import 'dart:async';
import 'dart:math' as math;

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'rerank_model_manager.dart';

/// 高精度モード用 second-stage rerank（Ruri v3 Reranker / Cross-Encoder）実装。
///
/// モデルが未導入 / 利用不可の場合は [isAvailable] = false となり、
/// 呼び出し側（HybridSearchService）は従来の複合スコアで返す（skip）。
///
/// 入出力形式（ONNX 版 Ruri Reranker）:
/// - 入力: query + document を SentencePiece で 1 列にペア符号化した
///   `input_ids`, `attention_mask`（int64）。トークナイザは embedding と
///   同一語彙のため [RerankModelManager] 経由で共有する。
/// - 出力: 単一の logit → sigmoid で 0.0〜1.0 の関連度スコア。
class RerankService {
  RerankService._();

  static final RerankService _instance = RerankService._();
  factory RerankService() => _instance;

  OrtSession? _session;
  SentencePieceTokenizer? _tokenizer;
  bool _isReady = false;
  bool _initStarted = false;

  /// reranker が利用可能か（モデル導入済みでセッション準備完了なら true）。
  Future<bool> get isAvailable async {
    await ensureReady();
    return _isReady;
  }

  /// モデル資産を確認し、あればセッションとトークナイザをロードする。
  /// 未導入 / 失敗時は例外を投げず false を維持する（クラッシュ禁止）。
  Future<void> ensureReady() async {
    if (_isReady) return;
    if (_initStarted) {
      // 初期化中は完了を待たず、本呼び出し時点の状態を返す
      return;
    }
    _initStarted = true;
    try {
      final manager = RerankModelManager();
      final ready = await manager.isModelReady();
      if (!ready) {
        debugPrint('[RerankService] モデル未導入のため skip');
        _isReady = false;
        return;
      }
      final session = await manager.loadSession();
      final tokPath = await manager.tokenizerPath;
      final tokenizer = await SentencePieceTokenizer.fromModelFile(tokPath);
      _session = session;
      _tokenizer = tokenizer;
      _isReady = true;
      debugPrint('[RerankService] モデルロード成功（high-precision rerank 利用可）');
    } catch (e) {
      debugPrint('[RerankService] 初期化失敗（skip rerank）: $e');
      _isReady = false;
      _tokenizer = null;
      final s = _session;
      _session = null;
      if (s != null) {
        try {
          await s.close();
        } catch (_) {}
      }
      _initStarted = false;
    }
  }

  /// second-stage rerank を実行する。
  ///
  /// [query] 検索クエリ（意味テキスト）。
  /// [candidates] first-stage で抽出された候補（work_id + 文書テキスト + 元スコア）。
  /// 戻り値は [rerankScore] を上書きした candidates リスト。
  ///
  /// 利用不可 / 失敗の場合は元の候補リストをそのまま返す（no-op）。
  Future<List<RerankCandidate>> rerank({
    required String query,
    required List<RerankCandidate> candidates,
  }) async {
    await ensureReady();
    if (!_isReady || _session == null || _tokenizer == null) {
      return candidates; // no-op
    }
    if (candidates.isEmpty) return candidates;

    final session = _session!;
    final tokenizer = _tokenizer!;

    final scores = List<double>.filled(candidates.length, 0.0);
    const int chunkSize = 8;

    try {
      for (int start = 0; start < candidates.length; start += chunkSize) {
        final end = (start + chunkSize).clamp(0, candidates.length);
        for (int i = start; i < end; i++) {
          final doc = candidates[i];
          // Ruri v3 Reranker の入力形式: [BOS] query [EOS_sep] doc [EOS]
          // セパレータ(EOS) を正しく挟むため addSpecialTokens:true を指定する。
          final encoding = tokenizer.encodePair(
            query,
            doc.documentText,
            addSpecialTokens: true,
            maxLength: RerankModelManager.modelMaxSeq,
          );
          final logit = await _scoreOne(session, tokenizer, encoding);
          scores[i] = logit;
        }
        // チャンク間でメインスレッドに制御を戻し、UI を詰まらせない
        await Future<void>.delayed(Duration.zero);
      }
    } catch (e) {
      debugPrint('[RerankService] 推論失敗（元スコアでフォールバック）: $e');
      return candidates;
    }

    // 正常系: 計算した rerank スコアを候補へ反映し、デバッグ出力
    for (int i = 0; i < candidates.length; i++) {
      candidates[i].rerankScore = scores[i];
      candidates[i].rerankApplied = true;
    }
    _debugRerankChange(candidates);

    return candidates;
  }

