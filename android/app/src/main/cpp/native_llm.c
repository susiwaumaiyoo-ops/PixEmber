// libnative_llm.so — PixEmber ローカルLLMネイティブレイヤー（llama.cpp C API ラッパ）。
//
// 設計根拠（flutter_llm 検証済み構成を踏襲）:
//   - llama.cpp 系 .so（libllama/libggml*/HTP skel/OpenCL stub）は jniLibs 同梱。
//   - HTP0 は ggml_backend_dev_by_name("HTP0") で取得し、
//     llama_model_params.devices = {HTP0, NULL} + n_gpu_layers でオフロード。
//     （adb shell llama-cli -dev HTP0 と同一構成 / SD 8 Gen 2 で pp 268-330 t/s 実証）
//   - ADSP_LIBRARY_PATH は nllm_init() 内で llama_backend_init() より前に
//     setenv する（未設定だと FastRPC 0x80000406 で HTP ctx open 失敗）。
//     CDSP_LIBRARY_PATH は設定しない（誤設定すると CPU 経路まで壊れる実証あり）。
//   - 生成はトークン単位でコールバック（NaitiveCallable 経由で Dart へ配信）。
//   - キャンセルは atomic int フラグをトークン境界で確認する協力型。
//   - セッション再利用: 同一モデル/同一設定ならロードをスキップする。
//     Qwen3.5 は Attention + recurrent の hybrid memory を持つため、
//     独立した生成リクエスト開始時に llama_memory_clear(mem, true) で
//     メモリを完全リセットしてから warm 実行する。
//
// 制約: llama.cpp のソースは改変・再ビルドしない（ヘッダのみ借用、SHA 050dde5）。

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <errno.h>

#include <android/log.h>
#include <sys/system_properties.h>

#include "ggml.h"
#include "ggml-backend.h"
#include "llama.h"

// Dart 側が atomic_int のアドレスを Pointer<Int32> として直接操作するため、
// atomic_int が int32 と同一の 4 バイトであることをコンパイル時に保証する。
_Static_assert(sizeof(atomic_int) == sizeof(int32_t),
               "atomic_int must be 4 bytes to expose as Pointer<Int32>");

#define TAG "PixEmberNativeLLM"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
// 診断専用。通常ビルドでは本文断片を常時ログに残さない用途に使う。
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// 共通ヘルパ
// ---------------------------------------------------------------------------

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec * 1000.0 + (double) ts.tv_nsec / 1e6;
}

typedef struct {
    char *  data;
    size_t  len;
    size_t  cap;
} sbuf;

static void sbuf_init(sbuf * s) {
    s->cap = 256;
    s->len = 0;
    s->data = (char *) calloc(s->cap, 1);
}

static void sbuf_append(sbuf * s, const char * p, size_t n) {
    if (s->data == NULL) {
        return;
    }
    if (s->len + n + 1 > s->cap) {
        size_t nc = s->cap * 2;
        while (nc < s->len + n + 1) {
            nc *= 2;
        }
        char * nd = (char *) realloc(s->data, nc);
        if (nd == NULL) {
            return;
        }
        s->data = nd;
        s->cap = nc;
    }
    memcpy(s->data + s->len, p, n);
    s->len += n;
    s->data[s->len] = '\0';
}

static void copy_err(char * errbuf, int32_t cap, const char * fmt, ...) {
    if (errbuf == NULL || cap <= 0) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(errbuf, (size_t) cap, fmt, ap);
    va_end(ap);
    errbuf[cap - 1] = '\0';
}

// ---------------------------------------------------------------------------
// init / バックエンド列挙
// ---------------------------------------------------------------------------

static const char * g_lib_dir = NULL;  // nativeLibraryDir（ADSP_LIBRARY_PATH 用）
static int g_initialized = 0;

void nllm_set_lib_dir(const char * native_lib_dir) {
    if (native_lib_dir != NULL && native_lib_dir[0] != '\0') {
        g_lib_dir = native_lib_dir;
        LOGI("[init] lib dir set: %s", g_lib_dir);
    }
}

