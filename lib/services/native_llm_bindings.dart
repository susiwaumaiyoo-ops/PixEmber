// libnative_llm.so の Dart FFI バインディング（低レベル）。
//
// 対応する C API は android/app/src/main/cpp/native_llm.c。
// セッションポインタ（session_t*）は void* としてやり取りし、
// ワーカー isolate 間では int アドレスで受け渡す。
//
// 注意:
// - nllm_load / nllm_generate はブロッキング。必ず別 isolate で呼ぶ。
// - nllm_request_stop はアトミックストアのみ。メイン isolate から
//   直接呼んでも安全（generate 実行中でもよい）。
// - llama_chat_message は { const char* role; const char* content; }。
//   nllm_generate はこのレイアウトと同一の nllm_chat_msg 配列を受け取る
//   （native 側でレイアウト非依存化済み）。
// - nllm_generate のトークン piece はネイティブ malloc 済みコピー。
//   受け取った側は必ず freeNativePiece()（= nllm_free）で解放すること。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// nllm_token_cb: void (*)(const char * piece_utf8, int32_t len, void * user_data)
typedef NllmTokenCbNative =
    ffi.Void Function(ffi.Pointer<Utf8>, ffi.Int32, ffi.Pointer<ffi.Void>);

typedef NllmTokenCbNativePtr =
    ffi.Pointer<ffi.NativeFunction<NllmTokenCbNative>>;

/// struct llama_chat_message { const char * role; const char * content; }
final class LlamaChatMessageFfi extends ffi.Struct {
  external ffi.Pointer<Utf8> role;
  external ffi.Pointer<Utf8> content;
}

/// libnative_llm.so のシンボル一覧。
class NativeLlmLib {
  NativeLlmLib(ffi.DynamicLibrary dylib) : _lib = dylib;

  final ffi.DynamicLibrary _lib;

  /// void nllm_set_lib_dir(const char * native_lib_dir)
  late final void Function(ffi.Pointer<Utf8>) setLibDir = _lib
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<Utf8>),
        void Function(ffi.Pointer<Utf8>)
      >('nllm_set_lib_dir');

  /// int32_t nllm_init(const char * dir, char * errbuf, int32_t errcap)
  late final int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int) init = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Int32),
        int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int)
      >('nllm_init');

  /// void nllm_free(void * p) — ネイティブ malloc 済みトークン片の解放。
  late final void Function(ffi.Pointer<ffi.Void>) freeNativePiece = _lib
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)
      >('nllm_free');

  late final int Function() hasHtp = _lib
      .lookupFunction<ffi.Int32 Function(), int Function()>('nllm_has_htp');

  late final int Function() hasOpencl = _lib
      .lookupFunction<ffi.Int32 Function(), int Function()>('nllm_has_opencl');

  /// session_t * nllm_load(...) — 失敗時 NULL + errbuf 設定。
  late final ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8> modelPath,
    int backendKind,
    int nCtx,
    int nBatch,
    int nUbatch,
    int nThreads,
    int nGpuLayers,
    int flashAttn,
    ffi.Pointer<Utf8> errbuf,
    int errcap,
  )
  load = _lib
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<Utf8>,
          ffi.Int32,
          ffi.Int32,
          ffi.Int32,
          ffi.Int32,
          ffi.Int32,
          ffi.Int32,
          ffi.Int32,
          ffi.Pointer<Utf8>,
          ffi.Int32,
        ),
        ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<Utf8>,
          int,
          int,
          int,
          int,
          int,
          int,
          int,
          ffi.Pointer<Utf8>,
          int,
        )
      >('nllm_load');

  late final int Function(ffi.Pointer<ffi.Void>) sessionKind = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<ffi.Void>)
      >('nllm_session_kind');

  late final ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>)
  sessionModelPath = _lib
      .lookupFunction<
        ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>),
        ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void>)
      >('nllm_session_model_path');

  /// int32_t nllm_generate(session, msgs, n_msgs, n_gen_max, temperature,
  ///                        on_token, user_data, errbuf, errcap)
  late final int Function(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<LlamaChatMessageFfi> msgs,
    int nMsgs,
    int nGenMax,
    double temperature,
    NllmTokenCbNativePtr onToken,
    ffi.Pointer<ffi.Void> userData,
    ffi.Pointer<Utf8> errbuf,
    int errcap,
  )
  generate = _lib
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<LlamaChatMessageFfi>,
          ffi.Int32,
          ffi.Int32,
          ffi.Float,
          NllmTokenCbNativePtr,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<Utf8>,
          ffi.Int32,
        ),
        int Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<LlamaChatMessageFfi>,
          int,
          int,
          double,
          NllmTokenCbNativePtr,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<Utf8>,
          int,
        )
      >('nllm_generate');

  late final void Function(ffi.Pointer<ffi.Void>) requestStop = _lib
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)
      >('nllm_request_stop');

  /// void * nllm_stop_flag_addr(session_t *)
  /// atomic_int stop のアドレスを void* で返す。Dart 側は
  /// `ffi.Pointer<ffi.Int32>.fromAddress(addr)` として保持し、
  /// メイン isolate から ptr.value = 1 を書くだけで停止要求できる
  /// （C 関数呼び出しではない＝二重 dlopen/isolate 不要）。
  late final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>) stopFlagAddr =
      _lib.lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
      >('nllm_stop_flag_addr');

  /// void nllm_get_stats(session, double* pp_tps, double* tg_tps,
  ///                      int32_t* n_prompt, int32_t* n_gen)
  late final void Function(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<ffi.Double> ppTps,
    ffi.Pointer<ffi.Double> tgTps,
    ffi.Pointer<ffi.Int32> nPrompt,
    ffi.Pointer<ffi.Int32> nGen,
  )
  getStats = _lib
      .lookupFunction<
        ffi.Void Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Double>,
          ffi.Pointer<ffi.Double>,
          ffi.Pointer<ffi.Int32>,
          ffi.Pointer<ffi.Int32>,
        ),
        void Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Double>,
          ffi.Pointer<ffi.Double>,
          ffi.Pointer<ffi.Int32>,
          ffi.Pointer<ffi.Int32>,
        )
      >('nllm_get_stats');

  late final int Function(
    ffi.Pointer<ffi.Void> session,
    ffi.Pointer<Utf8> text,
    int addSpecial,
  )
  countTokens = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Int32),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, int)
      >('nllm_count_tokens');

  /// int32_t nllm_get_stop_reason(session_t *)
  /// 直近生成の停止理由(0=eos 1=limit 2=cancel 3=error, -1=未生成)。
  late final int Function(ffi.Pointer<ffi.Void>) stopReason = _lib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<ffi.Void>)
      >('nllm_get_stop_reason');

  late final void Function(ffi.Pointer<ffi.Void>) unload = _lib
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)
      >('nllm_unload');
}