  /// rerank 前後で順位が実際に変わったかをログ出力（D: デバッグ確認手段）。
  void _debugRerankChange(List<RerankCandidate> candidates) {
    if (candidates.isEmpty) return;
    final before = List<RerankCandidate>.from(candidates)
      ..sort((a, b) => b.baseScore.compareTo(a.baseScore));
    final after = List<RerankCandidate>.from(candidates)
      ..sort((a, b) => (b.rerankScore ?? 0).compareTo(a.rerankScore ?? 0));
    final buf = StringBuffer();
    buf.write('[RerankService] 順位変化(top5) base→rerank: ');
    for (int i = 0; i < after.length && i < 5; i++) {
      final c = after[i];
      final baseRank = before.indexWhere((e) => e.workId == c.workId) + 1;
      buf.write(
        '#$i w${c.workId}(base#$baseRank, '
        '${c.baseScore.toStringAsFixed(3)}→${(c.rerankScore ?? 0).toStringAsFixed(3)}) ',
      );
    }
    debugPrint(buf.toString());
  }

  /// 1 件のペア入力について関連度スコア(0.0〜1.0)を推論する。
  ///
  /// 出力形状を実行時判定する（B タスク）:
  /// - [1] / [N,1]      → 単一 logit を sigmoid
  /// - [2] / [N,2]      → softmax して positive クラスの確率
  /// - その他（想定外） → 例外を投げず 0.0 を返し、呼び出し側でフォールバック
  Future<double> _scoreOne(
    OrtSession session,
    SentencePieceTokenizer tokenizer,
    Encoding encoding,
  ) async {
    final ids = Int64List.fromList(encoding.ids);
    final mask = Int64List.fromList(encoding.attentionMask);
    final idsTensor = await OrtValue.fromList(ids, [1, ids.length]);
    final maskTensor = await OrtValue.fromList(mask, [1, mask.length]);
    try {
      final feeds = <String, OrtValue>{
        session.inputNames[0]: idsTensor,
        session.inputNames[1]: maskTensor,
      };
      final outputs = await session.run(feeds);
      final out = outputs[session.outputNames.first]!;
      final flat = await out.asFlattenedList();
      await out.dispose();

      final shape = out.shape; // 例: [1,1] / [1,2]
      final lastDim = shape.isNotEmpty ? shape.last : 0;
      if (flat.isEmpty) return 0.0;

      if (lastDim == 1) {
        // 単一 logit → sigmoid（Ruri Reranker の公式出力形式）
        final logit = flat.first as double;
        debugPrint('[RerankService] 出力 shape=$shape → single logit');
        final score = 1.0 / (1.0 + math.exp(-logit));
        return score.clamp(0.0, 1.0);
      } else if (lastDim == 2) {
        // 2値ロジット → softmax して positive クラス確率
        final a = flat[0] as double;
        final b = flat[1] as double;
        final maxv = math.max(a, b);
        final ea = math.exp(a - maxv);
        final eb = math.exp(b - maxv);
        final positive = eb / (ea + eb); // index=1 を positive と仮定
        debugPrint(
          '[RerankService] 出力 shape=$shape → dual logits, '
          'positive=${positive.toStringAsFixed(4)}',
        );
        return positive.clamp(0.0, 1.0);
      } else {
        // 想定外形状 → フォールバック（rerank 全体スキップの契機）
        debugPrint('[RerankService] 想定外の出力形状 $shape のためスコア 0.0 でフォールバック');
        return 0.0;
      }
    } finally {
      await idsTensor.dispose();
      await maskTensor.dispose();
    }
  }

  Future<void> dispose() async {
    final s = _session;
    _session = null;
    _tokenizer = null;
    _isReady = false;
    _initStarted = false;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
  }
}

/// rerank の入力・出力候補。
class RerankCandidate {
  RerankCandidate({
    required this.workId,
    required this.documentText,
    required this.baseScore,
    this.rerankScore,
    this.rerankApplied = false,
  });

  final int workId;
  final String documentText;

  /// first-stage（hybrid search）の元スコア（0.0〜1.0）。
  final double baseScore;

  /// reranker が出力したスコア（0.0〜1.0）。未計算なら null。
  double? rerankScore;

  /// rerank が実際に適用されたか（UI 表示用）。
  bool rerankApplied;
}