int32_t nllm_init(const char * native_lib_dir, char * errbuf, int32_t errcap) {
    if (native_lib_dir != NULL && native_lib_dir[0] != '\0') {
        g_lib_dir = native_lib_dir;
    }
    if (g_initialized) {
        return 0;
    }
    // ADSP_LIBRARY_PATH は llama_backend_init() より前に設定必須。
    if (g_lib_dir != NULL) {
        setenv("ADSP_LIBRARY_PATH", g_lib_dir, 1);
        LOGI("[init] ADSP_LIBRARY_PATH=%s", g_lib_dir);
    }
    llama_backend_init();
    g_initialized = 1;
    LOGI("[init] llama_backend_init done");
    (void) errbuf;
    (void) errcap;
    return 0;
}

// バックエンド種別: ggml_backend_dev_type を PixEmber の論理 ID へ寄せる。
//   0 = CPU, 1 = GPU(OpenCL等), 2 = NPU(HTP/AI / accel 系)
//
// 注意: HTP はビルドにより ggml 側で type=GPU として登録される実装が
// 存在する（実機 Xiaomi Pad 6S Pro では HTP0 が GGML_BACKEND_DEVICE_TYPE_GPU
// として現れ、dev_kind が 1 を返していた）。kind は fa 既定値と Dart 側の
// 表示名を決めるため、HTP が 1 に誤映射されると flash-attn が off になり
// （kind==1 → fa=0）KV が fp16 で大量確保され、HTP ワークメモリと相まって
// メモリ逼迫 → lmkd kill の一因となる。名前 "HTP" を含むデバイス論理 ID
// を NPU(2) に寄せる。
static int32_t dev_kind(ggml_backend_dev_t dev) {
    const char * name = ggml_backend_dev_name(dev);
    if (name != NULL && strstr(name, "HTP") != NULL) {
        return 2;
    }
    switch (ggml_backend_dev_type(dev)) {
        case GGML_BACKEND_DEVICE_TYPE_CPU:
            return 0;
        case GGML_BACKEND_DEVICE_TYPE_GPU:
            return 1;
        case GGML_BACKEND_DEVICE_TYPE_ACCEL:
            return 2;
        default:
            return 0;
    }
}

static int32_t find_htp(ggml_backend_dev_t * out) {
    // 既定名 HTP0 の他、ACC 系デバイスから "HTP" を含むものを探す。
    ggml_backend_dev_t d = ggml_backend_dev_by_name("HTP0");
    if (d != NULL) {
        *out = d;
        return 1;
    }
    const size_t n = ggml_backend_dev_count();
    for (size_t i = 0; i < n; i++) {
        ggml_backend_dev_t cand = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(cand) == GGML_BACKEND_DEVICE_TYPE_ACCEL &&
            strstr(ggml_backend_dev_name(cand), "HTP") != NULL) {
            *out = cand;
            return 1;
        }
    }
    return 0;
}

static int32_t find_opencl(ggml_backend_dev_t * out) {
    const size_t n = ggml_backend_dev_count();
    for (size_t i = 0; i < n; i++) {
        ggml_backend_dev_t cand = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(cand) == GGML_BACKEND_DEVICE_TYPE_GPU &&
            strstr(ggml_backend_dev_name(cand), "OpenCL") != NULL) {
            *out = cand;
            return 1;
        }
    }
    return 0;
}

int32_t nllm_has_htp(void) {
    ggml_backend_dev_t dev = NULL;
    return find_htp(&dev) ? 1 : 0;
}

int32_t nllm_has_opencl(void) {
    ggml_backend_dev_t dev = NULL;
    return find_opencl(&dev) ? 1 : 0;
}

// ---------------------------------------------------------------------------
// セッション
// ---------------------------------------------------------------------------

typedef struct {
    struct llama_model   * model;
    struct llama_context * ctx;
    char *   model_path;
    int32_t  kind;         // 0=cpu 1=gpu(opencl) 2=npu(htp)
    int32_t  active;       // generate 実行中フラグ
    atomic_int stop;       // 0=実行 1=停止要求
    // 直近生成のパフォーマンス実測値
    double   pp_tps;
    double   tg_tps;
    int32_t  n_prompt;
    int32_t  n_gen;
    // 停止理由: 0=eos 1=limit 2=cancel 3=error(-1=未生成)
    int32_t  stop_reason;
    int32_t  n_gen_max;
} session_t;

