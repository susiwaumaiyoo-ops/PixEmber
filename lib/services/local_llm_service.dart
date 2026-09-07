import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart'
    show
        GenerationParams,
        LlamaBackend,
        LlamaChatMessage,
        LlamaCompletionChunk,
        GpuBackend,
        LlamaEngine,
        ModelParams;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm_model_preset.dart';

/// ローカルLLM（llama.cpp）のサービス状態。
enum LlmState {
  /// 初期状態・モデル未ロード、または生成が完了・キャンセルされた後。
  idle,

  /// モデルの読み込み中（ファイル検証・エンジン生成・ネイティブロード）。
  loading,

  /// トークン生成中。
  generating,

  /// 直近の生成が正常完了した。
  done,

  /// 直近の操作が失敗した（[LocalLlmService.errorMessage] 参照）。
  error,
}

/// 直近1回の生成メトリクス（M5 + B: 待ち時間内訳）。
class LlmGenerationStats {
  const LlmGenerationStats({
    required this.generatedTokens,
    required this.elapsed,
    this.timeToFirstTokenMs,
    this.loadMs,
    this.backend,
    this.thinkingEnabled,
    this.requestedThreads,
    this.requestedThreadsBatch,
    this.resolvedGpuLayers,
    this.backendName,
    this.usedCpuFallback,
    this.nativePromptEvalMs,
    this.nativePromptEvalTokens,
    this.nativeEvalMs,
    this.nativeEvalTokens,
  });

  /// 生成したトークン数（非空チャンク数の近似）。
  final int generatedTokens;

  /// 生成に要した実時間。
  final Duration elapsed;

  /// 生成開始 → 最初の表示用 content までの実測ミリ秒（B）。不明なら null。
  final int? timeToFirstTokenMs;

  /// 直近のモデルロードに要した実測ミリ秒（B・再ロード skip 時は 0）。不明なら null。
  final int? loadMs;

  /// 実際に使用した backend ラベル（llama_cpp 等）。
  final String? backend;

  /// engine 呼び出しに渡した thinking 設定（false = thinking 無効を明示）。
  final bool? thinkingEnabled;

  /// 要求した推論スレッド数（numberOfThreads。0 = 自動）。
  final int? requestedThreads;

  /// 要求したバッチ用スレッド数（numberOfThreadsBatch。0 = 自動）。
  final int? requestedThreadsBatch;

  /// ネイティブが解決した GPU オフロード層数（取得できない場合は null）。
  final int? resolvedGpuLayers;

  /// ネイティブ backend 名（取得できない場合は null）。
  final String? backendName;

  /// Vulkan ロード失敗により CPU へフォールバックしたか。
  final bool? usedCpuFallback;

  /// ネイティブ計測: プロンプト評価時間(ms)（取得できない場合は null）。
  final double? nativePromptEvalMs;

  /// ネイティブ計測: プロンプト評価トークン数。
  final int? nativePromptEvalTokens;

  /// ネイティブ計測: 生成評価時間(ms)（取得できない場合は null）。
  final double? nativeEvalMs;

  /// ネイティブ計測: 生成評価トークン数。
  final int? nativeEvalTokens;

  /// ネイティブ計測に基づく生成速度（取得できない場合は null）。
  double? get nativeTokensPerSecond {
    final ms = nativeEvalMs;
    final n = nativeEvalTokens;
    if (ms == null || ms <= 0 || n == null || n <= 0) return null;
    return n * 1000 / ms;
  }

  /// 1秒あたりの生成トークン数（計測不能なら 0.0）。
  ///
  /// 修正前は elapsed（TTFT を含む全体時間）が分母で、prefill が長い
  /// 実機で過小評価されていた。TTFT が取れる場合は「最初の出力以降の
  /// 経過時間」をデコード時間の近似として使う。ネイティブ計測
  /// （[nativeTokensPerSecond]）が取れる場合は UI はそちらを優先表示する。
  double get tokensPerSecond {
    if (generatedTokens == 0) return 0.0;
    final ms = elapsed.inMilliseconds;
    if (ms <= 0) return 0.0;
    final ttft = timeToFirstTokenMs;
    final decodeMs = (ttft == null || ttft <= 0 || ttft >= ms) ? ms : ms - ttft;
    return generatedTokens * 1000 / decodeMs;
  }
}

