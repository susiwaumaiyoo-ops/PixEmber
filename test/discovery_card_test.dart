// 今日の再発見カードサービス（非AI機能パック Phase N4）のユニットテスト。
//
// ネットワーク・DB を使わない純粋関数
// （buildDiscoveryCards / rankLongUnseenAuthors / pickDownloadedUnread）
// とタップ先モデルの検証のみを行う。

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/discovery_card_service.dart';

DiscoveryCandidate _tag(String tag, {int priority = 80}) => DiscoveryCandidate(
  kind: DiscoveryCardKind.dormantTag,
  title: tag,
  subtitle: '休眠タグ',
  priority: priority,
  tag: tag,
  dedupeKey: 'tag:$tag',
);

DiscoveryCandidate _series(int seriesId, int workId, {int priority = 100}) =>
    DiscoveryCandidate(
      kind: DiscoveryCardKind.seriesNext,
      title: 'シリーズの続き',
      subtitle: '3/12 話読了',
      priority: priority,
      seriesId: seriesId,
      workId: workId,
      dedupeKey: 'series:$seriesId',
    );

DiscoveryCandidate _author(String name, {int priority = 70}) =>
    DiscoveryCandidate(
      kind: DiscoveryCardKind.longUnseenAuthor,
      title: name,
      subtitle: '最近見ていない作者',
      priority: priority,
      authorId: name.hashCode,
      authorName: name,
      dedupeKey: 'author:$name',
    );

DiscoveryCandidate _unread(int workId, {int priority = 90}) =>
    DiscoveryCandidate(
      kind: DiscoveryCardKind.downloadedUnread,
      title: 'W$workId',
      subtitle: 'オフライン保存済み',
      priority: priority,
      workId: workId,
      dedupeKey: 'work:$workId',
    );

