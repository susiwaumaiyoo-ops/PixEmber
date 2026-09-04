// 今日の再発見カード（非AI機能パック Phase N4）。
//
// 設計:
// - 候補源（すべて端末内データ中心・非ブロッキング）:
//   1. 休眠タグ（DormantTagsService 再利用）
//   2. シリーズの続き（SeriesProgressService 再利用・次の未読話）
//   3. 長く見ていない作者（history × novels/illusts の author_id 結合）
//   4. ダウンロード済み・未読の小説（novel_text キャッシュ × 読了状態）
// - 純粋関数 buildDiscoveryCards が「優先度降順（同点は入力順）・重複排除・最大N件」
//   を決める。UI は非表示件数（候補0件）に自動で非表示になる。
// - ネットワークはシリーズ取得の1回程度のみ。失敗は各候補源単位で握りつぶし
//   （他候補は表示される）。外部送信はしない。

import 'database_service.dart';
import 'dormant_tags_service.dart';
import 'series_progress_service.dart';

/// カード種別。
enum DiscoveryCardKind {
  dormantTag,
  seriesNext,
  longUnseenAuthor,
  downloadedUnread,
}

/// タップ先。UI はこの enum を見て遷移先を決定する（テストで検証）。
enum DiscoveryTapTarget {
  searchTag, // tag → 検索実行
  openNovel, // workId → 小説詳細
  openAuthor, // authorId → 作者プロフィール
}

/// 候補（buildDiscoveryCards の入力）。priority が大きいほど優先。
class DiscoveryCandidate {
  final DiscoveryCardKind kind;
  final String title;
  final String subtitle;
  final int priority;
  final String? tag;
  final int? seriesId;
  final int? workId;
  final int? authorId;
  final String? authorName;
  final String dedupeKey;

  const DiscoveryCandidate({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.priority,
    this.tag,
    this.seriesId,
    this.workId,
    this.authorId,
    this.authorName,
    required this.dedupeKey,
  });

  /// 種別に応じたタップ先（候補段階でも検証可能）。
  DiscoveryTapTarget get tapTarget {
    switch (kind) {
      case DiscoveryCardKind.dormantTag:
        return DiscoveryTapTarget.searchTag;
      case DiscoveryCardKind.seriesNext:
      case DiscoveryCardKind.downloadedUnread:
        return DiscoveryTapTarget.openNovel;
      case DiscoveryCardKind.longUnseenAuthor:
        return DiscoveryTapTarget.openAuthor;
    }
  }

  /// タップ先の必須フィールドがあるか。
  bool get hasTapPayload {
    switch (tapTarget) {
      case DiscoveryTapTarget.searchTag:
        return (tag ?? '').isNotEmpty;
      case DiscoveryTapTarget.openNovel:
        return (workId ?? 0) > 0;
      case DiscoveryTapTarget.openAuthor:
        return (authorId ?? 0) > 0;
    }
  }
}

/// 表示用カード。
class DiscoveryCard {
  final DiscoveryCardKind kind;
  final String title;
  final String subtitle;
  final int priority;
  final String? tag;
  final int? seriesId;
  final int? workId;
  final int? authorId;
  final String? authorName;

  const DiscoveryCard({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.priority,
    this.tag,
    this.seriesId,
    this.workId,
    this.authorId,
    this.authorName,
  });

  DiscoveryCard._from(DiscoveryCandidate c)
    : kind = c.kind,
      title = c.title,
      subtitle = c.subtitle,
      priority = c.priority,
      tag = c.tag,
      seriesId = c.seriesId,
      workId = c.workId,
      authorId = c.authorId,
      authorName = c.authorName;

  /// 種別に応じたタップ先。
  DiscoveryTapTarget get tapTarget {
    switch (kind) {
      case DiscoveryCardKind.dormantTag:
        return DiscoveryTapTarget.searchTag;
      case DiscoveryCardKind.seriesNext:
      case DiscoveryCardKind.downloadedUnread:
        return DiscoveryTapTarget.openNovel;
      case DiscoveryCardKind.longUnseenAuthor:
        return DiscoveryTapTarget.openAuthor;
    }
  }

  /// タップ先の必須フィールドがあるか（UI 側が null チェックの前に確認用）。
  bool get hasTapPayload {
    switch (tapTarget) {
      case DiscoveryTapTarget.searchTag:
        return (tag ?? '').isNotEmpty;
      case DiscoveryTapTarget.openNovel:
        return (workId ?? 0) > 0;
      case DiscoveryTapTarget.openAuthor:
        return (authorId ?? 0) > 0;
    }
  }
}

/// 内部用: 優先度+元インデックスで安定ソートするための装飾。
class _IndexedCandidate {
  final DiscoveryCandidate item;
  final int index;
  const _IndexedCandidate(this.item, this.index);
}