/// llamadart ネイティブ（llama.cpp）から取得した 1 生成分の計測値。
///
/// llama.cpp は生成開始時に perf カウンタをリセットする
/// （llamadart 0.8.22 llama_cpp_service.dart の generate 前リセットを確認）
/// ため 1 生成分の値。取得できない項目は null（推定値は報告しない）。
class LlmNativePerf {
  const LlmNativePerf({
    this.promptEvalMs,
    this.promptEvalTokens,
    this.evalMs,
    this.evalTokens,
  });

  final double? promptEvalMs;
  final int? promptEvalTokens;
  final double? evalMs;
  final int? evalTokens;
}

/// ローカルLLMの実行設定（A/B: CPUスレッド数・推論バックエンド）。
class LlmRuntimeSettings {
  const LlmRuntimeSettings({this.cpuThreads = 0, this.useVulkan = false});

  /// SharedPreferences キー。
  static const String prefKeyCpuThreads = 'llm_pref_cpu_threads';
  static const String prefKeyUseVulkan = 'llm_pref_use_vulkan';

  /// スレッド数の選択肢（0 = 自動・現状の基準。1 は診断用）。
  static const List<int> cpuThreadChoices = <int>[0, 1, 2, 4];

  /// 要求する推論スレッド数（0 = llama.cpp の自動）。numberOfThreads と
  /// numberOfThreadsBatch の両方に同じ要求値を渡す（実効値は取得不能なため
  /// UI には「要求値」として表示する）。
  final int cpuThreads;

  /// Vulkan（GPU）を要求するか。未対応端末ではロード失敗時に CPU へ
  /// 1 回だけフォールバックする（ユーザーの明示操作でのみ有効）。
  final bool useVulkan;

  LlmRuntimeSettings copyWith({int? cpuThreads, bool? useVulkan}) =>
      LlmRuntimeSettings(
        cpuThreads: cpuThreads ?? this.cpuThreads,
        useVulkan: useVulkan ?? this.useVulkan,
      );

  /// 保存された設定を読む（不正値は既定に戻す）。
  static Future<LlmRuntimeSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getInt(prefKeyCpuThreads) ?? 0;
      final vulkan = prefs.getBool(prefKeyUseVulkan) ?? false;
      return LlmRuntimeSettings(
        cpuThreads: cpuThreadChoices.contains(t) ? t : 0,
        useVulkan: vulkan,
      );
    } catch (_) {
      return const LlmRuntimeSettings();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LlmRuntimeSettings &&
      other.cpuThreads == cpuThreads &&
      other.useVulkan == useVulkan;

  @override
  int get hashCode => Object.hash(cpuThreads, useVulkan);
}

/// 生成キャンセルを示す例外（UIはエラー表示にしない）。
class LlmCancelledException implements Exception {
  const LlmCancelledException();
  @override
  String toString() => 'Generation cancelled.';
}

/// 推論エンジンの抽象化（テスト用の fake 差し替え用）。
///
/// 本番は [LlamaDartEngine]（llamadart）。モデルロード・トークン生成は
/// llamadart が起動する worker isolate 内で実行され UI スレッドをブロックしない。
abstract class LlmInferenceEngine {
  /// モデルをロードする（テストの fake 実装は no-op でよい）。
  Future<void> loadModel(String modelPath);

  /// [messages] を与え、トークンをストリームで返す。
  Stream<LlamaCompletionChunk> generate({
    required List<LlamaChatMessage> messages,
    required GenerationParams options,
  });

  /// 使用済みリソースを解放する。
  void dispose();
}

/// llamadart による本番実装。
class LlamaDartEngine implements LlmInferenceEngine {
  LlamaDartEngine({
    int contextSize = 8192,
    int gpuLayers = 0,
    int cpuThreads = 0,
    bool useVulkan = false,
  }) : _contextSize = contextSize,
       _gpuLayers = gpuLayers,
       _cpuThreads = cpuThreads,
       _useVulkan = useVulkan,
       _engine = LlamaEngine(LlamaBackend());

  /// 実際に使用した backend のラベル（メトリクス表示用）。
  static const String backendLabel = 'llama_cpp';

  final int _contextSize;
  final int _gpuLayers;
  final int _cpuThreads;
  final bool _useVulkan;
  final LlamaEngine _engine;
  bool _loaded = false;
  bool _disposed = false;
  int? _resolvedGpuLayers;
  String? _backendName;

