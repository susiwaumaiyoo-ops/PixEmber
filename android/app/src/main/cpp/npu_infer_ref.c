// Phase 6 Stage A+: APK プロセス内での HTP0 実推論（最小実装）。
//
// 方針:
//   - 既存 Stage A の dual-path プローブ（Dart FFI）は一切壊さない。
//   - 実推論は本 C シム (libnpu_infer.so) に閉じ込める。
//     llama_model_params / llama_context_params は値返しの C 構造体のため、
//     Dart FFI では扱えず、C 側で完結させるのが最短・安全。
//   - 実行条件は adb shell 実績と揃える:
//       -dev HTP0 相当 (devices = {HTP0, NULL} + n_gpu_layers=99)
//       -t 4, -b 512 -ub 128, flash-attn off, greedy(temp0)
//   - モデルパス / プロンプト / 生成数は Dart から受け取る。
//   - 結果は固定レイアウトの InferResult* で返し、Dart 側 ffi.Struct で読む。
//   - ADSP/CDSP_LIBRARY_PATH は呼び出し前に Dart 側(setenv)で設定済み想定。
//     一応本シム起動時にも nativeLibraryDir を再設定して堅くする。

#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <errno.h>

#include <android/log.h>

#include "ggml.h"
#include "ggml-backend.h"
#include "llama.h"

#define TAG "FlutterLLM_NPU"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// A+-3 warm 用: 解放したくない model/ctx をプロセス全体で保持する静的変数。
// llama.h が struct llama_model / struct llama_context を前方宣言済み。
static struct llama_model   * s_keep_model = NULL;
static struct llama_context * s_keep_ctx   = NULL;

// ---- 結果構造体（Dart 側の ffi.Struct とレイアウトを一致させる） ----
typedef struct {
    int32_t status;   // 0 = success, !=0 = failure
    double  load_ms;  // モデルロード所要時間
    double  pp_tps;   // prompt processing tokens/sec
    double  tg_tps;   // token generation tokens/sec
    int32_t n_prompt; // 処理した prompt トークン数
    int32_t n_gen;    // 生成したトークン数
    double  wall_ms;  // 推論全体 (prompt処理+生成) の所要時間 (ms)
    char *  text;     // 生成テキスト (calloc, UTF-8, NUL 終端)
    char *  error;    // エラー全文 (calloc or NULL)
} InferResult;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec * 1000.0 + (double) ts.tv_nsec / 1e6;
}

static char * dup_err(const char * fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    char * out = (char *) calloc(strlen(buf) + 1, 1);
    if (out) {
        strcpy(out, buf);
    }
    return out;
}

// ---- growable UTF-8 バッファ ----
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

