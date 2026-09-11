// NativeLlmEngine — libnative_llm.so（llama.cpp C API ラッパ）への
// Dart FFI エンジンをワーカー isolate 付きで提供する。
//
// 設計（Option 1: ワーカー単一 dlopen / SendPort 経由 / isolateLocal cb）:
// - .so の dlopen はワーカー isolate で1回だけ。メイン isolate は
//   絶対に C 関数を直接呼ばない（二重 dlopen によるハンドルの不一致や
//   クロス isolate NativeCallback のマーシャリング問題を排除）。
// - モデルロード・生成（ブロッキング）はワーカー isolate で実行し、
//   メイン（UI）isolate をブロックしない。
// - 全操作（load / generate / countTokens / getStats / unload / stop）は
//   SendPort 経由でワーカーへ送るリクエスト／応答プロトコルで完結させる。
// - トークンコールバックはワーカー isolate 内で NativeCallable.isolateLocal
//   として作成する。nllm_generate はワーカーの Dart スレッド上で同期的に
//   実行され、on_token も同じスレッドから呼ばれるため、isolateLocal
//   コールバックがそのまま動作する。コールバック内で SendPort.send(bytes)
//   してトークンをメインへストリーミング配信する（SendPort.send は
//   送信 isolate が同期ブロック中でも受け取り側キューへ即時投递される）。
// - キャンセルは atomic アドレス方式。ロード時に nllm_stop_flag_addr の
//   返す atomic_int のアドレスを受け取り、メイン isolate が
//   Pointer<Int32>.value = 1 を書き込むだけ（C 関数呼び出しではないため
//   dlopen / 追加 isolate 不要）。ワーカーの生成ループが atomic_load で検知。
// - セッションポインタ / stop フラグアドレスは int で isolate 間をやり取り。
//
// Android 専用（libnative_llm.so は arm64-v8a の jniLibs 同梱）。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_llm_service.dart'
    show
        LlmBackend,
        LlmCancelledException,
        LlmChatMessage,
        LlmGenerationOptions,
        LlmInferenceEngine,
        LlmNativePerf;
import 'native_llm_bindings.dart';

/// libnative_llm.so への FFI バインディングエンジン（本番実装）。
class NativeLlmEngine implements LlmInferenceEngine {
  /// [backend] はユーザー要求（auto/npu/gpu/cpu）。npu/gpu 失敗時は
  /// LocalLlmService 側で CPU 再試行が行われる。
  NativeLlmEngine({
    required this.backend,
    // A-1: 既定は 8192（長文対応）。実際は LocalLlmService がセッションキー
    // 経由で contextSize を必ず渡すため、この既定値はフォールバック用。
    int contextSize = 8192,
    int gpuLayers = 0,
    int cpuThreads = 0,
    int nBatch = 512,
    int nUbatch = 128,
  }) : _contextSize = contextSize, // ignore: prefer_initializing_formals
       _gpuLayers = gpuLayers, // ignore: prefer_initializing_formals
       _cpuThreads = cpuThreads, // ignore: prefer_initializing_formals
       _nBatch = nBatch, // ignore: prefer_initializing_formals
       _nUbatch = nUbatch; // ignore: prefer_initializing_formals

  /// 実際に使用した backend のラベル（メトリクス表示用・従来互換）。
  static const String backendLabel = 'llama_cpp';

  final LlmBackend backend;
  final int _contextSize;
  final int _gpuLayers;
  final int _cpuThreads;
  final int _nBatch;
  final int _nUbatch;

  static const MethodChannel _channel = MethodChannel(
    'com.example.pixiv_viewer/native_llm',
  );

  static String? _nativeLibDir;

  /// ネイティブライブラリディレクトリ（applicationInfo.nativeLibraryDir）。
  static Future<String> _libDir() async {
    final cached = _nativeLibDir;
    if (cached != null) return cached;
    if (!Platform.isAndroid) {
      throw StateError('NativeLlmEngine requires Android');
    }
    final dir = await _channel.invokeMethod<String>('getNativeLibraryDir');
    if (dir == null || dir.isEmpty) {
      throw StateError('nativeLibraryDir unavailable');
    }
    return _nativeLibDir = dir;
  }

