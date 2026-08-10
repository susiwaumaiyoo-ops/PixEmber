import 'dart:async';
import 'dart:math' as math;

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'ruri_model_manager.dart';

/// Ruri v3-310m INT8 による埋め込み生成サービス（シングルトン）。
///
/// 公開 API は [encodeQuery] / [encodeDocument] の 2 つのみ。
/// プレフィックス付与は本サービス内部でのみ行う（呼び出し側は付けない）。
class EmbeddingService {
  static final EmbeddingService _instance = EmbeddingService._internal();
  factory EmbeddingService() => _instance;
  EmbeddingService._internal();

  // ---- 固定仕様（推定ロジック禁止） ----
  static const String modelId = RuriModelManager.embeddingModelId;
  static const int modelVersion = RuriModelManager.embeddingModelVersion;
  static const int embeddingDimension = RuriModelManager.embeddingDimension;
  static const int prefixSchemeVersion = RuriModelManager.prefixSchemeVersion;
  static const int paddedLength = 128;

  static const int bosTokenId = 1;
  static const int eosTokenId = 2;
  static const int padTokenId = 3;

  static const String _queryPrefix = RuriModelManager.queryPrefix;
  static const String _documentPrefix = RuriModelManager.documentPrefix;

  OrtSession? _session;
  SentencePieceTokenizer? _tokenizer;
  bool _isInitialized = false;
  String? _initError;
  Completer<void>? _initCompleter;

  bool get isInitialized => _isInitialized;
  String? get initError => _initError;

  /// 既存呼び出し側互換: 初期化完了を待つ Future。
  Future<void> get ready => _initCompleter?.future ?? Future<void>.value();

  /// モデル・トークナイザを読み込み、スモーク推論まで実施する。
  ///
  /// 多重呼び出しは同一の初期化処理を共有する。
  Future<void> initialize() async {
    if (_isInitialized) return;
    final existing = _initCompleter;
    if (existing != null && !existing.isCompleted) {
      return existing.future;
    }
    final completer = Completer<void>();
    _initCompleter = completer;
    _initError = null;
    try {
      await _doInitialize();
      _isInitialized = true;
      if (!completer.isCompleted) completer.complete();
    } catch (e, st) {
      _initError = e.toString();
      _isInitialized = false;
      debugPrint('[EmbeddingService] 初期化失敗: $e');
      debugPrint(st.toString());
      if (!completer.isCompleted) completer.completeError(e, st);
      // 呼び出し側の既存挙動を壊さないため rethrow しない。
    }
  }

  Future<void> _doInitialize() async {
    final manager = RuriModelManager();

    // 1) モデルが SHA-256 検証済みで存在するか確認
    final ready = await manager.isModelReady();
    if (!ready) {
      throw StateError('Ruri モデルが未準備です（未ダウンロードまたは検証失敗）。');
    }

    final modelPath = (await manager.modelFile).path;
    final tokPath = await manager.tokenizerPath;
    debugPrint('[EmbeddingService] modelPath=$modelPath');
    debugPrint('[EmbeddingService] tokenizerPath=$tokPath');
    final info = await manager.readInfo();
    if (info != null) {
      debugPrint(
        '[EmbeddingService] modelSha256=${info['modelSha256']} '
        'tokenizerSha256=${info['tokenizerSha256']}',
      );
    }

    // 2) 既存セッションは必ず先に破棄（複数セッション同時保持の禁止）
    await _disposeSession();

    // 3) ORT セッション作成（ネイティブ側で非同期実行）
    final session = await manager.loadSession();
    _session = session;
    debugPrint('[EmbeddingService] inputNames=${session.inputNames}');
    debugPrint('[EmbeddingService] outputNames=${session.outputNames}');

    // 4) トークナイザ読み込み（非同期・1 回だけ・キャッシュ）
    _tokenizer = await SentencePieceTokenizer.fromModelFile(tokPath);

    // 5) スモーク推論（768 次元・NaN/Inf なしを確認）
    final smoke = await _encodeInternal('$_queryPrefix初期化確認');
    if (smoke.length != embeddingDimension) {
      throw StateError('スモーク推論の次元が不正: ${smoke.length}');
    }
    debugPrint('[EmbeddingService] スモーク推論 OK (dim=${smoke.length})');
  }

  /// 検索クエリ用の埋め込みを生成する。
  Future<Float32List> encodeQuery(String text) async {
    _ensureReady();
    return _encodeInternal('$_queryPrefix$text');
  }

  /// 検索文書用の埋め込みを生成する。
  Future<Float32List> encodeDocument(String text) async {
    _ensureReady();
    return _encodeInternal('$_documentPrefix$text');
  }

  void _ensureReady() {
    if (!_isInitialized || _session == null || _tokenizer == null) {
      throw StateError(
        'EmbeddingService が初期化されていません。initialize() を先に呼んでください。'
        '${_initError != null ? ' (initError: $_initError)' : ''}',
      );
    }
  }

  // ---- トークナイズ ----