static ggml_backend_dev_t pick_device(int32_t kind, char * errbuf, int32_t errcap) {
    // kind: -1=auto(HTP→OpenCL→CPU) / 0=cpu / 1=opencl / 2=htp
    ggml_backend_dev_t dev = NULL;
    if (kind == 0) {
        return NULL;  // CPU（devices 未指定 = 既定）
    }
    if (kind == 2 || kind == -1) {
        if (find_htp(&dev)) {
            return dev;
        }
        if (kind == 2) {
            // auto でなければ即失敗 → Dart 側で CPU へフォールバック。
            copy_err(errbuf, errcap, "HTP device not available");
            return NULL;
        }
    }
    if (kind == 1 || kind == -1) {
        if (find_opencl(&dev)) {
            return dev;
        }
        if (kind == 1) {
            copy_err(errbuf, errcap, "OpenCL device not available");
            return NULL;
        }
    }
    return NULL;  // CPU
}
session_t * nllm_load(
    const char * model_path,
    int32_t      backend_kind,   // -1=auto 0=cpu 1=opencl 2=htp
    int32_t      n_ctx,
    int32_t      n_batch,
    int32_t      n_ubatch,
    int32_t      n_threads,
    int32_t      n_gpu_layers,  // <0 時は kind 既定値（htp/opencl=99, cpu=0）
    int32_t      flash_attn,    // <0 時は kind 既定値（opencl=0, 他=1）
    char *       errbuf,
    int32_t      errcap) {

    errbuf[0] = '\0';
    if (model_path == NULL || model_path[0] == '\0') {
        copy_err(errbuf, errcap, "model_path empty");
        return NULL;
    }
    if (!g_initialized) {
        nllm_init(NULL, errbuf, errcap);
    }
    FILE * fp = fopen(model_path, "rb");
    if (fp == NULL) {
        copy_err(errbuf, errcap, "cannot open model: %s (errno=%d)", model_path, errno);
        return NULL;
    }
    fclose(fp);

    // auto: htp → opencl → cpu の順。見つからなければ cpu に落ちる。
    ggml_backend_dev_t dev = pick_device(backend_kind, errbuf, errcap);
    if (errbuf[0] != '\0') {
        return NULL;
    }
    int32_t kind = dev == NULL ? 0 : dev_kind(dev);
    if (backend_kind == -1) {
        // auto 解決結果を logcat に必ず出す（HTP 検証用）。
        LOGI("[load] auto resolved backend: %s (kind=%d)",
             dev != NULL ? ggml_backend_dev_name(dev) : "CPU", kind);
    }

    int32_t ngl = n_gpu_layers;
    if (ngl < 0) {
        ngl = (kind == 0) ? 0 : 99;
    }
    int32_t fa = flash_attn;
    if (fa < 0) {
        fa = (kind == 1) ? 0 : 1;  // OpenCL のみ fa off（検証済み最適構成）
    }
    if (n_threads <= 0) {
        n_threads = 4;
    }

    session_t * s = (session_t *) calloc(1, sizeof(session_t));
    if (s == NULL) {
        copy_err(errbuf, errcap, "OOM session");
        return NULL;
    }
    s->kind = kind;
    s->model_path = strdup(model_path);

    struct llama_model_params mparams = llama_model_default_params();
    if (dev != NULL) {
        static ggml_backend_dev_t dev_list[2];
        dev_list[0] = dev;
        dev_list[1] = NULL;
        mparams.devices = dev_list;
    }
    mparams.n_gpu_layers = ngl;

    double t0 = now_ms();
    s->model = llama_model_load_from_file(model_path, mparams);
    if (s->model == NULL) {
        copy_err(errbuf, errcap, "model load failed (kind=%d ngl=%d %.1fms)",
                 kind, ngl, now_ms() - t0);
        LOGE("[load] %s", errbuf);
        free(s->model_path);
        free(s);
        return NULL;
    }
    LOGI("[load] model loaded kind=%d ngl=%d fa=%d in %.1f ms",
         kind, ngl, fa, now_ms() - t0);

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx            = (uint32_t) (n_ctx > 0 ? n_ctx : 4096);
    cparams.n_batch          = (uint32_t) (n_batch > 0 ? n_batch : 512);
    cparams.n_ubatch         = (uint32_t) (n_ubatch > 0 ? n_ubatch : 128);
    cparams.n_threads        = n_threads;
    cparams.n_threads_batch  = n_threads;
    cparams.flash_attn_type  = fa ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED;
    s->ctx = llama_init_from_model(s->model, cparams);
    if (s->ctx == NULL) {
        copy_err(errbuf, errcap, "ctx init failed");
        llama_model_free(s->model);
        free(s->model_path);
        free(s);
        return NULL;
    }
    atomic_init(&s->stop, 0);
    s->active = 0;
    return s;
}

