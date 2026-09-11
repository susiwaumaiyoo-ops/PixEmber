import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm_model_preset.dart';
import 'native_llm_engine.dart';

/// ローカルLLM（llama.cpp / libnative_llm.so）のサービス状態。
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

/// チャットの役割（llama.cpp のチャットテンプレートが期待する文字列と一致）。
enum LlmChatRole {
  system,
  user,
  assistant;

  /// ネイティブ（テンプレ適用）へ渡す役割名。
  String get wireName => name;
}

/// 1メッセージ（role + content）。
class LlmChatMessage {
  const LlmChatMessage({required this.role, required this.content});

  /// テキストから生成する（llamadart 時代の互換ファクトリ）。
  factory LlmChatMessage.fromText({
    required LlmChatRole role,
    required String text,
  }) => LlmChatMessage(role: role, content: text);

  final LlmChatRole role;
  final String content;

  @override
  bool operator ==(Object other) =>
      other is LlmChatMessage && other.role == role && other.content == content;

  @override
  int get hashCode => Object.hash(role, content);

  @override
  String toString() => 'LlmChatMessage($role, ${content.length} chars)';
}

/// 生成サンプリング設定（llamadart GenerationParams の互換置き換え）。
class LlmGenerationOptions {
  const LlmGenerationOptions({
    this.temp = 0.2,
    this.topP = 0.9,
    this.maxTokens = 1024,
  });

  /// 温度（<=0 で greedy）。
  final double temp;

  /// top-p（ネイティブ実装では未使用・UI/テスト互換のため維持）。
  final double topP;

  /// 生成上限トークン数。
  final int maxTokens;

  @override
  bool operator ==(Object other) =>
      other is LlmGenerationOptions &&
      other.temp == temp &&
      other.topP == topP &&
      other.maxTokens == maxTokens;

  @override
  int get hashCode => Object.hash(temp, topP, maxTokens);
}

/// 推論バックエンドの要求（auto = HTP → OpenCL → CPU の自動検出順）。
enum LlmBackend {
  auto,
  npu,
  gpu,
  cpu;

  /// nllm_load の backend_kind 引数（-1=auto 0=cpu 1=opencl 2=htp）。
  int get kindInt {
    switch (this) {
      case LlmBackend.auto:
        return -1;
      case LlmBackend.npu:
        return 2;
      case LlmBackend.gpu:
        return 1;
      case LlmBackend.cpu:
        return 0;
    }
  }

  /// 保存文字列から復元（不正値は auto）。
  static LlmBackend parse(String? name) {
    for (final b in LlmBackend.values) {
      if (b.name == name) return b;
    }
    return LlmBackend.auto;
  }
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
    this.stopReason,
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

  /// バックエンドロード失敗により CPU へフォールバックしたか。
  final bool? usedCpuFallback;

  /// ネイティブ計測: プロンプト評価時間(ms)（取得できない場合は null）。
  final double? nativePromptEvalMs;

  /// ネイティブ計測: プロンプト評価トークン数。
  final int? nativePromptEvalTokens;

  /// ネイティブ計測: 生成評価時間(ms)（取得できない場合は null）。
  final double? nativeEvalMs;

  /// ネイティブ計測: 生成評価トークン数。
  final int? nativeEvalTokens;

  /// 直近生成の停止理由の表示文言(EOS/上限到達/キャンセル/エラー)。
  /// キャッシュヒット等でネイティブ計測が無い場合は null。
  final String? stopReason;

  /// ネイティブ計測に基づく生成速度（取得できない場合は null）。
  double? get nativeTokensPerSecond {
    final ms = nativeEvalMs;
    final n = nativeEvalTokens;
    if (ms == null || ms <= 0 || n == null || n <= 0) return null;
    return n * 1000 / ms;
  }

  /// 1秒あたりの生成トークン数（計測不能なら 0.0）。
  ///
  /// TTFT が取れる場合は「最初の出力以降の経過時間」をデコード時間の
  /// 近似として使う。ネイティブ計測（[nativeTokensPerSecond]）が取れる
  /// 場合は UI はそちらを優先表示する。
  double get tokensPerSecond {
    if (generatedTokens == 0) return 0.0;
    final ms = elapsed.inMilliseconds;
    if (ms <= 0) return 0.0;
    final ttft = timeToFirstTokenMs;
    final decodeMs = (ttft == null || ttft <= 0 || ttft >= ms) ? ms : ms - ttft;
    return generatedTokens * 1000 / decodeMs;
  }
}