  /// [1(BOS)] + content + [2(EOS)] を作り、128 に切り詰め/PAD する。
  @visibleForTesting
  ({Int64List inputIds, Int64List attentionMask, int validCount}) buildInputs(
    String text,
  ) {
    final tokenizer = _tokenizer;
    if (tokenizer == null) {
      throw StateError('トークナイザ未ロードです。');
    }
    final content = tokenizer.encode(text).ids;

    final ids = <int>[bosTokenId];
    // BOS/EOS 分 2 を除いた本文長まで採用
    final maxContent = paddedLength - 2;
    for (int i = 0; i < content.length && i < maxContent; i++) {
      ids.add(content[i]);
    }
    ids.add(eosTokenId);

    final inputIds = Int64List(paddedLength);
    final attention = Int64List(paddedLength);
    final valid = ids.length;
    for (int i = 0; i < paddedLength; i++) {
      if (i < valid) {
        inputIds[i] = ids[i];
        attention[i] = 1;
      } else {
        inputIds[i] = padTokenId;
        attention[i] = 0;
      }
    }
    return (inputIds: inputIds, attentionMask: attention, validCount: valid);
  }

  // ---- 推論本体 ----

  Future<Float32List> _encodeInternal(String prefixedText) async {
    final session = _session;
    if (session == null) {
      throw StateError('ORT セッションが未作成です。');
    }

    final built = buildInputs(prefixedText);
    final validCount = built.validCount;
    if (validCount <= 0) {
      throw StateError('有効トークン数が 0 です。');
    }

    final idsTensor = await OrtValue.fromList(built.inputIds, [
      1,
      paddedLength,
    ]);
    final maskTensor = await OrtValue.fromList(built.attentionMask, [
      1,
      paddedLength,
    ]);

    final feeds = <String, OrtValue>{
      'input_ids': idsTensor,
      'attention_mask': maskTensor,
    };
    // ModernBERT は token_type_ids 不要。存在する場合のみゼロを渡す。
    OrtValue? typeTensor;
    if (session.inputNames.contains('token_type_ids')) {
      typeTensor = await OrtValue.fromList(Int64List(paddedLength), [
        1,
        paddedLength,
      ]);
      feeds['token_type_ids'] = typeTensor;
    }

    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run(feeds);
      final tokenEmb = outputs['token_embeddings'];
      if (tokenEmb == null) {
        throw StateError('token_embeddings 出力が存在しません。');
      }
      if (outputs.containsKey('sentence_embedding')) {
        debugPrint('[EmbeddingService] sentence_embedding は未使用（将来比較用）');
      }

      final flat = await tokenEmb.asFlattenedList();
      final expected = paddedLength * embeddingDimension;
      if (flat.length != expected) {
        throw StateError(
          'token_embeddings の要素数が不正: ${flat.length} (期待 $expected)',
        );
      }

      // Mean pooling（attention_mask == 1 のトークンのみ）
      final pooled = Float32List(embeddingDimension);
      for (int t = 0; t < paddedLength; t++) {
        if (built.attentionMask[t] != 1) continue;
        final base = t * embeddingDimension;
        for (int d = 0; d < embeddingDimension; d++) {
          pooled[d] += (flat[base + d] as num).toDouble();
        }
      }
      for (int d = 0; d < embeddingDimension; d++) {
        pooled[d] = pooled[d] / validCount;
      }

      // L2 正規化
      double sumSq = 0;
      for (int d = 0; d < embeddingDimension; d++) {
        sumSq += pooled[d] * pooled[d];
      }
      final norm = math.sqrt(sumSq);
      if (!(norm > 1e-9)) {
        throw StateError('L2 ノルムが極小のため正規化できません: $norm');
      }
      for (int d = 0; d < embeddingDimension; d++) {
        pooled[d] = pooled[d] / norm;
      }

      // 出力検証
      if (pooled.length != embeddingDimension) {
        throw StateError('出力次元が不正: ${pooled.length}');
      }
      double check = 0;
      for (int d = 0; d < embeddingDimension; d++) {
        final v = pooled[d];
        if (v.isNaN || v.isInfinite) {
          throw StateError('出力に NaN/Inf が含まれます。');
        }
        check += v * v;
      }
      final outNorm = math.sqrt(check);
      debugPrint(
        '[EmbeddingService] validTokens=$validCount dim=${pooled.length} '
        'norm=${outNorm.toStringAsFixed(6)}',
      );
      if ((outNorm - 1.0).abs() > 1e-3) {
        debugPrint('[EmbeddingService] 警告: 正規化後ノルムが 1.0 から乖離 ($outNorm)');
      }
      return pooled;
    } finally {
      await idsTensor.dispose();
      await maskTensor.dispose();
      if (typeTensor != null) await typeTensor.dispose();
      if (outputs != null) {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
    }
  }

  Future<void> _disposeSession() async {
    final s = _session;
    _session = null;
    if (s != null) {
      await s.close();
    }
  }

  Future<void> dispose() async {
    await _disposeSession();
    _tokenizer = null;
    _isInitialized = false;
    _initCompleter = null;
  }
}