  /// 要求したスレッド数（実効値は取得不能なため要求値を表示する）。
  int get requestedCpuThreads => _cpuThreads;

  /// ネイティブが解決した GPU 層数（取得失敗時は null）。
  int? get resolvedGpuLayers => _resolvedGpuLayers;

  /// ネイティブ backend 名（取得失敗時は null）。
  String? get backendName => _backendName;

  /// ネイティブ（llama.cpp）の 1 生成分 perf 計測を取得する。
  /// 取得できない場合は null（推定しない）。
  Future<LlmNativePerf?> readNativePerf() async {
    if (!_loaded || _disposed) return null;
    try {
      final perf = await _engine.getPerformanceContext();
      if (perf == null) return null;
      return LlmNativePerf(
        promptEvalMs: perf.promptEvalMs,
        promptEvalTokens: perf.promptEvalTokens,
        evalMs: perf.evalMs,
        evalTokens: perf.evalTokens,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> loadModel(String modelPath) async {
    if (_disposed) {
      throw StateError('LlamaDartEngine is already disposed.');
    }
    if (_loaded) return;
    // B: Vulkan 要求時は全層オフロード（ModelParams.maxGpuLayers = 999、
    // 存在確認済み定数）と preferredBackend: vulkan を明示する。
    // llamadart 側の Android 向け保守設定・Qwen3.5 例外は変更しない。
    // Vulkan 非要求時は CPU 強制（Android の auto は llamadart が CPU に
    // 解決するため、挙動を明示的に固定する）。
    await _engine.loadModel(
      modelPath,
      modelParams: ModelParams(
        contextSize: _contextSize,
        gpuLayers: _useVulkan ? ModelParams.maxGpuLayers : _gpuLayers,
        preferredBackend: _useVulkan ? GpuBackend.vulkan : GpuBackend.cpu,
        numberOfThreads: _cpuThreads,
        numberOfThreadsBatch: _cpuThreads,
      ),
    );
    _loaded = true;
    // ロード後の診断値（表示専用。失敗は握り潰す）。
    try {
      _resolvedGpuLayers = await _engine.getResolvedGpuLayers();
    } catch (_) {
      _resolvedGpuLayers = null;
    }
    try {
      _backendName = await _engine.getBackendName();
    } catch (_) {
      _backendName = null;
    }
  }

  @override
  Stream<LlamaCompletionChunk> generate({
    required List<LlamaChatMessage> messages,
    required GenerationParams options,
  }) {
    if (_disposed) {
      throw StateError('LlamaDartEngine is already disposed.');
    }
    // B: thinking を無効化して engine 呼び出しに明示的に届かせる
    // （要約は 3 セクション形式出力のみを必要とし、推論チャネルは不要）。
    return _engine.create(messages, params: options, enableThinking: false);
  }

  /// プロンプトのトークン数を実測する（B）。llamadart の [LlamaEngine.tokenize]
  /// （ネイティブのトークナイザ）を利用する。未ロード時は例外を投げるため
  /// 呼び出し側で握り潰す前提。
  Future<int> promptTokenCount(List<LlamaChatMessage> messages) async {
    final prompt = messages.map((m) => m.content).join('\n');
    final tokens = await _engine.tokenize(prompt);
    return tokens.length;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_engine.dispose().catchError((Object _) {}));
  }
}

/// ローカルLLM推論を司るサービス（llamadart ラッパー）。
///
/// 状態機械: idle / loading / generating / done / error。
/// [onStateChange] で状態遷移、[generate] の onToken でストリーミング配信。
///
/// 規約:
/// - [dispose] 以降は [onStateChange] を絶対に呼ばない（setState 後の dispose 対策）。
/// - [cancel] はストリーム購読を破棄して idle に戻す。
///   購読破棄は llamadart の cancel token に伝播し、worker isolate が
///   次のトークン境界でデコードを停止する（実キャンセル）。
class LocalLlmService {
  /// [engineFactory] 未指定時は llama.cpp 実装（[LlamaDartEngine]）を使う。
  ///
  /// [preset] は [engineFactory] 未指定時にエンジンへ渡される推論プリセット。
  /// 通常はカタログ fileName で解決した値
  /// （[LlmInferencePreset.resolveForFileName]）を渡す。
  LocalLlmService({
    LlmInferenceEngine Function(String modelPath)? engineFactory,
    LlmInferencePreset preset = LlmInferencePreset.defaults,
    LlmRuntimeSettings runtimeSettings = const LlmRuntimeSettings(),
  }) : _preset = preset,
       runtimeSettings = runtimeSettings,
       _customEngineFactory = engineFactory;

  /// 要約生成向けコンテキストサイズ（本文2000字+プロンプト+出力に余力）。
  static const int defaultContextSize = 8192;

  /// 要約生成向けサンプリング（低温度で安定した出力を取る）。
  static const GenerationParams defaultGenerationOptions = GenerationParams(
    temp: 0.2,
    topP: 0.9,
    maxTokens: 1024,
  );

  final LlmInferenceEngine Function(String modelPath)? _customEngineFactory;
  final LlmInferencePreset _preset;

  /// 現在要求されている実行設定（A/B）。
  LlmRuntimeSettings runtimeSettings;

  /// 直近のロードで実際に適用した設定（再利用判定に使用）。
  LlmRuntimeSettings _currentSettings = const LlmRuntimeSettings();
  bool _lastLoadUsedCpuFallback = false;

  LlmState _state = LlmState.idle;
  String? _errorMessage;
  bool _disposed = false;
  bool _busy = false;
  bool _cancelled = false;
  LlmInferenceEngine? _engine;
  String? _currentModelPath;
  LlmGenerationStats? _lastGenerationStats;

  /// 状態遷移通知。[dispose] 以降は呼ばれない。
  void Function(LlmState state, String? error)? onStateChange;

  LlmState get state => _state;
  String? get errorMessage => _errorMessage;
  bool get isDisposed => _disposed;
  bool get isBusy => _busy;
  String? get modelPath => _currentModelPath;

  /// コンストラクタで渡された推論プリセット（M5）。
  LlmInferencePreset get preset => _preset;

  /// 直近のロードが Vulkan 失敗 → CPU フォールバックだったか。
  bool get lastLoadUsedCpuFallback => _lastLoadUsedCpuFallback;

  /// エンジンを生成する（カスタムファクトリ（テスト）優先。
  /// 実機は [LlmRuntimeSettings] を ModelParams へ反映する）。
  LlmInferenceEngine _newEngine(String modelPath, LlmRuntimeSettings s) {
    final custom = _customEngineFactory;
    if (custom != null) return custom(modelPath);
    return LlamaDartEngine(
      contextSize: _preset.contextSize,
      gpuLayers: _preset.gpuLayers,
      cpuThreads: s.cpuThreads,
      useVulkan: s.useVulkan,
    );
  }

  /// プリセットに基づく生成オプション（M5）。
  ///
  /// maxTokens はプリセットの maxOutputTokens（温度等は従来値を維持）。
  GenerationParams get generationOptions => GenerationParams(
    temp: 0.2,
    topP: 0.9,
    maxTokens: _preset.maxOutputTokens,
  );

  /// 直近の生成メトリクス（M5）。生成成功時に更新、generate 開始時にクリア。
  LlmGenerationStats? get lastGenerationStats => _lastGenerationStats;

  /// 直近のモデルロード所要時間（ミリ秒・B）。同一モデル再利用時は 0。
  int? _lastLoadMs;
  int? get lastLoadMs => _lastLoadMs;

  /// プロンプトのトークン数を実測する（B）。
  ///
  /// llamadart の tokenize API（ネイティブトークナイザ）が利用できる場合は
  /// 実測値を返す。テストの fake エンジンやネイティブ未ロードなどで
  /// 実測できない場合は null（= 「個別取得不可」。推定値は返さない）。
  Future<int?> promptTokenCount(List<LlamaChatMessage> messages) async {
    final engine = _engine;
    if (engine is! LlamaDartEngine) return null;
    try {
      return await engine.promptTokenCount(messages);
    } catch (_) {
      return null;
    }
  }

  void _transition(LlmState next, {String? error}) {
    if (_disposed) return;
    _state = next;
    _errorMessage = error;
    onStateChange?.call(next, error);
  }

  /// [path] に GGUF が妥当に配置されているか（存在 + 非0バイト）。
  Future<bool> isModelFileReady(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      return await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// [isModelFileReady] の同期版（loadModel 内部検証用）。
  static bool _isModelFileSyncReady(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      return file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  /// モデルを読み込む（ファイル検証 + エンジン生成 + 実際のロード）。
  ///
  /// 実際のロードは llamadart の worker isolate 内で実行され、
  /// UI スレッドはブロックされない。
  ///
  /// 成功: true（state -> idle）。ファイル不在・ロード失敗: false（state -> error）。
  Future<bool> loadModel(String modelPath) async {
    if (_disposed || _busy) return false;
    // B: 同一モデルがロード済みなら再ロードしない（シート再表示・再試行の
    // ボトルネック排除。重みはそのまま再利用する）。
    // 再利用条件: モデルパスに加え、ロード時に適用する実行設定
    // （スレッド数・バックエンド・gpuLayers 等）が完全一致する場合のみ。
    // 設定が変わった場合は古いエンジンを再利用しない。
    if (_engine != null &&
        _currentModelPath == modelPath &&
        _currentSettings == runtimeSettings &&
        !_cancelled) {
      _lastLoadMs = 0;
      return true;
    }
    _busy = true;
    _transition(LlmState.loading);
    final loadWatch = Stopwatch()..start();
    try {
      // 同期 stat（1ファイルの stat は軽量。非同期I/Oは FakeAsync テスト
      // （モデル切替シート等）で完了しないため同期で検証する）。
      if (!_isModelFileSyncReady(modelPath)) {
        throw StateError('Model file not found: $modelPath');
      }
      _engine?.dispose();
      LlmInferenceEngine? engine;
      try {
        engine = _newEngine(modelPath, runtimeSettings);
        await engine.loadModel(modelPath);
      } catch (_) {
        // 失敗したエンジンは確実に解放する（同時にロードするのは常時1つ）。
        try {
          engine?.dispose();
        } catch (_) {}
        rethrow;
      }
      loadWatch.stop();
      _lastLoadMs = loadWatch.elapsedMilliseconds;
      _lastLoadUsedCpuFallback = false;
      _engine = engine;
      _currentModelPath = modelPath;
      _currentSettings = runtimeSettings;
      _transition(LlmState.idle);
      return true;
    } catch (e) {
      // B: Vulkan 要求でのロード失敗は、失敗したエンジンを解放して
      // CPU 設定で 1 回だけ再試行する（未対応端末でのクラッシュ防止）。
      if (runtimeSettings.useVulkan && !_lastLoadUsedCpuFallback) {
        try {
          final cpuSettings = runtimeSettings.copyWith(useVulkan: false);
          final cpuEngine = _newEngine(modelPath, cpuSettings);
          await cpuEngine.loadModel(modelPath);
          loadWatch.stop();
          _lastLoadMs = loadWatch.elapsedMilliseconds;
          _lastLoadUsedCpuFallback = true;
          _engine = cpuEngine;
          _currentModelPath = modelPath;
          _currentSettings = cpuSettings;
          // 以後のロード要求が実際に動作している CPU 設定と比較されるよう、
          // 実行要求値を実値へ同期する（再利用判定の一致）。
          runtimeSettings = cpuSettings;
          _transition(LlmState.idle);
          return true;
        } catch (_) {
          // CPU 再試行も失敗 → 元のエラーとして扱う。
        }
      }
      _transition(LlmState.error, error: _friendlyError(e));
      return false;
    } finally {
      _busy = false;
    }
  }

  /// [messages] からテキストを生成し、トークンを onToken でストリーム配信。
  ///
  /// 成功: 完全テキストを返す（state -> done）。
  /// 失敗: Exception を投げる（state -> error）。
  /// キャンセル: [LlmCancelledException]（state -> idle）。
  Future<String> generate(
    List<LlamaChatMessage> messages, {
    void Function(String piece)? onToken,
    GenerationParams? options,
  }) async {
    if (_disposed) {
      throw StateError('LocalLlmService is already disposed.');
    }
    if (_busy) {
      throw StateError('Another operation is already in progress.');
    }
    final engine = _engine;
    if (engine == null) {
      throw StateError('Model is not loaded. Call loadModel() first.');
    }
    _busy = true;
    _cancelled = false;
    _lastGenerationStats = null;
    _transition(LlmState.generating);
    final buffer = StringBuffer();
    var generatedTokens = 0;
    int? ttftMs;
    final stopwatch = Stopwatch()..start();
    try {
      final stream = engine.generate(
        messages: messages,
        options: options ?? defaultGenerationOptions,
      );
      // await for でストリームを最後まで消費する。ジェネレータの完了と
      // ループ終了が完全同期するため、FakeAsync の widget テスト
      // （モデル切替シート等）でも確実に完了する。
      // キャンセルは cancel() でフラグを立て、次のトークンで
      // LlmCancelledException を投げてループを抜ける
      // （await for が自動的に購読を破棄する）。
      await for (final chunk in stream) {
        if (_cancelled) {
          throw const LlmCancelledException();
        }
        final piece = _chunkText(chunk);
        if (piece.isEmpty) continue;
        generatedTokens++;
        ttftMs ??= stopwatch.elapsedMilliseconds;
        buffer.write(piece);
        onToken?.call(piece);
      }
      if (_cancelled) {
        throw const LlmCancelledException();
      }
      stopwatch.stop();
      // B: backend/thinking は実エンジンで確定した値のみ報告する
      // （fake エンジンでは「実測不能」として null を返す）。
      final native = engine is LlamaDartEngine ? engine : null;
      LlmNativePerf? nativePerf;
      if (native != null) {
        try {
          nativePerf = await native.readNativePerf();
        } catch (_) {
          nativePerf = null;
        }
      }
      _lastGenerationStats = LlmGenerationStats(
        generatedTokens: generatedTokens,
        elapsed: stopwatch.elapsed,
        timeToFirstTokenMs: ttftMs,
        loadMs: _lastLoadMs,
        backend: native != null ? LlamaDartEngine.backendLabel : null,
        thinkingEnabled: native != null ? false : null,
        requestedThreads: native?.requestedCpuThreads,
        requestedThreadsBatch: native?.requestedCpuThreads,
        resolvedGpuLayers: native?.resolvedGpuLayers,
        backendName: native?.backendName,
        usedCpuFallback: native != null ? _lastLoadUsedCpuFallback : null,
        nativePromptEvalMs: nativePerf?.promptEvalMs,
        nativePromptEvalTokens: nativePerf?.promptEvalTokens,
        nativeEvalMs: nativePerf?.evalMs,
        nativeEvalTokens: nativePerf?.evalTokens,
      );
      _transition(LlmState.done);
      return buffer.toString();
    } catch (e) {
      if (e is LlmCancelledException) {
        _transition(LlmState.idle);
        rethrow;
      }
      _transition(LlmState.error, error: _friendlyError(e));
      rethrow;
    } finally {
      _busy = false;
    }
  }

  /// 生成中であることをキャンセルする（state -> idle）。
  ///
  /// 次のトークンで生成ループを中断する（await for が購読を破棄する。
  /// llamadart でもトークン境界でデコードが停止する）。
  void cancel() {
    if (!_busy) return;
    _cancelled = true;
  }

  /// サービスを終了する。以降は [onStateChange] は呼ばれない。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelled = true;
    _engine?.dispose();
    _engine = null;
    _currentModelPath = null;
    onStateChange = null;
  }

  /// ストリームチャンクからテキスト差分を抽出する。
  static String _chunkText(LlamaCompletionChunk chunk) {
    if (chunk.choices.isEmpty) return '';
    return chunk.choices.first.delta.content ?? '';
  }

  /// 生メッセージをユーザー表示用に変換する（本文・URL等は出力しない）。
  static String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('Model file not found')) {
      return 'モデルファイルが見つかりません。設定で GGUF の配置先を確認してください。';
    }
    if (msg.contains('Model is not loaded')) {
      return 'モデルが未ロードです。';
    }
    final firstLine = msg.split('\n').first.trim();
    final clipped = firstLine.length > 200
        ? '${firstLine.substring(0, 200)}…'
        : firstLine;
    return 'ローカルAIの動作に失敗しました: $clipped';
  }
}

/// モデルファイルの配置・解決（M4 以降はアプリ内ダウンロードに対応）。
///
/// - 既定ディレクトリ: `documents/models/llm`（既存ファイル・非再帰）
/// - 取り込み（カスタム）: `documents/models/llm/imported`
/// - アプリ内ダウンロード（管理）: `cache/models/llm/managed`
class LlmModelPaths {
  LlmModelPaths._();