/// ネイティブ（libnative_llm.so = llama.cpp）から取得した 1 生成分の計測値。
///
/// nllm_get_stats は直近 1 生成の実測値を返すため 1 生成分。
/// 取得できない項目は null（推定値は報告しない）。
class LlmNativePerf {
  const LlmNativePerf({
    this.promptEvalMs,
    this.promptEvalTokens,
    this.evalMs,
    this.evalTokens,
    this.stopReason,
  });

  final double? promptEvalMs;
  final int? promptEvalTokens;
  final double? evalMs;
  final int? evalTokens;

  /// 停止理由コード(0=eos 1=limit 2=cancel 3=error, -1/未取得=null)。
  final int? stopReason;
}

/// ローカルLLMの実行設定（A/B: CPUスレッド数・推論バックエンド）。
class LlmRuntimeSettings {
  const LlmRuntimeSettings({
    this.cpuThreads = 0,
    this.backend = LlmBackend.auto,
  });

  /// SharedPreferences キー。
  static const String prefKeyCpuThreads = 'llm_pref_cpu_threads';
  static const String prefKeyBackend = 'llm_pref_backend';

  /// 旧 Vulkan 切り替えのキー（移行専用・読み取りのみ）。
  static const String prefKeyUseVulkanLegacy = 'llm_pref_use_vulkan';

  /// スレッド数の選択肢（0 = 自動・現状の基準。1 は診断用）。
  static const List<int> cpuThreadChoices = <int>[0, 1, 2, 4];

  /// 要求する推論スレッド数（0 = llama.cpp の自動）。実効値は取得不能なため
  /// UI には「要求値」として表示する。
  final int cpuThreads;

  /// 要求する推論バックエンド。npu/gpu でロード失敗時は CPU へ
  /// 1 回だけフォールバックする。
  final LlmBackend backend;

  LlmRuntimeSettings copyWith({int? cpuThreads, LlmBackend? backend}) =>
      LlmRuntimeSettings(
        cpuThreads: cpuThreads ?? this.cpuThreads,
        backend: backend ?? this.backend,
      );

  /// 保存された設定を読む（不正値は既定に戻す）。
  ///
  /// 旧バージョンの Vulkan bool 設定はバックエンド選択へ移行する
  /// （true → gpu / false → auto）。
  static Future<LlmRuntimeSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getInt(prefKeyCpuThreads) ?? 0;
      final storedBackend = prefs.getString(prefKeyBackend);
      final LlmBackend backend;
      if (storedBackend != null) {
        backend = LlmBackend.parse(storedBackend);
      } else {
        // 旧 Vulkan 設定からの移行。
        backend = (prefs.getBool(prefKeyUseVulkanLegacy) ?? false)
            ? LlmBackend.gpu
            : LlmBackend.auto;
      }
      return LlmRuntimeSettings(
        cpuThreads: cpuThreadChoices.contains(t) ? t : 0,
        backend: backend,
      );
    } catch (_) {
      return const LlmRuntimeSettings();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LlmRuntimeSettings &&
      other.cpuThreads == cpuThreads &&
      other.backend == backend;

  @override
  int get hashCode => Object.hash(cpuThreads, backend);
}

/// 生成キャンセルを示す例外（UIはエラー表示にしない）。
class LlmCancelledException implements Exception {
  const LlmCancelledException();
  @override
  String toString() => 'Generation cancelled.';
}

/// 推論エンジンの抽象化（テスト用の fake 差し替え用）。
///
/// 本番は [NativeLlmEngine]（libnative_llm.so への FFI）。モデルロード・
/// トークン生成は ワーカー isolate 内で実行され UI スレッドをブロックしない。
abstract class LlmInferenceEngine {
  /// モデルをロードする（テストの fake 実装は no-op でよい）。
  Future<void> loadModel(String modelPath);

  /// [messages] を与え、テキスト断片（UTF-8 完了済み）をストリームで返す。
  Stream<String> generate({
    required List<LlmChatMessage> messages,
    required LlmGenerationOptions options,
  });