// stop フラグ（atomic_int）のアドレスを void* で返す。
// Dart 側はこれを Pointer<Int32>.fromAddress(addr) として保持し、
// メイン isolate から ptr.value = 1 を書き込むだけで停止要求できる
// （C 関数呼び出し＝dlopen/isolate 不要）。nllm_generate 内の
// atomic_load(&s->stop)（seq_cst）で検知される。
// 注意: アドレスの有効期間は session の生存中のみ。unload 後に
// 書込みると use-after-free になるため、Dart 側は unload 時に
// Pointer を null 化し、stop 時は null チェックで no-op する。
void * nllm_stop_flag_addr(session_t * s) {
    return (s == NULL) ? NULL : (void *) &s->stop;
}

int32_t nllm_session_kind(session_t * s) {
    return s ? s->kind : -1;
}

const char * nllm_session_model_path(session_t * s) {
    return s ? (const char *) s->model_path : "";
}

// ---------------------------------------------------------------------------
// チャットテンプレート適用
// ---------------------------------------------------------------------------

// llama_chat_message のレイアウト依存を排し、バインディング側で
// 確保した {const char* role; const char* content;} 配列を指す
// ポインタを受け取る（1要素あたり 2 語長。role=+0, content=+8）。
typedef struct {
    const char * role;
    const char * content;
} nllm_chat_msg;

static char * apply_chat_template(
    const struct llama_model * model,
    const nllm_chat_msg * msgs,
    size_t n_msgs,
    const char * fallback_head,  // 手動ラップ時の user ヘッダ例 "<start_of_turn>user\n"
    const char * fallback_sep,   // メッセージ間区切り例 "<end_of_turn>\n"
    const char * fallback_tail,  // 生成開始尾例 "<end_of_turn>\n<start_of_turn>model\n"
    char * errbuf, int32_t errcap) {

    // nllm_chat_msg は llama_chat_message とレイアウト同一（語長2）。
    const struct llama_chat_message * raw = (const struct llama_chat_message *) msgs;
    const char * tmpl = llama_model_chat_template(model, NULL);
    int32_t need = llama_chat_apply_template(tmpl, raw, n_msgs, /*add_ass=*/true, NULL, 0);
    if (need > 0) {
        char * buf = (char *) calloc((size_t) need + 4, 1);
        int32_t applied = llama_chat_apply_template(
            tmpl, raw, n_msgs, true, buf, need);
        if (applied > 0 && applied <= need) {
            buf[applied] = '\0';
            LOGI("[tmpl] builtin applied: %d chars", applied);
            // Qwen3.5: llama.cpp 内蔵コンバータは enable_thinking の else 分岐
            // (<think>\n\n</think>\n\n) を再現しないため、生成ターン先頭へ
            // 空 think ブロックを注入して思考の自発開始を抑止する。
            // 誤注入防止: 末尾の '<|im_start|>assistant' 直後が生成ターンであり、
            // かつ空 think が未挿入の場合のみ補う。
            {
                static const char * kImStartAsst = "<|im_start|>assistant";
                static const char * kNoThink = "<think>\n\n</think>\n\n";
                const char * last = NULL;
                for (const char * p = buf;
                     (p = strstr(p, kImStartAsst)) != NULL;
                     p += strlen(kImStartAsst)) {
                    last = p;
                }
                if (last != NULL) {
                    const char * after = last + strlen(kImStartAsst);
                    while (*after == '\n' || *after == '\r' || *after == ' ') {
                        after++;
                    }
                    // 診断: 生成ターン末尾(本文断片ではない)のみ DEBUG へ。
                    LOGD("[tmpl] gen-turn suffix: '%s'", after);
                    if (strstr(after, "<|im_end|>") == NULL &&
                        strncmp(after, "<think>", 7) != 0) {
                        size_t add = strlen(kNoThink);
                        char * nb = (char *) realloc(buf, (size_t) applied + add + 1);
                        if (nb != NULL) {
                            memcpy(nb + applied, kNoThink, add + 1);
                            buf = nb;
                            LOGI("[tmpl] injected no-think prefix: %zu chars", add);
                        }
                    }
                }
            }
            return buf;
        }
        free(buf);
    }
    // 内蔵テンプレ適用不可（カスタム jinja 等）→ Gemma 形式を手でラップ。
    LOGI("[tmpl] builtin failed, manual wrap fallback");
    sbuf out;
    sbuf_init(&out);
    for (size_t i = 0; i < n_msgs; i++) {
        sbuf_append(&out, fallback_head, strlen(fallback_head));
        sbuf_append(&out, msgs[i].content, strlen(msgs[i].content));
        sbuf_append(&out, fallback_sep, strlen(fallback_sep));
    }
    sbuf_append(&out, fallback_tail, strlen(fallback_tail));
    if (out.data == NULL) {
        copy_err(errbuf, errcap, "tmpl OOM");
        return NULL;
    }
    return out.data;
}

