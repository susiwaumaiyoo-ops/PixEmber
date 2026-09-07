import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart'
    show
        GenerationParams,
        LlamaBackend,
        LlamaChatMessage,
        LlamaCompletionChunk,
        LlamaEngine,
        ModelParams;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  LlamaDartEngine({this._contextSize = 8192, this._gpuLayers = 0})
    : _engine = LlamaEngine(LlamaBackend());

  final int _contextSize;
  final int _gpuLayers;
  final LlamaEngine _engine;
  bool _loaded = false;
  bool _disposed = false;

  @override
  Future<void> loadModel(String modelPath) async {
    if (_disposed) {
      throw StateError('LlamaDartEngine is already disposed.');
    }
    if (_loaded) return;
    await _engine.loadModel(
      modelPath,
      modelParams: ModelParams(
        contextSize: _contextSize,
        gpuLayers: _gpuLayers,
      ),
    );
    _loaded = true;
  }

  @override
  Stream<LlamaCompletionChunk> generate({
    required List<LlamaChatMessage> messages,
    required GenerationParams options,
  }) {
    if (_disposed) {
      throw StateError('LlamaDartEngine is already disposed.');
    }
    return _engine.create(messages, params: options);
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
  LocalLlmService({
    LlmInferenceEngine Function(String modelPath)? engineFactory,
  }) : _engineFactory = engineFactory ?? _defaultEngine;

  static LlmInferenceEngine _defaultEngine(String modelPath) {
    return LlamaDartEngine(contextSize: defaultContextSize);
  }

  /// 要約生成向けコンテキストサイズ（本文2000字+プロンプト+出力に余力）。
  static const int defaultContextSize = 8192;

  /// 要約生成向けサンプリング（低温度で安定した出力を取る）。
  static const GenerationParams defaultGenerationOptions = GenerationParams(
    temp: 0.2,
    topP: 0.9,
    maxTokens: 1024,
  );

  final LlmInferenceEngine Function(String modelPath) _engineFactory;

  LlmState _state = LlmState.idle;
  String? _errorMessage;
  bool _disposed = false;
  bool _busy = false;
  bool _cancelled = false;
  LlmInferenceEngine? _engine;
  StreamSubscription<LlamaCompletionChunk>? _subscription;
  String? _currentModelPath;
  bool _generationDone = false;
  Object? _generationError;

  static const Duration _tick = Duration(milliseconds: 5);

  /// 状態遷移通知。[dispose] 以降は呼ばれない。
  void Function(LlmState state, String? error)? onStateChange;

  LlmState get state => _state;
  String? get errorMessage => _errorMessage;
  bool get isDisposed => _disposed;
  bool get isBusy => _busy;
  String? get modelPath => _currentModelPath;

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

  /// モデルを読み込む（ファイル検証 + エンジン生成 + 実際のロード）。
  ///
  /// 実際のロードは llamadart の worker isolate 内で実行され、
  /// UI スレッドはブロックされない。
  ///
  /// 成功: true（state -> idle）。ファイル不在・ロード失敗: false（state -> error）。
  Future<bool> loadModel(String modelPath) async {
    if (_disposed || _busy) return false;
    _busy = true;
    _transition(LlmState.loading);
    try {
      if (!await isModelFileReady(modelPath)) {
        throw StateError('Model file not found: $modelPath');
      }
      _engine?.dispose();
      final engine = _engineFactory(modelPath);
      await engine.loadModel(modelPath);
      _engine = engine;
      _currentModelPath = modelPath;
      _transition(LlmState.idle);
      return true;
    } catch (e) {
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
    _generationDone = false;
    _generationError = null;
    _transition(LlmState.generating);
    final buffer = StringBuffer();
    try {
      final stream = engine.generate(
        messages: messages,
        options: options ?? defaultGenerationOptions,
      );
      final subscription = stream.listen(
        (chunk) {
          if (_cancelled) return;
          final piece = _chunkText(chunk);
          if (piece.isEmpty) return;
          buffer.write(piece);
          onToken?.call(piece);
        },
        onError: (Object e) {
          if (_cancelled) return;
          _generationError = e;
        },
        onDone: () {
          _generationDone = true;
        },
        cancelOnError: false,
      );
      _subscription = subscription;
      // onDone/onError を待って終了を判定する（ポーリングで橋渡し）。
      while (!_generationDone && _generationError == null) {
        await Future<void>.delayed(_tick);
        if (_cancelled) {
          await subscription.cancel();
          throw const LlmCancelledException();
        }
      }
      await subscription.cancel();
      if (_generationError != null) {
        throw _generationError!;
      }
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
      _generationDone = false;
      _generationError = null;
      _subscription = null;
      _busy = false;
    }
  }

  /// 生成中であることをキャンセルする（state -> idle）。
  ///
  /// 購読破棄は llamadart の cancel token に伝播し、
  /// worker isolate が次のトークン境界でデコードを停止する。
  void cancel() {
    if (!_busy) return;
    _cancelled = true;
    _subscription?.cancel();
  }

  /// サービスを終了する。以降は [onStateChange] は呼ばれない。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelled = true;
    _subscription?.cancel();
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

/// モデルファイルの配置・解決（手動配置前提: 自動ダウンロードはしない）。
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

  /// [dirPath]（既定は既定ディレクトリ）配下の *.gguf ファイルパス一覧（ソート済み）。
  /// 読み取り失敗時は空リストを返す（例外は出さない）。
  static Future<List<String>> discover({String? dirPath}) async {
    try {
      final dir = dirPath != null ? Directory(dirPath) : await defaultDir();
      if (!await dir.exists()) return const [];
      final entities = await dir.list().toList();
      final files = entities.whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return files
          .where((f) => f.path.toLowerCase().endsWith('.gguf'))
          .map((f) => f.path)
          .toList();
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