  /// 使用済みリソースを解放する。
  void dispose();
}

/// ローカルLLM推論を司るサービス（libnative_llm.so ラッパー）。
///
/// 状態機械: idle / loading / generating / done / error。
/// [onStateChange] で状態遷移、[generate] の onToken でストリーミング配信。
///
/// 規約:
/// - [dispose] 以降は [onStateChange] を絶対に呼ばない（setState 後の dispose 対策）。
/// - [cancel] はネイティブへ停止要求（nllm_request_stop）を行い、
///   ワーカーは次のトークン境界でデコードを停止する（実キャンセル）。
class LocalLlmService {
  /// [engineFactory] 未指定時は llama.cpp 実装（[NativeLlmEngine]）を使う。
  ///
  /// [preset] は [engineFactory] 未指定時にエンジンへ渡される推論プリセット。
  /// 通常はカタログ fileName で解決した値
  /// （[LlmInferencePreset.resolveForFileName]）を渡す。
  LocalLlmService({
    LlmInferenceEngine Function(String modelPath)? engineFactory,
    LlmInferencePreset preset = LlmInferencePreset.defaults,
    this.runtimeSettings = const LlmRuntimeSettings(),
  }) : _preset = preset, // ignore: prefer_initializing_formals
       _customEngineFactory = engineFactory;

  /// 要約生成向けコンテキストサイズ（本文2000字+プロンプト+出力に余力）。
  static const int defaultContextSize = 8192;

  /// 要約生成向けサンプリング（低温度で安定した出力を取る）。
  static const LlmGenerationOptions defaultGenerationOptions =
      LlmGenerationOptions(temp: 0.2, topP: 0.9, maxTokens: 1024);

  final LlmInferenceEngine Function(String modelPath)? _customEngineFactory;
  final LlmInferencePreset _preset;

  /// 現在要求されている実行設定（A/B）。
  LlmRuntimeSettings runtimeSettings;

  /// 直近のロードが実際に適用したセッションキー（再利用判定に使用）。
  _LlmSessionKey? _currentKey;
  bool _lastLoadUsedCpuFallback = false;

  /// A-3: ロード失敗時にコンテキストを縮小して再試行したか。
  bool _lastLoadUsedContextFallback = false;

  /// A-3: 縮小フォールバックで使用するコンテキストサイズ。
  static const int fallbackContextSize = 4096;

  /// A-3: プリセットより小さいコンテキストで再試行するための上書き値。
  int? _contextSizeOverride;

  /// A-3: 実際にロードへ渡すコンテキストサイズ（縮小済みなら小さい値）。
  int get effectiveContextSize => _contextSizeOverride ?? _preset.contextSize;

  LlmState _state = LlmState.idle;
  String? _errorMessage;
  bool _disposed = false;
  bool _busy = false;
  bool _cancelled = false;
  LlmInferenceEngine? _engine;
  String? _currentModelPath;
  LlmGenerationStats? _lastGenerationStats;

  /// シート跨ぎでエンジンを保持するためのセッションキャッシュ（プロセス単一）。
  /// LocalLlmService は要約シート再生成のたびに新インスタンス化されるため、
  /// 同一キーならワーカー/ネイティブセッションを再ロードなく再利用する。
  /// カスタムファクトリ（テスト）は対象外。
  static _LlmSessionEntry? _sharedSession;

  /// 状態遷移通知。[dispose] 以降は呼ばれない。
  void Function(LlmState state, String? error)? onStateChange;

  LlmState get state => _state;
  String? get errorMessage => _errorMessage;
  bool get isDisposed => _disposed;
  bool get isBusy => _busy;
  String? get modelPath => _currentModelPath;

  /// コンストラクタで渡された推論プリセット（M5）。
  LlmInferencePreset get preset => _preset;

  /// 直近のロードがバックエンド失敗 → CPU フォールバックだったか。
  bool get lastLoadUsedCpuFallback => _lastLoadUsedCpuFallback;

  /// A-3: 直近のロードがコンテキスト縮小(8192→4096)だったか。
  bool get lastLoadUsedContextFallback => _lastLoadUsedContextFallback;