// ---------------------------------------------------------------------------
// 生成（トークンコールバック + 協力型キャンセル）
// ---------------------------------------------------------------------------

// 生成コールバックに渡す piece は malloc 済みコピー。受け取った側
// （Dart）は使用後に必ず nllm_free() すること。
// （NativeCallable.listener の非同期マーシャリングでは、スタック
// バッファを渡すと使用時点で失効するため。）
typedef void (*nllm_token_cb)(const char * piece_utf8, int32_t len, void * user_data);

void nllm_free(void * p) {
    free(p);
}

// decode 失敗時: 途中まで処理した ubatch が次リクエストへ残らないよう、
// 同期 -> メモリ全クリア(data 含む) -> 同期 を行ってから error 終了する。
static void reset_memory_after_decode_failure(struct llama_context * ctx) {
    if (ctx == NULL) return;
    llama_synchronize(ctx);
    llama_memory_t mem = llama_get_memory(ctx);
    if (mem != NULL) {
        llama_memory_clear(mem, true);
    }
    llama_synchronize(ctx);
}

int32_t nllm_generate(
    session_t * s,
    const nllm_chat_msg * msgs,
    int32_t         n_msgs,
    int32_t         n_gen_max,
    float           temperature,   // <=0 で greedy
    nllm_token_cb   on_token,
    void *          user_data,
    char *          errbuf,
    int32_t         errcap) {

    errbuf[0] = '\0';
    LOGI("[gen] ENTER nllm_generate (session=%p n_msgs=%d max=%d temp=%.2f)",
         (void *) s, n_msgs, n_gen_max, temperature);
    if (s == NULL || s->ctx == NULL) {
        copy_err(errbuf, errcap, "invalid session");
        LOGE("[gen] invalid session");
        return -1;
    }
    if (s->active) {
        copy_err(errbuf, errcap, "session busy");
        LOGE("[gen] session busy");
        return -2;
    }
    s->active = 1;

    // セッション再利用(warm)対応:
    // Qwen3.5 は Attention + recurrent の hybrid memory を持ち、独立した
    // 生成リクエスト開始時にメモリを完全リセットできていないと前回の位置
    // カウンタが蓄積し、n_ctx 超過で次の prompt decode が rc=1 で失敗する
    // (実測: 1本目 eos 成功 -> 2本目 1536/2017 で失敗 -> 以降 processed=0 即失敗)。
    // seq_rm の戻り値を無視するだけでは残骸を検出できないため、順序を固定し
    // synchronize -> 取得 -> pos_max 記録 -> clear(data 含む) -> synchronize ->
    // pos_max 記録 を実施。mem が取得できない場合は生成せずエラーで返す。
    {
        llama_synchronize(s->ctx);
        llama_memory_t mem = llama_get_memory(s->ctx);
        if (mem == NULL) {
            copy_err(errbuf, errcap, "failed to get context memory");
            LOGE("[gen] %s", errbuf);
            s->active = 0;
            return -1;
        }
        const llama_pos before = llama_memory_seq_pos_max(mem, 0);
        llama_memory_clear(mem, true);
        llama_synchronize(s->ctx);
        const llama_pos after = llama_memory_seq_pos_max(mem, 0);
        // 注意: hybrid memory の pos_max は Attention/recurrent を個別表示
        // しないため、after=-1 だけを「完全クリアの証明」とは見なさない。
        // 実用上の合格判定は同一 context での 3 連続生成成功。
        LOGI("[gen] memory reset: pos_max before=%d after=%d",
             (int) before, (int) after);
    }

    // 生成状態を初期値へ戻す(stop フラグ / 停止理由 / 生成上限)。
    atomic_store(&s->stop, 0);
    s->stop_reason = -1;
    s->n_gen_max = 0;

    int32_t rc = -1;
    char * prompt = NULL;
    llama_token * toks = NULL;
    struct llama_sampler * smpl = NULL;

    const struct llama_vocab * vocab = llama_model_get_vocab(s->model);

    // messages → テンプレ文字列。Gemma 手動ラップ用の既定もここで渡す。
    const nllm_chat_msg * use_msgs = msgs;
    int32_t use_n = n_msgs;
    prompt = apply_chat_template(
        s->model, use_msgs, (size_t) use_n,
        "<start_of_turn>user\n", "<end_of_turn>\n",
        "<end_of_turn>\n<start_of_turn>model\n",
        errbuf, errcap);
    if (prompt == NULL) {
        goto done;
    }

    {
        int32_t plen = (int32_t) strlen(prompt);
        int32_t max_tok = plen + 8;
        toks = (llama_token *) calloc((size_t) max_tok, sizeof(llama_token));
        int32_t n_tok = llama_tokenize(vocab, prompt, plen, toks, max_tok,
                                       /*add_special=*/true, /*parse_special=*/true);
        if (n_tok <= 0) {
            copy_err(errbuf, errcap, "tokenize failed (%d)", n_tok);
            goto done;
        }
        LOGI("[gen] prompt tokens = %d", n_tok);

        struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
        smpl = llama_sampler_chain_init(sparams);
        if (temperature > 0.0f) {
            llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
            llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
        } else {
            llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
        }

        // ---- prompt processing ----
        const int32_t nb = (int32_t) llama_n_batch(s->ctx);
        double pp0 = now_ms();
        int32_t processed = 0;
        int32_t drc = 0;
        while (processed < n_tok) {
            if (atomic_load(&s->stop)) {
                LOGI("[gen] cancelled during pp");
                rc = 1;
                goto done;
            }
            int32_t chunk = n_tok - processed;
            if (chunk > nb) {
                chunk = nb;
            }
            struct llama_batch batch = llama_batch_get_one(toks + processed, chunk);
            drc = llama_decode(s->ctx, batch);
            if (drc != 0) {
                break;
            }
            processed += chunk;
        }
        if (drc != 0) {
            copy_err(errbuf, errcap, "decode(prompt) rc=%d at %d/%d", drc, processed, n_tok);
            // fatal error 後の残骸を残さない(次回開始時の完全リセットに加え、
            // エラー終了時点でもクリアして安全側に倒す)。
            reset_memory_after_decode_failure(s->ctx);
            s->stop_reason = 3;
            s->n_gen_max = n_gen_max;
            goto done;
        }
        {
            double dt = (now_ms() - pp0) / 1000.0;
            s->pp_tps = dt > 0 ? (double) n_tok / dt : 0.0;
            s->n_prompt = n_tok;
            LOGI("[gen] pp: %d tok in %.1f ms -> %.2f t/s", n_tok, dt * 1000.0, s->pp_tps);
        }

        // ---- token generation ----
        double tg0 = now_ms();
        int32_t i = 0;
        llama_token cur = llama_sampler_sample(smpl, s->ctx, -1);
        llama_sampler_accept(smpl, cur);
        // 停止理由: 0=eos(自然終了) 1=limit(n_gen_max 到達)
        //           2=cancel(ユーザー停止) 3=error(デコード/OOM 失敗)
        int32_t status = 0;
        for (; i < n_gen_max; i++) {
            if (atomic_load(&s->stop)) {
                LOGI("[gen] cancelled at token %d", i);
                rc = 1;  // cooperative cancel: 正常終了扱い
                status = 2;
                break;
            }
            if (llama_vocab_is_eog(vocab, cur)) {
                status = 0;  // EOS
                break;
            }
            char * piece = (char *) malloc(128);
            if (piece == NULL) {
                copy_err(errbuf, errcap, "token piece OOM at i=%d", i);
                status = 3;  // OOM
                break;
            }
            int32_t n = llama_token_to_piece(vocab, cur, piece, 128, 0, true);
            if (n > 0 && on_token != NULL) {
                // 所有権をコールバック側へ移転（Dart が nllm_free する）。
                on_token(piece, n, user_data);
            } else {
                free(piece);
            }
            struct llama_batch one = llama_batch_get_one(&cur, 1);
            if (llama_decode(s->ctx, one) != 0) {
                copy_err(errbuf, errcap, "decode(gen) failed at i=%d", i);
                status = 3;  // decode error
                reset_memory_after_decode_failure(s->ctx);
                break;
            }
            cur = llama_sampler_sample(smpl, s->ctx, -1);
            llama_sampler_accept(smpl, cur);
        }
        // EOS/キャンセル/エラー以外でループを抜けた=上限到達。
        if (status != 2 && status != 3 && i >= n_gen_max) {
            status = 1;
        }
        s->stop_reason = status;
        s->n_gen_max = n_gen_max;
        {
            double dt = (now_ms() - tg0) / 1000.0;
            s->tg_tps = (i > 0 && dt > 0) ? (double) i / dt : 0.0;
            s->n_gen = i;
            static const char * kStopReason[] = {"eos", "limit", "cancel", "error"};
            LOGI("[gen] tg: %d tok in %.1f ms -> %.2f t/s (status=%d reason=%s n_gen_max=%d)",
                 i, dt * 1000.0, s->tg_tps, status,
                 kStopReason[status & 3], n_gen_max);
        }
        rc = errbuf[0] != '\0' ? -1 : 0;
        if (status == 2) {
            rc = 1;
        }
    }

done:
    if (smpl != NULL) {
        llama_sampler_free(smpl);
    }
    free(toks);
    free(prompt);
    s->active = 0;
    atomic_store(&s->stop, 0);
    return rc;
}