  // --- ワーカー isolate 管理 -------------------------------------------

  Isolate? _worker;
  SendPort? _workerSend;
  ReceivePort? _replyPort;
  final Completer<SendPort> _workerReady = Completer<SendPort>();
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 1;
  bool _disposed = false;

  int? _sessionAddr;
  int? _resolvedKind; // 0=cpu 1=opencl 2=htp

  /// stop フラグ（atomic_int）のアドレスをラップした Pointer。
  /// ロード時にワーカー応答で受領し、unload/dispose で null 化する。
  /// メイン isolate は requestStop() で value=1 を書き込むだけ。
  ffi.Pointer<ffi.Int32>? _stopPtr;

  /// 生成中フラグ（dispose 時に generate 完了後の unload 遅延のため）。
  bool _generating = false;
  int? _unloadAfterGenerate;

  /// loadModel / generate 等を直列化する簡易キュー。
  Future<void> _tail = Future<void>.value();

  Future<R> _call<R>(Map<String, Object?> cmd) {
    final send = _workerSend;
    if (send == null) {
      return Future<R>.error(StateError('native llm worker not started'));
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    send.send(<String, Object?>{'id': id, ...cmd});
    return completer.future.then((v) => v as R);
  }

  Future<void> _ensureWorker() async {
    if (_worker != null) return;
    final libDir = await _libDir();
    final reply = _replyPort ??= ReceivePort();
    reply.listen((message) {
      if (message is SendPort) {
        if (!_workerReady.isCompleted) _workerReady.complete(message);
        return;
      }
      if (message is Map) {
        final id = message['id'];
        final completer = _pending.remove(id);
        if (completer == null) return;
        if (message.containsKey('error')) {
          completer.completeError(StateError('${message['error']}'));
          return;
        }
        completer.complete(message['result']);
      }
    });
    // メインの SendPort を起動メッセージでワーカーへ渡す（握手の返信先）。
    _worker = await Isolate.spawn(_workerMain, (libDir, reply.sendPort));
    _workerSend = await _workerReady.future.timeout(
      const Duration(seconds: 60),
    );
  }

  @override
  Future<void> loadModel(String modelPath) async {
    if (_disposed) {
      throw StateError('NativeLlmEngine is already disposed.');
    }
    if (_sessionAddr != null) return;
    final task = _tail.then((_) async {
      if (_sessionAddr != null) return;
      await _ensureWorker();
      final res = await _call<Map<Object?, Object?>>({
        'cmd': 'load',
        'modelPath': modelPath,
        'backendKind': backend.kindInt,
        'nCtx': _contextSize,
        'nBatch': _nBatch,
        'nUbatch': _nUbatch,
        'nThreads': _cpuThreads,
        'nGpuLayers': _gpuLayers > 0 ? _gpuLayers : -1,
        'flashAttn': -1,
      });
      final addr = res['addr'] as int? ?? 0;
      if (addr == 0) {
        throw StateError(
          'nllm_load failed: ${res['error'] ?? 'unknown error'}',
        );
      }
      _sessionAddr = addr;
      _resolvedKind = res['kind'] as int? ?? 0;
      final stopAddr = res['stopAddr'] as int? ?? 0;
      // stopAddr が 0 の場合（想定外）は requestStop が no-op になる。
      _stopPtr = stopAddr != 0
          ? ffi.Pointer<ffi.Int32>.fromAddress(stopAddr)
          : null;
      debugPrint(
        'NativeLlmEngine loaded: backendKind=${backend.kindInt} '
        'resolvedKind=$_resolvedKind stopAddr=$stopAddr',
      );
    });
    _tail = task.then((_) {}, onError: (Object _) {});
    return task;
  }

  /// ネイティブが解決したバックエンド種別（0=CPU 1=OpenCL 2=HTP）。
  int? get resolvedKind => _resolvedKind;

  /// エンジンが破棄済みか（セッション共有キャッシュの有効性判定用）。
  bool get isDisposed => _disposed;

  /// セッションがロード済みで再利用可能か（未ロード / 生成中は不可）。
  bool get isReusable => _sessionAddr != null && !_disposed && !_generating;

  /// 要求したスレッド数（実効値ではなく要求値）。
  int get requestedCpuThreads => _cpuThreads;

  /// ネイティブが実際に使ったオフロード層数（kind 既定を含む）。
  int? get resolvedGpuLayers {
    final kind = _resolvedKind;
    if (kind == null) return null;
    if (_gpuLayers > 0) return _gpuLayers;
    return kind == 0 ? 0 : 99;
  }

  /// 表示用 native backend 名。
  String? get backendName {
    switch (_resolvedKind) {
      case 2:
        return 'HTP0 (NPU)';
      case 1:
        return 'OpenCL (GPU)';
      case 0:
        return 'CPU (KleidiAI)';
      default:
        return null;
    }
  }

  @override
  Stream<String> generate({
    required List<LlmChatMessage> messages,
    required LlmGenerationOptions options,
  }) {
    if (_disposed) {
      throw StateError('NativeLlmEngine is already disposed.');
    }
    final session = _sessionAddr;
    if (session == null) {
      throw StateError('Model is not loaded.');
    }
    final controller = StreamController<String>();
    final task = _tail.then((_) async {
      if (controller.isClosed) return;
      await _runGenerate(controller, session, messages, options);
    });
    _tail = task.then((_) {}, onError: (Object _) {});
    return controller.stream;
  }

  Future<void> _runGenerate(
    StreamController<String> controller,
    int session,
    List<LlmChatMessage> messages,
    LlmGenerationOptions options,
  ) async {
    if (_generating) {
      controller.addError(StateError('Another generation is in progress.'));
      await controller.close();
      return;
    }
    _generating = true;

    // トークン配信专用的受信ポート（メイン側）。ワーカーの isolateLocal
    // コールバックが SendPort.send(bytes) した UTF-8 バイトを受け取る。
    final streamPort = ReceivePort();
    final sink = _TokenUtf8Sink(controller);
    streamPort.listen((message) {
      if (message is List<int>) {
        sink.addBytes(message);
      } else if (message is String) {
        // 万が一口在端が違う形態で来てもUTF-8として扱う。
        sink.addBytes(utf8.encode(message));
      }
    });

    try {
      final res = await _call<Map<Object?, Object?>>({
        'cmd': 'generate',
        'session': session,
        'messages': [
          for (final m in messages) [m.role.wireName, m.content],
        ],
        'nGenMax': options.maxTokens,
        'temperature': options.temp,
        'streamPort': streamPort.sendPort,
      });
      final rc = res['rc'] as int? ?? -99;
      sink.finish();
      if (rc == 1) {
        controller.addError(const LlmCancelledException());
      } else if (rc < 0) {
        controller.addError(
          StateError('nllm_generate failed: ${res['error'] ?? 'rc=$rc'}'),
        );
      }
      await controller.close();
    } catch (e) {
      sink.finish();
      if (!controller.isClosed) {
        controller.addError(e);
        await controller.close();
      }
    } finally {
      // 次生成に備えて stop フラグを戻す（未ロードなら null）。
      final stop = _stopPtr;
      if (stop != null) {
        stop.value = 0;
      }
      streamPort.close();
      _generating = false;
      final pendingUnload = _unloadAfterGenerate;
      if (pendingUnload != null) {
        _unloadAfterGenerate = null;
        await _unloadNow(pendingUnload);
      }
    }
  }

  /// 生成中にトークン境界での停止を要求する。
  ///
  /// atomic アドレス方式: メイン isolate は保持中の `Pointer<Int32>` に
  /// 1 を書き込むだけ（C 関数呼び出しではない＝dlopen / 追加 isolate 不要）。
  /// ワーカーの生成ループが atomic_load(&s->stop) で検知して協力停止する。
  /// 未ロード（_stopPtr が null）は何もしない（no-op・二重 stop も安全）。
  void requestStop() {
    final stop = _stopPtr;
    if (stop == null) return;
    try {
      stop.value = 1;
    } catch (e) {
      debugPrint('NativeLlmEngine.requestStop failed: $e');
    }
  }

  /// テキストのトークン数を実測（未ロードは例外）。
  Future<int> countTokens(String text) async {
    final session = _sessionAddr;
    if (session == null) {
      throw StateError('Model is not loaded.');
    }
    return _call<int>({'cmd': 'countTokens', 'session': session, 'text': text});
  }

  /// 直近 1 生成分のネイティブ perf（取得不可能は null）。
  Future<LlmNativePerf?> readNativePerf() async {
    final session = _sessionAddr;
    if (session == null || _disposed) return null;
    try {
      final res = await _call<Map<Object?, Object?>>({
        'cmd': 'getStats',
        'session': session,
      });
      final ppTps = (res['ppTps'] as num?)?.toDouble() ?? 0;
      final tgTps = (res['tgTps'] as num?)?.toDouble() ?? 0;
      final nPrompt = (res['nPrompt'] as num?)?.toInt() ?? 0;
      final nGen = (res['nGen'] as num?)?.toInt() ?? 0;
      return LlmNativePerf(
        promptEvalMs: (ppTps > 0 && nPrompt > 0)
            ? nPrompt * 1000 / ppTps
            : null,
        promptEvalTokens: nPrompt > 0 ? nPrompt : null,
        evalMs: (tgTps > 0 && nGen > 0) ? nGen * 1000 / tgTps : null,
        evalTokens: nGen > 0 ? nGen : null,
        stopReason: (res['stopReason'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final session = _sessionAddr;
    _sessionAddr = null;
    // session と同時に stop フラグも失効する（unload 後に書くと UAF）。
    // ただし generate 実行中は まだ session 生存なので、完了後 unload まで
    // pointer は保持し、_unloadNow 後に null 化する。
    if (session == null) {
      _stopPtr = null;
      _killWorker();
      return;
    }
    if (_generating) {
      // generate 実行中: まず停止要求し、完了後に unload する。
      requestStop();
      _unloadAfterGenerate = session;
      return;
    }
    unawaited(_unloadNow(session));
  }

  Future<void> _unloadNow(int session) async {
    try {
      await _call<bool>({'cmd': 'unload', 'session': session});
    } catch (_) {}
    // session は解放済み。stop フラグアドレスは無効になるので必ず null 化。
    _stopPtr = null;
    _killWorker();
  }

  void _killWorker() {
    _worker?.kill(priority: Isolate.beforeNextEvent);
    _worker = null;
    _workerSend = null;
    _replyPort?.close();
    _replyPort = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('NativeLlmEngine disposed.'));
      }
    }
    _pending.clear();
  }
}

/// トークン UTF-8 バイト列 → 文字列（マルチバイト分割対策）デコーダ。
class _TokenUtf8Sink {
  _TokenUtf8Sink(this.controller);

  final StreamController<String> controller;
  final List<int> _pending = [];

  void addBytes(List<int> bytes) {
    _pending.addAll(bytes);
    _flush(false);
  }

  void finish() {
    _flush(true);
  }

  void _flush(bool flushAll) {
    final bytes = _pending;
    if (bytes.isEmpty) return;
    var consumed = 0;
    String? decoded;
    for (var take = bytes.length; take > 0 && consumed == 0; take--) {
      try {
        decoded = utf8.decode(bytes.sublist(0, take));
        consumed = take;
      } on FormatException {
        // 末尾が未完了のマルチバイト → 1バイトずつ縮めて再試行。
        continue;
      }
    }
    if (consumed > 0) {
      controller.add(decoded!);
      bytes.removeRange(0, consumed);
    }
    if (flushAll && bytes.isNotEmpty) {
      // 完了時に未消化（不正列）→ 損失回避で allowMalformed 変換。
      controller.add(utf8.decode(bytes, allowMalformed: true));
      bytes.clear();
    }
  }
}

// ---------------------------------------------------------------------------
// ワーカー isolate 側
// ---------------------------------------------------------------------------

/// ワーカー isolate 本体: ネイティブ呼び出しを直列実行する。
///
/// プロトコル:
/// 1. 起動後最初に自分の SendPort をメインへ送る（ハンドシェイク）。
/// 2. {id, cmd, ...} を受信して処理し、{id, result} または {id, error} を返す。
///
/// .so の dlopen はここで1回だけ行う（メインは C 関数を呼ばない）。
void _workerMain((String, SendPort) boot) {
  final (libDir, mainSend) = boot;
  final receive = ReceivePort();
  // 自分の SendPort を『メインの SendPort 宛』に送る。
  // （受信側 ReceivePort はまだ listen 前でもメッセージはキューされる）。
  mainSend.send(receive.sendPort);

  NativeLlmLib? lib;
  try {
    lib = NativeLlmLib(ffi.DynamicLibrary.open('$libDir/libnative_llm.so'));
    final dirPtr = libDir.toNativeUtf8();
    final errbuf = calloc<ffi.Char>(512);
    final rc = lib.init(dirPtr, errbuf.cast(), 512);
    calloc.free(dirPtr);
    if (rc != 0) {
      debugPrint('nllm_init rc=$rc ${errbuf.cast<Utf8>().toDartString()}');
    }
    calloc.free(errbuf);
  } catch (e) {
    debugPrint('NativeLlmEngine worker init failed: $e');
    lib = null;
  }

  // 応答は必ず『メインの SendPort（mainSend）』へ送る。
  // receive.sendPort はワーカー自身の受信ポートなので、ここへ応答を
  // 送ると自分の listen に無限ループバックしてハングする（真因）。
  // トークン配信は generate 応答内で mainSend ではなく streamPort 経由。
  receive.listen((message) {
    if (message is! Map) return;
    final id = message['id'];
    if (lib == null) {
      mainSend.send(<Object?, Object?>{
        'id': id,
        'error': 'native library unavailable',
      });
      return;
    }
    try {
      mainSend.send(<Object?, Object?>{
        'id': id,
        'result': _handle(lib, message),
      });
    } catch (e) {
      mainSend.send(<Object?, Object?>{'id': id, 'error': e.toString()});
    }
  });
}

Object? _handle(NativeLlmLib lib, Map<Object?, Object?> msg) {
  switch (msg['cmd']) {
    case 'load':
      return _doLoad(lib, msg);
    case 'generate':
      return _doGenerate(lib, msg);
    case 'countTokens':
      return _doCountTokens(lib, msg);
    case 'getStats':
      return _doGetStats(lib, msg);
    case 'unload':
      lib.unload(ffi.Pointer.fromAddress(msg['session'] as int));
      return true;
    default:
      throw StateError('unknown cmd ${msg['cmd']}');
  }
}

Map<Object?, Object?> _doLoad(NativeLlmLib lib, Map<Object?, Object?> msg) {
  final errbuf = calloc<ffi.Char>(512);
  final pathPtr = (msg['modelPath'] as String).toNativeUtf8();
  try {
    final session = lib.load(
      pathPtr,
      msg['backendKind'] as int,
      msg['nCtx'] as int,
      msg['nBatch'] as int,
      msg['nUbatch'] as int,
      msg['nThreads'] as int,
      msg['nGpuLayers'] as int,
      msg['flashAttn'] as int,
      errbuf.cast(),
      512,
    );
    if (session.address == 0) {
      return <Object?, Object?>{
        'addr': 0,
        'error': errbuf.cast<Utf8>().toDartString(),
      };
    }
    // stopFlagAddr は新規シンボル。可視性/解決失敗でロード応答自体を
    // 壊さないよう防御的に扱う（失敗時は stopAddr=0 → requestStop は no-op、
    // 生成は動作するがキャンセル不可になる）。デバッグ用に必ず結果を残す。
    int stopAddr = 0;
    try {
      stopAddr = lib.stopFlagAddr(session).address;
    } catch (_) {
      // 解決失敗時は stopAddr=0 → requestStop は no-op（生成は動作可）。
      stopAddr = 0;
    }
    return <Object?, Object?>{
      'addr': session.address,
      'kind': lib.sessionKind(session),
      'stopAddr': stopAddr,
    };
  } finally {
    calloc.free(pathPtr);
    calloc.free(errbuf);
  }
}

Map<Object?, Object?> _doGenerate(NativeLlmLib lib, Map<Object?, Object?> msg) {
  final session = ffi.Pointer<ffi.Void>.fromAddress(msg['session'] as int);
  final streamSend = msg['streamPort'] as SendPort;
  final messages = (msg['messages'] as List).cast<List<Object?>>();
  final msgsPtr = calloc<LlamaChatMessageFfi>(messages.length);
  final errbuf = calloc<ffi.Char>(512);
  final ptrs = <ffi.Pointer<Utf8>>[];

  // ワーカー isolate 内で完結するトークンコールバック。
  // nllm_generate はワーカーの Dart スレッド上で同期的に走るため、
  // on_token も同じスレッドから呼ばれる → isolateLocal で直接実行でき、
  // その中で SendPort.send してメインへ UTF-8 バイトを流す。
  // piece は native malloc 済み → コピー後に必ず freeNativePiece で解放。
  final cb = ffi.NativeCallable<NllmTokenCbNative>.isolateLocal((
    ffi.Pointer<Utf8> piece,
    int len,
    ffi.Pointer<ffi.Void> userData,
  ) {
    if (piece.address == 0 || len <= 0) return;
    final bytes = Uint8List.fromList(piece.cast<ffi.Uint8>().asTypedList(len));
    streamSend.send(bytes);
    lib.freeNativePiece(piece.cast());
  });

  try {
    for (var i = 0; i < messages.length; i++) {
      final r = (messages[i][0] as String).toNativeUtf8();
      final c = (messages[i][1] as String).toNativeUtf8();
      ptrs
        ..add(r)
        ..add(c);
      msgsPtr[i].role = r;
      msgsPtr[i].content = c;
    }
    final rc = lib.generate(
      session,
      msgsPtr,
      messages.length,
      msg['nGenMax'] as int,
      (msg['temperature'] as num).toDouble(),
      cb.nativeFunction,
      ffi.Pointer.fromAddress(0),
      errbuf.cast(),
      512,
    );
    return <Object?, Object?>{
      'rc': rc,
      'error': rc < 0 ? errbuf.cast<Utf8>().toDartString() : null,
    };
  } finally {
    cb.close();
    for (final p in ptrs) {
      calloc.free(p);
    }
    calloc.free(msgsPtr);
    calloc.free(errbuf);
  }
}

int _doCountTokens(NativeLlmLib lib, Map<Object?, Object?> msg) {
  final session = ffi.Pointer<ffi.Void>.fromAddress(msg['session'] as int);
  final text = (msg['text'] as String).toNativeUtf8();
  try {
    return lib.countTokens(session, text, 0);
  } finally {
    calloc.free(text);
  }
}

Map<Object?, Object?> _doGetStats(NativeLlmLib lib, Map<Object?, Object?> msg) {
  final session = ffi.Pointer<ffi.Void>.fromAddress(msg['session'] as int);
  final pp = calloc<ffi.Double>();
  final tg = calloc<ffi.Double>();
  final np = calloc<ffi.Int32>();
  final ng = calloc<ffi.Int32>();
  try {
    lib.getStats(session, pp, tg, np, ng);
    return <Object?, Object?>{
      'ppTps': pp.value,
      'tgTps': tg.value,
      'nPrompt': np.value,
      'nGen': ng.value,
      'stopReason': lib.stopReason(session),
    };
  } finally {
    calloc.free(pp);
    calloc.free(tg);
    calloc.free(np);
    calloc.free(ng);
  }
}