  /// A-3: コンテキスト縮小の表示文言(発生していなければ null)。
  String? get contextShrinkNote => _lastLoadUsedContextFallback
      ? 'コンテキスト縮小: ${_preset.contextSize}→$fallbackContextSize'
      : null;

  /// エンジンを生成する（カスタムファクトリ（テスト）優先。
  /// 実機は [LlmRuntimeSettings] をネイティブパラメータへ反映する）。
  LlmInferenceEngine _buildEngine(_LlmSessionKey key) {
    final custom = _customEngineFactory;
    if (custom != null) return custom(key.modelPath);
    return NativeLlmEngine(
      backend: key.backend,
      contextSize: key.contextSize,
      gpuLayers: key.gpuLayers,
      cpuThreads: key.cpuThreads,
    );
  }

  /// プリセットに基づく生成オプション（M5）。
  ///
  /// maxTokens はプリセットの maxOutputTokens（温度等は従来値を維持）。
  LlmGenerationOptions get generationOptions => LlmGenerationOptions(
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
  /// ネイティブ（llama.cpp）のトークナイザが利用できる場合は実測値を返す。
  /// テストの fake エンジンやネイティブ未ロードなどで実測できない場合は
  /// null（= 「個別取得不可」。推定値は返さない）。
  Future<int?> promptTokenCount(List<LlmChatMessage> messages) async {
    final engine = _engine;
    if (engine is! NativeLlmEngine) return null;
    try {
      final prompt = messages.map((m) => m.content).join('\n');
      return await engine.countTokens(prompt);
    } catch (_) {
      return null;
    }
  }

  /// 単一テキストのトークン数を実測する(B: チャンク分割の予算計算)。
  ///
  /// ネイティブのトークナイザが使えない場合(fake エンジン等)は null。
  Future<int?> countTokens(String text) async {
    final engine = _engine;
    if (engine is! NativeLlmEngine) return null;
    try {
      return await engine.countTokens(text);
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
  /// 実際のロードは NativeLlmEngine のワーカー isolate 内で実行され、
  /// UI スレッドはブロックされない。
  ///
  /// 成功: true（state -> idle）。ファイル不在・ロード失敗: false（state -> error）。
  /// セッション再利用キーを作る（モデルパス + 実行設定 + プリセット値）。
  _LlmSessionKey _keyFor(String modelPath, LlmRuntimeSettings s) {
    return _LlmSessionKey(
      modelPath: modelPath,
      backend: s.backend,
      // A-3: 縮小フォールバック適用中は小さい値でキーを組む(再利用判定)。
      contextSize: effectiveContextSize,
      gpuLayers: _preset.gpuLayers,
      cpuThreads: s.cpuThreads,
    );
  }

  Future<bool> loadModel(String modelPath) async {
    if (_disposed || _busy) return false;
    final key = _keyFor(modelPath, runtimeSettings);
    // B: 同一セッションがロード済みなら再ロードしない。再利用条件は
    // モデルパスに加え、バックエンド・コンテキスト・gpuLayers・スレッド数
    // が完全一致する場合のみ（= タプルキー一致）。設定が変われば再ロード。
    if (_engine != null && _currentKey == key && !_cancelled) {
      _lastLoadMs = 0;
      return true;
    }
    // シート跨ぎ保持: 別の LocalLlmService インスタンスが同一キーで
    // ロードしたネイティブセッションがあれば adopt（再ロード回避）。
    // カスタムファクトリ（テスト）は対象外。
    final shared = _customEngineFactory == null ? _sharedSession : null;
    if (shared != null &&
        shared.key == key &&
        shared.engine is NativeLlmEngine &&
        (shared.engine as NativeLlmEngine).isReusable) {
      _disposeOwnEngine(excluding: shared.engine);
      _engine = shared.engine;
      _currentKey = key;
      _currentModelPath = modelPath;
      _lastLoadUsedCpuFallback = false;
      _lastLoadMs = 0;
      _transition(LlmState.idle);
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
      _engine = null;
      final engine = _buildEngine(key);
      try {
        await engine.loadModel(modelPath);
      } catch (_) {
        // 失敗したエンジンは確実に解放する（同時にロードするのは常時1つ）。
        try {
          engine.dispose();
        } catch (_) {}
        rethrow;
      }
      loadWatch.stop();
      _lastLoadMs = loadWatch.elapsedMilliseconds;
      _lastLoadUsedCpuFallback = false;
      _lastLoadUsedContextFallback = false;
      _adopt(engine, key, modelPath);
      _transition(LlmState.idle);
      return true;
    } catch (e) {
      // A-3: コンテキスト過大によるロード失敗(HTP バッファ確保失敗等)に
      // 備え、プリセットが 4096 超なら 4096 で 1 回だけ再試行する。
      // ただしファイル自体が存在しない場合(同期検証失敗)は対象外。
      // 縮小は HTP(NPU) の 4GiB DSP 上限で起きるバッファ確保失敗への
      // 対処であり、CPU/GPU では無関係なため npu のときだけ発火させる。
      final modelMissing = e is StateError &&
          e.message.toString().contains('Model file not found');
      if (!modelMissing &&
          runtimeSettings.backend == LlmBackend.npu &&
          !_lastLoadUsedContextFallback &&
          _contextSizeOverride == null &&
          _preset.contextSize > fallbackContextSize) {
        LlmInferenceEngine? shrinkEngine;
        try {
          _contextSizeOverride = fallbackContextSize;
          final shrinkKey = _keyFor(modelPath, runtimeSettings);
          shrinkEngine = _buildEngine(shrinkKey);
          await shrinkEngine.loadModel(modelPath);
          loadWatch.stop();
          _lastLoadMs = loadWatch.elapsedMilliseconds;
          _lastLoadUsedCpuFallback = false;
          _lastLoadUsedContextFallback = true;
          debugPrint(
            'LocalLlmService: context shrink fallback '
            '${_preset.contextSize} -> $fallbackContextSize',
          );
          _adopt(shrinkEngine, shrinkKey, modelPath);
          shrinkEngine = null; // adopt 済み = 二重 dispose 防止
          _transition(LlmState.idle);
          return true;
        } catch (_) {
          try {
            shrinkEngine?.dispose();
          } catch (_) {}
          // 縮小も失敗 → 元のコンテキストへ戻して後続フォールバックへ。
          _contextSizeOverride = null;
        }
      }
      // B: NPU/GPU 要求でのロード失敗は、失敗したエンジンを解放して
      // CPU 設定で 1 回だけ再試行する（未対応端末でのクラッシュ防止）。
      if ((runtimeSettings.backend == LlmBackend.npu ||
              runtimeSettings.backend == LlmBackend.gpu) &&
          !_lastLoadUsedCpuFallback) {
        LlmInferenceEngine? cpuEngine;
        try {
          final cpuSettings = runtimeSettings.copyWith(backend: LlmBackend.cpu);
          final cpuKey = _keyFor(modelPath, cpuSettings);
          cpuEngine = _buildEngine(cpuKey);
          await cpuEngine.loadModel(modelPath);
          loadWatch.stop();
          _lastLoadMs = loadWatch.elapsedMilliseconds;
          _lastLoadUsedCpuFallback = true;
          // 以後のロード要求が実際に動作している CPU 設定と比較されるよう、
          // 実行要求値を実値へ同期する（再利用判定の一致）。
          runtimeSettings = cpuSettings;
          _adopt(cpuEngine, cpuKey, modelPath);
          cpuEngine = null; // adopt 済み = 二重 dispose 防止
          _transition(LlmState.idle);
          return true;
        } catch (_) {
          // CPU 再試行も失敗 → エンジンを確実に解放してから元エラー扱い。
          try {
            cpuEngine?.dispose();
          } catch (_) {}
        }
      }
      _transition(LlmState.error, error: _friendlyError(e));
      return false;
    } finally {
      _busy = false;
    }
  }

  /// ロード済みエンジンをこのサービスに紐付け、静的セッションキャッシュへ登録。
  void _adopt(LlmInferenceEngine engine, _LlmSessionKey key, String modelPath) {
    _engine = engine;
    _currentKey = key;
    _currentModelPath = modelPath;
    if (_customEngineFactory == null) {
      _sharedSession = _LlmSessionEntry(key: key, engine: engine);
    }
  }

  /// このインスタンスが保持する旧エンジンを解放する（[excluding] は残す）。
  void _disposeOwnEngine({LlmInferenceEngine? excluding}) {
    final own = _engine;
    if (own == null || identical(own, excluding)) return;
    try {
      own.dispose();
    } catch (_) {}
  }

  /// [messages] からテキストを生成し、トークンを onToken でストリーム配信。
  ///
  /// 成功: 完全テキストを返す（state -> done）。
  /// 失敗: Exception を投げる（state -> error）。
  /// キャンセル: [LlmCancelledException]（state -> idle）。
  Future<String> generate(
    List<LlmChatMessage> messages, {
    void Function(String piece)? onToken,
    LlmGenerationOptions? options,
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
      // キャンセルは cancel()（ネイティブへ停止要求済み）でフラグを立て、
      // 次のトークンで LlmCancelledException を投げてループを抜ける
      // （await for が自動的に購読を破棄する。ストリーム側も rc==1 で
      //  LlmCancelledException を配信するため双方から検知する）。
      await for (final piece in stream) {
        if (_cancelled) {
          throw const LlmCancelledException();
        }
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
      final native = engine is NativeLlmEngine ? engine : null;
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
        backend: native != null ? NativeLlmEngine.backendLabel : null,
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
        stopReason: _stopReasonLabel(nativePerf?.stopReason),
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
  /// ネイティブへアトミックな停止要求（nllm_request_stop）を渡し、
  /// ワーカーは次のトークン境界でデコードを停止する。
  void cancel() {
    // B: チャンク境界(生成と生成の間は _busy=false)でもキャンセルを
    // 有効にするためフラグは常に立てる。ネイティブ停止要求は生成中のみ。
    _cancelled = true;
    if (!_busy) return;
    final engine = _engine;
    if (engine is NativeLlmEngine) {
      engine.requestStop();
    }
  }

  /// B: 直近のキャンセル要求フラグ(チャンク境界の判定用)。
  bool get isCancelled => _cancelled;

  /// サービスを終了する。以降は [onStateChange] は呼ばれない。
  ///
  /// 本番（NativeLlmEngine）ではシートを閉じてもネイティブセッションは
  /// 静的キャッシュ [_sharedSession] に保持し、次回同一キーで adopt する
  /// （再ロード回避）。アプリ background 時の解放は Phase C。
  /// カスタムファクトリ（テスト）は従来通り即時解放する。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelled = true;
    if (_customEngineFactory != null) {
      try {
        _engine?.dispose();
      } catch (_) {}
    }
    _engine = null;
    _currentKey = null;
    _currentModelPath = null;
    onStateChange = null;
  }

  /// 生メッセージをユーザー表示用に変換する（本文・URL等は出力しない）。
  /// native 停止理由コード → 表示文言(0=eos 1=limit 2=cancel 3=error)。
  static String? _stopReasonLabel(int? code) {
    switch (code) {
      case 0:
        return 'EOS(自然終了)';
      case 1:
        return '上限到達(未完了)';
      case 2:
        return 'キャンセル';
      case 3:
        return 'エラー';
      default:
        return null;
    }
  }

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

/// セッション再利用キー（モデルパス + 実行設定 + プリセット値のタプル）。
///
/// これが完全一致した場合のみ既存エンジン（ネイティブセッション）を
/// 再ロードなく再利用する。バックエンド・コンテキスト・gpuLayers・
/// スレッド数のいずれかが変われば別キー = 再ロード。
@immutable
class _LlmSessionKey {
  const _LlmSessionKey({
    required this.modelPath,
    required this.backend,
    required this.contextSize,
    required this.gpuLayers,
    required this.cpuThreads,
  });

  final String modelPath;
  final LlmBackend backend;
  final int contextSize;
  final int gpuLayers;
  final int cpuThreads;

  @override
  bool operator ==(Object other) =>
      other is _LlmSessionKey &&
      other.modelPath == modelPath &&
      other.backend == backend &&
      other.contextSize == contextSize &&
      other.gpuLayers == gpuLayers &&
      other.cpuThreads == cpuThreads;

  @override
  int get hashCode =>
      Object.hash(modelPath, backend, contextSize, gpuLayers, cpuThreads);
}

/// シート跨ぎで保持するセッション（キーとエンジン实例の対応）。
class _LlmSessionEntry {
  _LlmSessionEntry({required this.key, required this.engine});

  final _LlmSessionKey key;
  final LlmInferenceEngine engine;
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