  /// SharedPreferences のキー（選択済みモデルの絶対パスを保存）。
  static const String prefsKey = 'llm_summary_model_path';

  /// 本 PoC は Android 先行。その他のプラットフォームでは機能を提供しない。
  static bool isSupportedPlatform() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android;
  }

  /// 既定モデルディレクトリ: `getApplicationDocumentsDirectory()/models/llm`。
  /// 存在しなければ作成する。
  static Future<Directory> defaultDir() async {
    final appDoc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDoc.path, 'models', 'llm'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// アプリ内ダウンロード（M4）の管理ディレクトリ:
  /// `getApplicationCacheDirectory()/models/llm/managed`。
  /// 存在しなければ作成する。
  ///
  /// 注意: Android ではキャッシュディレクトリは OS により消去され得る
  /// （再ダウンロードで復旧する）。
  static Future<Directory> managedDir() async {
    final cache = await getApplicationCacheDirectory();
    final dir = Directory(p.join(cache.path, 'models', 'llm', 'managed'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// ピッカー取り込み（カスタム）モデルのディレクトリ:
  /// `defaultDir()/imported`（= `documents/models/llm/imported`）。
  /// 存在しなければ作成する。
  static Future<Directory> importedDir() async {
    final base = await defaultDir();
    final dir = Directory(p.join(base.path, 'imported'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// GGUF ファイルパス一覧（ソート済み・重複排除）。
  ///
  /// [dirPath] 指定時はその 1 ディレクトリ配下（非再帰）をスキャンする
  /// （既存挙動）。未指定時は 既定ディレクトリ（再帰: imported/ 含む）と
  /// 管理ディレクトリ（再帰） をスキャンする。
  /// 読み取り失敗時は空リストを返す（例外は出さない）。
  static Future<List<String>> discover({String? dirPath}) async {
    try {
      if (dirPath != null) {
        final dir = Directory(dirPath);
        if (!await dir.exists()) return const [];
        final files =
            dir
                .listSync(followLinks: false)
                .whereType<File>()
                .where((f) => f.path.toLowerCase().endsWith('.gguf'))
                .map((f) => f.path)
                .toList()
              ..sort((a, b) => a.compareTo(b));
        return files;
      }
      final found = <String>{};
      void scan(Directory dir) {
        if (!dir.existsSync()) return;
        try {
          for (final e in dir.listSync(recursive: true, followLinks: false)) {
            if (e is File && e.path.toLowerCase().endsWith('.gguf')) {
              found.add(e.path);
            }
          }
        } catch (_) {
          // 読み取りできないディレクトリはスキップ。
        }
      }

      // 既定ディレクトリの再帰スキャンで直下（既存）+ imported/ を網羅。
      scan(await defaultDir());
      scan(await managedDir());
      return found.toList()..sort((a, b) => a.compareTo(b));
    } catch (_) {
      return const [];
    }
  }

  /// 実際に使うモデルパスを解決する。
  ///
  /// 1. 設定済みパス（prefs）が存在すればそれを採用
  /// 2. 設定なしで既定ディレクトリに GGUF がちょうど1つあればそれを採用
  /// 3. 以上でない場合は null（UI は「GGUFファイルを配置してください」を表示）
  static Future<String?> resolveModelPath() async {
    try {
      if (!isSupportedPlatform()) return null;
      final prefs = await SharedPreferences.getInstance();
      final configured = prefs.getString(prefsKey)?.trim() ?? '';
      if (configured.isNotEmpty) {
        final f = File(configured);
        if (await f.exists() && await f.length() > 0) return f.path;
        // M5: 選択済みファイルが消失していたら設定をクリアする
        // （キャッシュ消去・手動削除対策。以降は再検索へ進む）。
        try {
          await prefs.remove(prefsKey);
        } catch (_) {
          // クリア失敗は解決の継続を妨げない。
        }
      }
      final found = await discover();
      if (found.length == 1) return found.single;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 選択済みモデルパスを設定（絶対パス、または既定ディレクトリからのファイル名）。
  /// 絶対パスでない場合は既定ディレクトリに結合して保存する。
  static Future<String> setModelPath(String pathOrName) async {
    final trimmed = pathOrName.trim();
    final abs = p.isAbsolute(trimmed)
        ? trimmed
        : p.join((await defaultDir()).path, trimmed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, abs);
    return abs;
  }
}