void nllm_request_stop(session_t * s) {
    if (s != NULL) {
        atomic_store(&s->stop, 1);
    }
}

// 直近生成の実測値取得。
void nllm_get_stats(session_t * s, double * pp_tps, double * tg_tps,
                    int32_t * n_prompt, int32_t * n_gen) {
    if (s == NULL) {
        return;
    }
    if (pp_tps) *pp_tps = s->pp_tps;
    if (tg_tps) *tg_tps = s->tg_tps;
    if (n_prompt) *n_prompt = s->n_prompt;
    if (n_gen) *n_gen = s->n_gen;
}

// 直近生成の停止理由(0=eos 1=limit 2=cancel 3=error, -1=未生成)。
int32_t nllm_get_stop_reason(session_t * s) {
    if (s == NULL) return -1;
    return s->stop_reason;
}

// プロンプト文字列（テンプレ後）のトークン数実測用。
int32_t nllm_count_tokens(session_t * s, const char * text, int32_t add_special) {
    if (s == NULL || s->model == NULL || text == NULL) {
        return -1;
    }
    const struct llama_vocab * vocab = llama_model_get_vocab(s->model);
    int32_t plen = (int32_t) strlen(text);
    int32_t max_tok = plen + 8;
    llama_token * tmp = (llama_token *) calloc((size_t) max_tok, sizeof(llama_token));
    int32_t n = llama_tokenize(vocab, text, plen, tmp, max_tok,
                               add_special != 0, /*parse_special=*/true);
    free(tmp);
    return n;
}

void nllm_unload(session_t * s) {
    if (s == NULL) {
        return;
    }
    if (s->ctx != NULL) {
        llama_free(s->ctx);
    }
    if (s->model != NULL) {
        llama_model_free(s->model);
    }
    free(s->model_path);
    free(s);
}
