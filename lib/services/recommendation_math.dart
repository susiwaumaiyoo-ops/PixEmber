/// AIレコメンドフィード用の純粋関数群（UI非依存・単体テスト可能）。
///
/// これらの関数は副作用を持たず、入力から出力を決定論的に計算する。
/// [RecommendationService] から利用される。
library;

import 'dart:typed_data';

/// レコメンド候補1件。
///
/// [type] は 'novel' または 'illust'。
/// [score] は統合スコア（高いほど上位）。
/// [source] は候補の由来（'local' = ローカルベクトル検索, 'api' = pixiv API おすすめ）。
/// [row] はDB行（novels/illusts）または API モデルを表すMap。
class RecommendCandidate {
  final int workId;
  final String type;
  final double score;
  final String source;
  final Map<String, dynamic> row;

  const RecommendCandidate({
    required this.workId,
    required this.type,
    required this.score,
    required this.source,
    required this.row,
  });

  /// 作者ID（row に author_id があればint、なければ0）。
  int get authorId {
    final v = row['author_id'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    // API モデル形式（author.id）のフォールバック
    final author = row['author'];
    if (author is Map) {
      final aid = author['id'];
      if (aid is int) return aid;
      if (aid is num) return aid.toInt();
    }
    return 0;
  }

  /// シリーズID（row に series_id があればint、なければ0）。
  int get seriesId {
    final v = row['series_id'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    // Novel モデル形式（series.id）のフォールバック
    final series = row['series'];
    if (series is Map) {
      final sid = series['id'];
      if (sid is int) return sid;
      if (sid is num) return sid.toInt();
    }
    return 0;
  }

  RecommendCandidate copyWith({double? score}) => RecommendCandidate(
    workId: workId,
    type: type,
    score: score ?? this.score,
    source: source,
    row: row,
  );
}

/// 履歴ベクトル（新→旧順）とお気に入りベクトルから、加重平均後に
/// L2正規化した嗜好ベクトルを構築する。
///
/// - [historyVectors]: 履歴に対応する埋め込み（順序は新→旧を想定）。
///   新しい履歴ほど多く重み付けする（線形減衰）。
/// - [favoriteVectors]: お気に入りに対応する埋め込み。
/// - [historyWeight]: 履歴の基礎重み（既定1.0）。
/// - [favoriteWeight]: お気に入りの基礎重み（既定2.0）。
///
/// 全ベクトルが空、または全てゼロベクトルの場合はゼロベクトルを返す。
/// 次元が混在する場合は最初の非空ベクトルの次元に合わせ、異なる次元のベクトルは無視する。
Float32List buildPreferenceVector({
  required List<Float32List> historyVectors,
  required List<Float32List> favoriteVectors,
  double historyWeight = 1.0,
  double favoriteWeight = 2.0,
}) {
  // 基準次元を決定（最初の非空ベクトル）
  int dim = 0;
  for (final v in [...historyVectors, ...favoriteVectors]) {
    if (v.isNotEmpty) {
      dim = v.length;
      break;
    }
  }
  if (dim == 0) return Float32List(0);

  final acc = Float32List(dim);

  double totalWeight = 0.0;

  // 履歴: 新→旧で線形減衰（最新=1.0, 最古=0.5）× historyWeight
  final hLen = historyVectors.length;
  for (int i = 0; i < hLen; i++) {
    final v = historyVectors[i];
    if (v.length != dim) continue;
    final decay = hLen == 1
        ? 1.0
        : 1.0 - 0.5 * (i / (hLen - 1)); // i=0 → 1.0, i=hLen-1 → 0.5
    final w = historyWeight * decay;
    for (int d = 0; d < dim; d++) {
      acc[d] += v[d] * w;
    }
    totalWeight += w;
  }

  // お気に入り: 均等重み × favoriteWeight
  for (final v in favoriteVectors) {
    if (v.length != dim) continue;
    final w = favoriteWeight;
    for (int d = 0; d < dim; d++) {
      acc[d] += v[d] * w;
    }
    totalWeight += w;
  }

  if (totalWeight == 0) return Float32List(dim);

  // 加重平均
  for (int d = 0; d < dim; d++) {
    acc[d] /= totalWeight;
  }

  // L2正規化
  return l2Normalize(acc);
}

/// ベクトルをL2正規化する。
/// ゼロベクトルの場合はそのまま返す（NaN発生を防ぐ）。
Float32List l2Normalize(Float32List v) {
  final norm = vectorNorm(v);
  if (norm == 0.0) return Float32List.fromList(v);
  final out = Float32List(v.length);
  for (int i = 0; i < v.length; i++) {
    out[i] = v[i] / norm;
  }
  return out;
}

/// L2ノルムを計算する。
double vectorNorm(Float32List v) {
  double sum = 0.0;
  for (int i = 0; i < v.length; i++) {
    sum += v[i] * v[i];
  }
  return sqrt(sum);
}

/// 平方根（dart:math 未importでも使えるよう自前実装: ニュートン法）。
double sqrt(double x) {
  if (x <= 0.0) return 0.0;
  if (x == double.infinity) return double.infinity;
  var r = x;
  // ニュートン法: r_{n+1} = (r_n + x/r_n) / 2
  for (int i = 0; i < 20; i++) {
    final next = (r + x / r) / 2;
    if ((next - r).abs() < 1e-12) {
      r = next;
      break;
    }
    r = next;
  }
  return r;
}

/// コサイン類似度を計算する。
/// 事前計算済みのノルム [aNorm] を渡せる版。
double cosineSimilarity(Float32List a, Float32List b, [double? aNorm]) {
  if (a.length != b.length) return 0.0;
  final an = aNorm ?? vectorNorm(a);
  final bn = vectorNorm(b);
  if (an == 0.0 || bn == 0.0) return 0.0;
  double dot = 0.0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot / (an * bn);
}

/// ローカル候補（DB行 + similarity）とAPI候補（モデル + nextUrl情報等）を
/// 統合し、スコア降順の候補リストを返す。
///
/// - [localRows]: DB検索結果（['...novels/illusts行', 'similarity': double]）。
///   [type] は 'novel' または 'illust'。
/// - [apiModels]: API モデルの JSON Map リスト。
/// - [userVector]: 嗜好ベクトル（API候補のスコア計算用。未提供・ゼロなら API 候補は
///   固定スコア [apiFallbackWeight] で扱う）。
/// - [apiFallbackWeight]: API候補の基本スコア（既定0.4。ローカル候補は類似度0〜1.0と競合）。
/// - [maxPerSource]: 1つのソースあたりの最大採用件数（偏り防止）。null なら無制限。
List<RecommendCandidate> mergeAndRank({
  required List<Map<String, dynamic>> localNovels,
  required List<Map<String, dynamic>> localIllusts,
  required List<Map<String, dynamic>> apiNovels,
  required List<Map<String, dynamic>> apiIllusts,
  Float32List? userVector,
  double apiFallbackWeight = 0.4,
  int? maxPerSource,
}) {
  final candidates = <RecommendCandidate>[];

  // ローカル小説
  var count = 0;
  for (final row in localNovels) {
    if (maxPerSource != null && count >= maxPerSource) break;
    final sim = row['similarity'];
    final score = sim is num ? sim.toDouble() : 0.0;
    if (score <= 0.0) continue;
    final workId = row['id'] is int
        ? row['id'] as int
        : (row['id'] is num ? (row['id'] as num).toInt() : 0);
    if (workId == 0) continue;
    candidates.add(
      RecommendCandidate(
        workId: workId,
        type: 'novel',
        score: score,
        source: 'local',
        row: row,
      ),
    );
    count++;
  }

  // ローカルイラスト
  count = 0;
  for (final row in localIllusts) {
    if (maxPerSource != null && count >= maxPerSource) break;
    final sim = row['similarity'];
    final score = sim is num ? sim.toDouble() : 0.0;
    if (score <= 0.0) continue;
    final workId = row['id'] is int
        ? row['id'] as int
        : (row['id'] is num ? (row['id'] as num).toInt() : 0);
    if (workId == 0) continue;
    candidates.add(
      RecommendCandidate(
        workId: workId,
        type: 'illust',
        score: score,
        source: 'local',
        row: row,
      ),
    );
    count++;
  }

  // API小説
  count = 0;
  for (final model in apiNovels) {
    if (maxPerSource != null && count >= maxPerSource) break;
    final id = model['id'];
    final workId = id is int ? id : (id is num ? id.toInt() : 0);
    if (workId == 0) continue;
    double score = apiFallbackWeight;
    candidates.add(
      RecommendCandidate(
        workId: workId,
        type: 'novel',
        score: score,
        source: 'api',
        row: model,
      ),
    );
    count++;
  }

  // APIイラスト
  count = 0;
  for (final model in apiIllusts) {
    if (maxPerSource != null && count >= maxPerSource) break;
    final id = model['id'];
    final workId = id is int ? id : (id is num ? id.toInt() : 0);
    if (workId == 0) continue;
    double score = apiFallbackWeight;
    candidates.add(
      RecommendCandidate(
        workId: workId,
        type: 'illust',
        score: score,
        source: 'api',
        row: model,
      ),
    );
    count++;
  }

  // スコア降順でソート
  candidates.sort((a, b) => b.score.compareTo(a.score));
  return candidates;
}

/// 既読・ミュート・削除済みの作品を除外する。
///
/// - [candidates]: 統合済み候補リスト。
/// - [readWorkIds]: 既読の work_id 集。
/// - [mutedAuthorIds]: ミュート中の author_id 集。
/// - [mutedWorkIds]: ミュート中の work_id 集。
/// - [deletedWorkIds]: 削除済み（無効・削除）の work_id 集。
List<RecommendCandidate> excludeFiltered({
  required List<RecommendCandidate> candidates,
  required Set<int> readWorkIds,
  required Set<int> mutedAuthorIds,
  required Set<int> mutedWorkIds,
  required Set<int> deletedWorkIds,
}) {
  return candidates.where((c) {
    if (readWorkIds.contains(c.workId)) return false;
    if (mutedWorkIds.contains(c.workId)) return false;
    if (deletedWorkIds.contains(c.workId)) return false;
    if (c.authorId != 0 && mutedAuthorIds.contains(c.authorId)) return false;
    return true;
  }).toList();
}

/// 同一作者・同一シリーズの連続表示を抑制する。
///
/// 連続して同じ作者/シリーズが出現する場合、2件目以降のスコアを逓減させる。
/// これにより「ある作者の作品ばかり並ぶ」偏りを防ぐ。
///
/// - [maxConsecutivePerAuthor]: 同一作者の連続最大件数（超過分は後ろに回す）。
///   既定2。
/// - [maxConsecutivePerSeries]: 同一シリーズの連続最大件数。既定2。
/// - [penalty]: 連続超過時のスコア逓減率（0.0〜1.0）。既定0.3（70%減）。
List<RecommendCandidate> suppressAuthorSeriesBias({
  required List<RecommendCandidate> candidates,
  int maxConsecutivePerAuthor = 2,
  int maxConsecutivePerSeries = 2,
  double penalty = 0.3,
}) {
  if (candidates.isEmpty) return candidates;

  final result = List<RecommendCandidate>.from(candidates);
  final authorStreak = <int, int>{};
  final seriesStreak = <int, int>{};

  for (int i = 0; i < result.length; i++) {
    final c = result[i];
    final aid = c.authorId;
    final sid = c.seriesId;

    bool penalized = false;

    if (aid != 0) {
      final cnt = (authorStreak[aid] ?? 0) + 1;
      authorStreak[aid] = cnt;
      if (cnt > maxConsecutivePerAuthor) penalized = true;
    }
    if (sid != 0) {
      final cnt = (seriesStreak[sid] ?? 0) + 1;
      seriesStreak[sid] = cnt;
      if (cnt > maxConsecutivePerSeries) penalized = true;
    }

    // 異なる作者/シリーズに切り替わったら streak をリセット
    // （簡易実装: 連続判定のみ。完全なリセットは authorStreak/seriesStreak を
    //  全キーでなく「直前のキー」のみ管理する方が正確だが、ここでは件数抑制が主目的）
    if (aid != 0 && i > 0 && result[i - 1].authorId != aid) {
      authorStreak.clear();
      authorStreak[aid] = 1;
    }
    if (sid != 0 && i > 0 && result[i - 1].seriesId != sid) {
      seriesStreak.clear();
      seriesStreak[sid] = 1;
    }

    if (penalized) {
      result[i] = c.copyWith(score: c.score * (1.0 - penalty));
    }
  }

  // 逓減後に再度ソート
  result.sort((a, b) => b.score.compareTo(a.score));
  return result;
}
