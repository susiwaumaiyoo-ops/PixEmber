/// 一致度ラベル（数値%ではなく相対的な近さ）の共通フォーマット関数。
///
/// 全画面（フィーリング発掘・小説カード等）で同一のルールを適用するため、
/// スコア表示は必ずこの関数を経由する。
///
/// ルール:
/// - 生類似度を「かなり近い / 近い / やや近い」の 3 段階に変換（数値%は出さない）。
/// - embedding 未生成（AI未解析）または lexical のみヒット時は「キーワード一致」。
/// - embedding 未生成かつ lexical でもない場合は「AI未解析」。
/// - rerank は順位付け（ソート）にのみ使い、ラベルには影響させない。
class ScoreFormat {
  const ScoreFormat._();

  /// 一致度ラベルを生成する。
  ///
  /// [semanticScore] 正規化済み類似度（0.0〜1.0）。null 可。
  /// [semanticComputed] 意味ベクトルが実際に計算・活用されているか。
  /// [lexicalHit] キーワード（lexical）のみでヒットしたか。
  /// [rerankApplied] 高精度モード（Reranker）で順位付けに使われたか。
  static String formatMatchLabel({
    double? semanticScore,
    required bool semanticComputed,
    required bool lexicalHit,
    bool rerankApplied = false,
  }) {
    // embedding 未生成時
    if (!semanticComputed) {
      return lexicalHit ? 'キーワード一致' : 'AI未解析';
    }
    final s = semanticScore ?? 0.0;
    final base = s >= 0.70 ? 'かなり近い' : (s >= 0.45 ? '近い' : 'やや近い');
    return rerankApplied ? '$base・高精度' : base;
  }

  /// 一致度を % 表記で返す（embedding の生類似度ベース）。
  ///
  /// [score] 正規化済み類似度（0.0〜1.0）。null / NaN は表示しない（空文字）。
  /// [semanticComputed] 意味ベクトルが実際に計算・活用されているか。
  /// [lexicalHit] キーワード（lexical）のみでヒットしたか。
  /// [rerankApplied] 高精度モード（Reranker）で順位付けに使われたか。
  ///
  /// - embedding 未生成 + lexical のみ → 「キーワード一致」
  /// - embedding 未生成 + lexical でもない → 「AI未解析」
  /// - 通常: 「XX%」（整数、0〜100 に clamp、小数点なし）
  /// - rerank 適用時: 「XX% ・高精度」
  static String formatMatchPercent({
    double? score,
    required bool semanticComputed,
    required bool lexicalHit,
    bool rerankApplied = false,
  }) {
    if (!semanticComputed) {
      return lexicalHit ? 'キーワード一致' : 'AI未解析';
    }
    if (score == null || score.isNaN) return '';
    final pct = (score * 100).round().clamp(0, 100);
    final base = '$pct%';
    return rerankApplied ? '$base ・高精度' : base;
  }
}