/// 純粋関数: 候補を優先度降順（同点は入力順）・重複排除して最大 [maxCards] 件にまとめる。
///
/// 重複排除:
/// - [DiscoveryCandidate.dedupeKey] が同じものは先頭（高優先）1件のみ採用。
/// - 別種別でも workId が重複する場合は先に採用した方のみ採用（同一作品の二重表示防止）。
List<DiscoveryCard> buildDiscoveryCards(
  List<DiscoveryCandidate> candidates, {
  int maxCards = 3,
}) {
  if (candidates.isEmpty) return const [];
  final indexed = List<_IndexedCandidate>.generate(
    candidates.length,
    (i) => _IndexedCandidate(candidates[i], i),
  );
  indexed.sort((a, b) {
    final p = b.item.priority.compareTo(a.item.priority);
    if (p != 0) return p;
    return a.index.compareTo(b.index);
  });
  final seenKeys = <String>{};
  final usedWorkIds = <int>{};
  final out = <DiscoveryCard>[];
  for (final e in indexed) {
    final c = e.item;
    if (seenKeys.contains(c.dedupeKey)) continue;
    final wid = c.workId;
    if (wid != null && usedWorkIds.contains(wid)) continue;
    seenKeys.add(c.dedupeKey);
    if (wid != null) usedWorkIds.add(wid);
    out.add(DiscoveryCard._from(c));
    if (out.length >= maxCards) break;
  }
  return out;
}

/// 作者の閲覧統計（rankLongUnseenAuthors の入力）。
class AuthorSeen {
  final String name;
  final int? authorId;
  final DateTime lastSeen;
  final int count;
  const AuthorSeen({
    required this.name,
    this.authorId,
    required this.lastSeen,
    required this.count,
  });
}

/// 純粋関数: 「過去よく見ていたのに最近見ていない」作者を候補化。
///
/// 条件: 閲覧回数が [minCount] 以上かつ最終閲覧が [minDaysSinceSeen] 日以上前。
/// 並び: 最終閲覧が新しい順（休眠中でも「まだ忘れられていない」作者を先に）。
List<DiscoveryCandidate> rankLongUnseenAuthors(
  List<AuthorSeen> authors, {
  DateTime? now,
  int minDaysSinceSeen = 14,
  int minCount = 2,
  int maxItems = 2,
}) {
  final n = now ?? DateTime.now();
  final cutoff = n.subtract(Duration(days: minDaysSinceSeen));
  final list =
      authors
          .where((a) => a.count >= minCount && !a.lastSeen.isAfter(cutoff))
          .toList()
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
  return list
      .take(maxItems)
      .map(
        (a) => DiscoveryCandidate(
          kind: DiscoveryCardKind.longUnseenAuthor,
          title: a.name,
          subtitle: '最近見ていない作者',
          priority: 70,
          authorId: a.authorId,
          authorName: a.name,
          dedupeKey: 'author:${a.name}',
        ),
      )
      .toList();
}

/// キャッシュ済み小説の参照（pickDownloadedUnread の入力）。
class CachedNovelRef {
  final int workId;
  final String title;
  final String? authorName;
  const CachedNovelRef({
    required this.workId,
    required this.title,
    this.authorName,
  });
}

/// 純粋関数: オフライン保存済みのうち未読（読了状態を SeriesProgressService 判定で流用）を候補化。
List<DiscoveryCandidate> pickDownloadedUnread(
  List<CachedNovelRef> cached, {
  required Map<int, int> readLaterStatusByWork,
  required Map<int, double> progressByWork,
  int maxItems = 2,
  double readThreshold = 0.995,
}) {
  final out = <DiscoveryCandidate>[];
  for (final c in cached) {
    final read = isWorkRead(
      workId: c.workId,
      readLaterStatusByWork: readLaterStatusByWork,
      progressByWork: progressByWork,
      readThreshold: readThreshold,
    );
    if (read) continue;
    final author = (c.authorName ?? '').trim();
    out.add(
      DiscoveryCandidate(
        kind: DiscoveryCardKind.downloadedUnread,
        title: c.title,
        subtitle: author.isNotEmpty ? 'オフライン保存: $author' : 'オフライン保存済み',
        priority: 90,
        workId: c.workId,
        dedupeKey: 'work:${c.workId}',
      ),
    );
    if (out.length >= maxItems) break;
  }
  return out;
}

String _trunc(String s, int n) {
  final t = s.trim();
  if (t.length <= n) return t;
  return '${t.substring(0, n)}…';
}