// 推論本体。model / prompt は UTF-8 NUL 終端文字列。
InferResult * npu_infer_run(
    const char * model_path,
    const char * prompt,
    int32_t      n_ctx,
    int32_t      n_batch,
    int32_t      n_ubatch,
    int32_t      n_threads,
    int32_t      n_gpu_layers,
     int32_t      n_gen_max,
     int32_t      use_chat_template,
     int32_t      keep_loaded) {

     InferResult * r = (InferResult *) calloc(1, sizeof(InferResult));
    if (r == NULL) {
        return NULL;
    }
    r->status = -1;

    if (model_path == NULL || prompt == NULL) {
        r->error = dup_err("model_path / prompt is NULL");
        return r;
    }

    // 可読性を先に確認（SELinux / パーミッション切り分け用）。
    FILE * fp = fopen(model_path, "rb");
    if (fp == NULL) {
        r->error = dup_err(
            "cannot open model: %s (errno=%d %s)",
            model_path, errno, strerror(errno));
        LOGE("[infer] %s", r->error);
        return r;
    }
    fclose(fp);

    llama_backend_init();

    // ---- デバイス取得 (HTP0) ----
    ggml_backend_dev_t htp = ggml_backend_dev_by_name("HTP0");
    if (htp == NULL) {
        r->error = dup_err("HTP0 device not found (enumerate failed)");
        LOGE("[infer] %s", r->error);
        return r;
    }
    LOGI("[infer] HTP0 device found, offloading (n_gpu_layers=%d)", n_gpu_layers);

    // devices = {HTP0, NULL}
    ggml_backend_dev_t dev_list[2];
    dev_list[0] = htp;
    dev_list[1] = NULL;

    // ---- モデルロード ----
    struct llama_model_params mparams = llama_model_default_params();
    mparams.devices      = dev_list;
    mparams.n_gpu_layers = n_gpu_layers;

     struct llama_context * ctx;
     struct llama_model * model;
     // ---- warm: 直近の run が model/ctx を保持していれば再ロードしない ----
    if (s_keep_model != NULL && s_keep_ctx != NULL) {
        model = s_keep_model;
        ctx   = s_keep_ctx;
        r->load_ms = 0.0;
        // warm: 保持 ctx の KV キャッシュは前回の推論が埋めたままなので、
        // 全シーケンスを除去して推論位置を 0 に戻す。
        // モデル本体 / ctx / HTP バッファは再利用（再ロード・再初期化なし）。
        {
            llama_memory_t mem = llama_get_memory(ctx);
            llama_memory_seq_rm(mem, -1, 0, -1);
            LOGI("[infer] warm path: KV cache cleared (seq_rm all)");
        }
        LOGI("[infer] warm path: reusing retained model+ctx (load_ms=0)");
    } else {
         double t_load0 = now_ms();
         model = llama_model_load_from_file(model_path, mparams);
         r->load_ms = now_ms() - t_load0;
         if (model == NULL) {
             r->error = dup_err(
                 "llama_model_load_from_file failed (load_ms=%.1f)", r->load_ms);
             LOGE("[infer] %s", r->error);
             return r;
         }
         LOGI("[infer] model loaded in %.1f ms", r->load_ms);

         struct llama_context_params cparams = llama_context_default_params();
         cparams.n_ctx         = (uint32_t) (n_ctx > 0 ? n_ctx : 512);
         cparams.n_batch       = (uint32_t) (n_batch > 0 ? n_batch : 512);
         cparams.n_ubatch      = (uint32_t) (n_ubatch > 0 ? n_ubatch : 128);
         cparams.n_threads        = n_threads > 0 ? n_threads : 4;
         cparams.n_threads_batch  = cparams.n_threads;
         cparams.flash_attn_type  = LLAMA_FLASH_ATTN_TYPE_DISABLED;
         ctx = llama_init_from_model(model, cparams);
         if (ctx == NULL) {
             r->error = dup_err("llama_init_from_model returned NULL");
             llama_model_free(model);
             LOGE("[infer] %s", r->error);
             return r;
         }
     }

     const struct llama_vocab * vocab = llama_model_get_vocab(model);

     // ---- sampler: greedy(temp0 相当) ----
    struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    struct llama_sampler * smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    // ---- (任意) チャットテンプレ適用: adb shell --jinja と同一構造に揃える ----
    // 生プロンプトをそのまま使わず、モデル内蔵 jinja 文字列で
    // "<start_of_turn>user\n..<end_of_turn>\n<start_of_turn>model\n" 化する。
    const char * effective_prompt = prompt;
    char * tmpl_buf = NULL;
    if (use_chat_template) {
        const char * tmpl = llama_model_chat_template(model, NULL);
        struct llama_chat_message chat[1];
        chat[0].role    = "user";
        chat[0].content = prompt;
        // 必要長を測る（返り値が buf のサイズ超なら realloc して再適用）。
        int32_t need = llama_chat_apply_template(tmpl, chat, 1, /*add_ass=*/true, NULL, 0);
        if (need <= 0) {
            need = (int32_t) strlen(prompt) * 2 + 256;
        }
        tmpl_buf = (char *) calloc((size_t) need + 4, 1);
        int32_t applied = llama_chat_apply_template(
            tmpl, chat, 1, /*add_ass=*/true, tmpl_buf, need);
        if (applied > 0 && applied <= need) {
            tmpl_buf[applied] = '\0';
            effective_prompt = tmpl_buf;
            LOGI("[infer] chat template applied (builtin): tmpl_len=%d chars", applied);
        } else {
            // 内蔵検出が使えない（カスタム jinja）→ Gemma 形式を手でラップ。
            // llama-chat.cpp LLM_CHAT_TEMPLATE_GEMMA と同一の出力形を再現する。
            free(tmpl_buf);
            size_t pl = strlen(prompt);
            const char * head = "<start_of_turn>user\n";
            const char * tail = "<end_of_turn>\n<start_of_turn>model\n";
            size_t cap = strlen(head) + pl + strlen(tail) + 4;
            tmpl_buf = (char *) calloc(cap, 1);
            int32_t wn = snprintf(
                tmpl_buf, cap, "%s%s%s", head, prompt, tail);
            if (wn > 0 && (size_t) wn < cap) {
                effective_prompt = tmpl_buf;
                LOGI("[infer] chat template applied (manual-gemma): len=%d chars", wn);
            } else {
                LOGE("[infer] manual gemma wrap failed, fallback to raw");
                effective_prompt = prompt;
            }
        }
    }

    // ---- tokenize (parse_special=true: <start_of_turn> 等を特殊トークン化) ----
    int32_t plen = (int32_t) strlen(effective_prompt);
    int32_t max_tok = plen + 8;  // 日本語は最大で 1文字=1tok 程度
    llama_token * toks = (llama_token *) calloc(max_tok, sizeof(llama_token));
    int32_t n_tok = llama_tokenize(vocab, effective_prompt, plen, toks, max_tok,
                                   /*add_special=*/true, /*parse_special=*/true);
    if (tmpl_buf) {
        free(tmpl_buf);
        tmpl_buf = NULL;
    }
    if (n_tok <= 0) {
        r->error = dup_err("llama_tokenize failed (%d)", n_tok);
        goto cleanup;
    }
    LOGI("[infer] prompt tokens = %d", n_tok);

    // ---- prompt processing (pp): n_batch を超える場合は分割ループ ----
    {
        int32_t nb = (n_batch > 0 ? n_batch : 512);
        double t0 = now_ms();
        int32_t n_processed = 0;
        int32_t rc = 0;
        while (n_processed < n_tok) {
            int32_t chunk = n_tok - n_processed;
            if (chunk > nb) {
                chunk = nb;
            }
            struct llama_batch batch = llama_batch_get_one(toks + n_processed, chunk);
            rc = llama_decode(ctx, batch);
            if (rc != 0) {
                break;
            }
            n_processed += chunk;
        }
        if (rc != 0) {
            r->error = dup_err("llama_decode(prompt) rc=%d at %d/%d", rc, n_processed, n_tok);
            goto cleanup;
        }
        double dt = (now_ms() - t0) / 1000.0;
        r->pp_tps = (dt > 0) ? (double) n_tok / dt : 0.0;
        r->n_prompt = n_tok;
        r->wall_ms = dt * 1000.0;
        LOGI("[infer] pp done: %d tok (nb=%d) in %.1f ms -> %.2f t/s",
             n_tok, nb, dt * 1000.0, r->pp_tps);
    }

    // ---- generation loop (tg) ----
    sbuf out;
    sbuf_init(&out);
    {
        llama_token cur = llama_sampler_sample(smpl, ctx, -1);
        llama_sampler_accept(smpl, cur);
        double t0 = now_ms();
        int32_t i = 0;
        for (; i < n_gen_max; i++) {
            if (llama_vocab_is_eog(vocab, cur)) {
                break;
            }
            char piece[128];
            int32_t n = llama_token_to_piece(vocab, cur, piece, sizeof(piece), 0, true);
            if (n > 0) {
                sbuf_append(&out, piece, (size_t) n);
            }
            struct llama_batch nb = llama_batch_get_one(&cur, 1);
            int32_t rc = llama_decode(ctx, nb);
            if (rc != 0) {
                if (r->error == NULL) {
                    r->error = dup_err("llama_decode(gen) rc=%d at i=%d", rc, i);
                }
                LOGE("[infer] %s", r->error);
                break;
            }
            cur = llama_sampler_sample(smpl, ctx, -1);
            llama_sampler_accept(smpl, cur);
        }
         double dt = (now_ms() - t0) / 1000.0;
         r->n_gen = i;
         r->tg_tps = (i > 0 && dt > 0) ? (double) i / dt : 0.0;
         if (i > 0) {
             r->wall_ms += dt * 1000.0;
         }
         LOGI("[infer] tg done: %d tok in %.1f ms -> %.2f t/s",
              i, dt * 1000.0, r->tg_tps);
    }
    r->text = out.data;  // calloc/realloc 済み。呼び出し側で free。

     r->status = 0;
     if (r->error != NULL) {
         // 生成途中でエラーが出たら status 非0 として扱うが text は返す。
         r->status = 1;
     }

     cleanup:
     if (toks) {
         free(toks);
     }
     llama_sampler_free(smpl);
     if (keep_loaded) {
         // A+-3 warm: 同一プロセス内で model/ctx を解放せず保持し、
         // 2 回目以降は再ロードせずそのまま推論する。
         s_keep_ctx = ctx;
         s_keep_model = model;
         LOGI("[infer] keep_loaded=1: retain model+ctx (no free)");
     } else {
         llama_free(ctx);
         llama_model_free(model);
     }
     LOGI("[infer] ==== npu_infer_run end status=%d keep=%d ====", r->status, keep_loaded);
     return r;
     }

// 結果解放。text / error / r 自体を free する。
void npu_infer_free_result(InferResult * r) {
    if (r == NULL) {
        return;
    }
    if (r->text) {
        free(r->text);
    }
    if (r->error) {
        free(r->error);
    }
    free(r);
}