void main() {
  final now = DateTime(2026, 9, 4, 12);

  group('buildDiscoveryCards', () {
    test('優先度降順に並び替え（入力順とは異なる）', () {
      final cards = buildDiscoveryCards([
        _author('A'),
        _series(1, 100),
        _tag('t'),
      ]);
      expect(cards.map((c) => c.kind).toList(), [
        DiscoveryCardKind.seriesNext,
        DiscoveryCardKind.dormantTag,
        DiscoveryCardKind.longUnseenAuthor,
      ]);
    });

    test('同点は入力順を維持（安定ソート）', () {
      final cards = buildDiscoveryCards([
        _tag('t1'),
        _tag('t2'),
        _tag('t3'),
        _tag('t4'),
      ]);
      expect(cards.map((c) => c.tag).toList(), ['t1', 't2', 't3']);
      expect(cards.length, 3); // max 3
    });

    test('dedupeKey 重複は先頭（高優先）のみ採用', () {
      final cards = buildDiscoveryCards([
        _tag('dup'),
        _tag('dup'),
        _tag('other'),
      ]);
      expect(cards.length, 2);
      expect(cards.first.tag, 'dup');
    });

    test('別種別でも同一 workId は先に採用した方のみ採用', () {
      final cards = buildDiscoveryCards([
        _series(1, 55),
        _unread(55),
        _unread(56),
      ]);
      // series(100) が先。unread(55) は workId 重複で除外、unread(56) は採用。
      expect(cards.map((c) => c.kind).toList(), [
        DiscoveryCardKind.seriesNext,
        DiscoveryCardKind.downloadedUnread,
      ]);
      expect(cards[1].workId, 56);
    });

    test('最大件数は maxCards で切り詰め', () {
      final cards = buildDiscoveryCards([
        _series(1, 1),
        _series(2, 2),
        _series(3, 3),
        _series(4, 4),
        _series(5, 5),
      ], maxCards: 2);
      expect(cards.length, 2);
    });

    test('空入力なら空リスト（UI は非表示）', () {
      expect(buildDiscoveryCards(const []), isEmpty);
    });

    test('全候補が重複で埋まる場合は採用分のみ返す', () {
      final cards = buildDiscoveryCards([
        _series(9, 77),
        _series(9, 78), // dedupeKey 'series:9' 重複
        _series(9, 79), // 同
        _tag('x'),
      ]);
      expect(cards.length, 2);
      expect(cards[0].workId, 77);
      expect(cards[1].kind, DiscoveryCardKind.dormantTag);
    });
  });

  group('タップ先モデル', () {
    test('種別ごとに正しい tapTarget', () {
      expect(_tag('t').tapTarget, DiscoveryTapTarget.searchTag);
      expect(_series(1, 2).tapTarget, DiscoveryTapTarget.openNovel);
      expect(_unread(3).tapTarget, DiscoveryTapTarget.openNovel);
      expect(_author('a').tapTarget, DiscoveryTapTarget.openAuthor);
    });

    test('hasTapPayload は必須フィールドの存在を検証', () {
      expect(_tag('t').hasTapPayload, isTrue);
      expect(
        const DiscoveryCandidate(
          kind: DiscoveryCardKind.dormantTag,
          title: '',
          subtitle: '',
          priority: 80,
          tag: '',
          dedupeKey: 'tag:',
        ).tapTarget,
        DiscoveryTapTarget.searchTag,
      );
      expect(_series(1, 0).hasTapPayload, isFalse);
      expect(_series(1, 123).hasTapPayload, isTrue);
      expect(_unread(0).hasTapPayload, isFalse);
      expect(_author('a').hasTapPayload, isTrue);
    });
  });

  group('rankLongUnseenAuthors', () {
    AuthorSeen mk(String name, int daysAgo, {int count = 5, int? id}) =>
        AuthorSeen(
          name: name,
          authorId: id,
          lastSeen: now.subtract(Duration(days: daysAgo)),
          count: count,
        );

    test('条件を満たさない作者は除外（回数がたりない / 最近見ている）', () {
      final cands = rankLongUnseenAuthors([
        mk('active', 1), // 最近見ている
        mk('rare', 40, count: 1), // 回数がたりない
        mk('good', 20),
      ], now: now);
      expect(cands.map((c) => c.title).toList(), ['good']);
    });

    test('最終閲覧が新しい順に並ぶ', () {
      final cands = rankLongUnseenAuthors([
        mk('old', 60),
        mk('new', 15),
      ], now: now);
      expect(cands.map((c) => c.title).toList(), ['new', 'old']);
    });

    test('maxItems で切り詰め', () {
      final cands = rankLongUnseenAuthors(
        [mk('a1', 15), mk('a2', 16), mk('a3', 17)],
        now: now,
        maxItems: 2,
      );
      expect(cands.length, 2);
    });

    test('空入力なら空リスト', () {
      expect(rankLongUnseenAuthors(const [], now: now), isEmpty);
    });

    test('候補は kind=longUnseenAuthor かつ authorId を保持', () {
      final cands = rankLongUnseenAuthors([mk('x', 30, id: 42)], now: now);
      expect(cands.single.kind, DiscoveryCardKind.longUnseenAuthor);
      expect(cands.single.authorId, 42);
    });
  });

  group('pickDownloadedUnread', () {
    test('読了（status=2）は除外・未読のみ採用', () {
      final cands = pickDownloadedUnread(
        [
          CachedNovelRef(workId: 1, title: 'W1'),
          CachedNovelRef(workId: 2, title: 'W2'),
          CachedNovelRef(workId: 3, title: 'W3'),
        ],
        readLaterStatusByWork: {2: 2},
        progressByWork: {},
      );
      expect(cands.map((c) => c.workId).toList(), [1, 3]);
    });

    test('しおり進捗が閾値以上は読了扱い（除外）', () {
      final cands = pickDownloadedUnread(
        [
          CachedNovelRef(workId: 1, title: 'W1'),
          CachedNovelRef(workId: 2, title: 'W2'),
        ],
        readLaterStatusByWork: {},
        progressByWork: {2: 1.0},
      );
      expect(cands.map((c) => c.workId).toList(), [1]);
    });

    test('maxItems で切り詰め', () {
      final cands = pickDownloadedUnread(
        [
          CachedNovelRef(workId: 1, title: 'W1'),
          CachedNovelRef(workId: 2, title: 'W2'),
          CachedNovelRef(workId: 3, title: 'W3'),
        ],
        readLaterStatusByWork: {},
        progressByWork: {},
        maxItems: 1,
      );
      expect(cands.length, 1);
      expect(cands.single.workId, 1);
    });

    test('空入力なら空リスト', () {
      expect(
        pickDownloadedUnread(
          const [],
          readLaterStatusByWork: {},
          progressByWork: {},
        ),
        isEmpty,
      );
    });

    test('作者名があるとサブタイトルに表示', () {
      final cands = pickDownloadedUnread(
        [CachedNovelRef(workId: 1, title: 'W1', authorName: '山田')],
        readLaterStatusByWork: {},
        progressByWork: {},
      );
      expect(cands.single.subtitle, contains('山田'));
    });
  });
}