DateTime? _parseLocal(String? s) {
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// 今日の再発見カード生成サービス（シングルトン・非ブロッキング）。
class DiscoveryCardService {
  static final DiscoveryCardService _instance =
      DiscoveryCardService._internal();
  factory DiscoveryCardService() => _instance;
  DiscoveryCardService._internal();

  /// 候補を集めて最大 [maxCards] 件のカードを返す。全候補源が失敗しても空リスト（UI は非表示）。
  Future<List<DiscoveryCard>> fetch({DateTime? now, int maxCards = 3}) async {
    final cands = <DiscoveryCandidate>[];

    // 1. 休眠タグ（上位2件）
    try {
      final dormant = await DormantTagsService().fetch(now: now);
      for (final d in dormant.take(2)) {
        cands.add(
          DiscoveryCandidate(
            kind: DiscoveryCardKind.dormantTag,
            title: d.tag,
            subtitle: '過去${d.pastCount}回読んだのに ${d.daysSinceLast}日出ていない',
            priority: 80,
            tag: d.tag,
            dedupeKey: 'tag:${d.tag}',
          ),
        );
      }
    } catch (_) {}

    // 2. シリーズの続き（候補シリーズ最大2本・次の未読話がある場合のみ）
    try {
      final seriesIds = await _candidateSeriesIds();
      for (final sid in seriesIds.take(2)) {
        final progress = await SeriesProgressService().fetch(sid);
        final next = progress?.nextUnreadWork;
        if (progress != null && next != null) {
          cands.add(
            DiscoveryCandidate(
              kind: DiscoveryCardKind.seriesNext,
              title: 'シリーズの続き',
              subtitle:
                  '${progress.readCount}/${progress.totalCount} 話読了 ・ 次: ${_trunc(next.title, 16)}',
              priority: 100,
              seriesId: sid,
              workId: next.id,
              dedupeKey: 'series:$sid',
            ),
          );
        }
      }
    } catch (_) {}

    // 3. 長く見ていない作者（上位2件）
    try {
      final authors = await _authorSeenStats();
      cands.addAll(rankLongUnseenAuthors(authors, now: now));
    } catch (_) {}

    // 4. ダウンロード済み・未読小説（上位2件）
    try {
      final cached = await DatabaseService().getCachedNovelTexts();
      final refs = cached
          .map(
            (r) => CachedNovelRef(
              workId: (r['work_id'] as num?)?.toInt() ?? 0,
              title: (r['title'] as String?) ?? 'タイトル不明',
              authorName: r['author_name'] as String?,
            ),
          )
          .where((r) => r.workId > 0)
          .toList();
      final (statusByWork, progressByWork) = await SeriesProgressService()
          .localReadingState();
      cands.addAll(
        pickDownloadedUnread(
          refs,
          readLaterStatusByWork: statusByWork,
          progressByWork: progressByWork,
        ),
      );
    } catch (_) {}

    return buildDiscoveryCards(cands, maxCards: maxCards);
  }

  /// 履歴で最近触れた小説から候補シリーズIDを抽出（重複除去・新しい順）。
  Future<List<int>> _candidateSeriesIds() async {
    try {
      final db = await DatabaseService().database;
      final rows = await db.rawQuery(
        'SELECT n.series_id FROM novels n '
        'JOIN history h ON h.work_id = n.id '
        'WHERE n.series_id > 0 '
        'ORDER BY h.created_at DESC LIMIT 60',
      );
      final out = <int>[];
      final seen = <int>{};
      for (final r in rows) {
        final sid = (r['series_id'] as num?)?.toInt() ?? 0;
        if (sid <= 0) continue;
        if (!seen.contains(sid)) {
          seen.add(sid);
          out.add(sid);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// history × (novels ∪ illusts) で作者ごとの最終閲覧・回数を集計。
  Future<List<AuthorSeen>> _authorSeenStats() async {
    try {
      final db = await DatabaseService().database;
      final rows = await db.rawQuery(
        'SELECT h.author_name AS name, m.author_id AS author_id, '
        'MAX(h.created_at) AS last_seen, COUNT(*) AS cnt '
        'FROM history h '
        'JOIN (SELECT id, author_id FROM novels '
        '       UNION ALL SELECT id, author_id FROM illusts) m '
        '  ON m.id = h.work_id '
        "WHERE h.author_name IS NOT NULL AND h.author_name != '' "
        'GROUP BY h.author_name',
      );
      final out = <AuthorSeen>[];
      for (final r in rows) {
        final dt = _parseLocal(r['last_seen'] as String?);
        if (dt == null) continue;
        out.add(
          AuthorSeen(
            name: (r['name'] as String?) ?? '',
            authorId: (r['author_id'] as num?)?.toInt(),
            lastSeen: dt,
            count: (r['cnt'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
