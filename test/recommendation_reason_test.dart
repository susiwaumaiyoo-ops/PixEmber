// AIレコメンド理由説明（非AI機能パック Phase N2）のユニットテスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/recommendation_math.dart';

RecommendCandidate _cand({
  int workId = 1,
  String type = 'novel',
  double score = 0.8,
  String source = 'local',
  Map<String, dynamic>? row,
}) {
  return RecommendCandidate(
    workId: workId,
    type: type,
    score: score,
    source: source,
    row: row ?? {'id': workId, 'title': '作品'},
  );
}

final _recent = [
  RecentWorkRef(workId: 10, title: '直近の作品', tags: ['猫', '青']),
  RecentWorkRef(workId: 11, title: 'もう一つの直近', tags: ['青', '夜']),
];

final _favorites = [
  RecentWorkRef(workId: 20, title: 'お気に入り作品', tags: ['猫', '赤']),
];

void main() {
  group('extractTagsFromRow', () {
    test('DB行: tags_json から解析', () {
      expect(extractTagsFromRow({'tags': 'a,b', 'tags_json': '["a","b"]'}), [
        'a',
        'b',
      ]);
    });

    test('DB行: tags_json なしなら tags をカンマ分割', () {
      expect(extractTagsFromRow({'tags': ' a , b ,c '}), ['a', 'b', 'c']);
    });

    test('APIモデル: {name} のリスト', () {
      expect(
        extractTagsFromRow({
          'tags': const [
            {'name': 'x'},
            {'name': 'y'},
          ],
        }),
        ['x', 'y'],
      );
    });

    test('タグなし → 空リスト', () {
      expect(extractTagsFromRow({}), isEmpty);
      expect(extractTagsFromRow({'tags': ''}), isEmpty);
    });
  });

  group('authorNameFromRow', () {
    test('DB行: author_name', () {
      expect(authorNameFromRow({'author_name': ' 太郎 '}), '太郎');
    });

    test('APIモデル: user.name', () {
      expect(
        authorNameFromRow({
          'user': {'name': '花子'},
        }),
        '花子',
      );
    });

    test('欠損 → 空文字', () {
      expect(authorNameFromRow({}), '');
    });
  });

  group('buildRecommendationReason', () {
    test('タグ一致 → matchedTags と「N件一致」ラベル', () {
      final r = buildRecommendationReason(
        candidate: _cand(row: {'id': 1, 'tags_json': '["猫","青","犬"]'}),
        recentWorks: _recent,
        favoriteWorks: _favorites,
        knownAuthorNames: const {},
      );
      expect(r.matchedTags, ['猫', '青']);
      expect(r.labels, contains('タグ2件一致'));
    });

    test('直近作品と共通タグ2以上 → 最近読んだ作品に近い', () {
      final r = buildRecommendationReason(
        candidate: _cand(row: {'id': 1, 'tags_json': '["猫","青"]'}),
        recentWorks: _recent,
        favoriteWorks: const [],
        knownAuthorNames: const {},
      );
      expect(r.similarToRecentWorks, hasLength(1));
      expect(r.similarToRecentWorks.first.workId, 10);
      expect(r.labels, contains('最近読んだ作品に近い'));
    });

    test('共通タグ1つでは類似としない', () {
      final r = buildRecommendationReason(
        candidate: _cand(row: {'id': 1, 'tags_json': '["青"]'}),
        recentWorks: _recent,
        favoriteWorks: const [],
        knownAuthorNames: const {},
      );
      expect(r.similarToRecentWorks, isEmpty);
      expect(r.labels, isNot(contains('最近読んだ作品に近い')));
    });

    test('お気に入りタグ一致 → お気に入り傾向', () {
      final r = buildRecommendationReason(
        candidate: _cand(row: {'id': 1, 'tags_json': '["赤"]'}),
        recentWorks: const [],
        favoriteWorks: _favorites,
        knownAuthorNames: const {},
      );
      expect(r.fromFavorites, isTrue);
      expect(r.labels, contains('お気に入り傾向'));
    });

    test('履歴にある作者・未読作品 → 未読の作者', () {
      final r = buildRecommendationReason(
        candidate: _cand(row: {'id': 1, 'author_name': '太郎'}),
        recentWorks: const [],
        favoriteWorks: const [],
        knownAuthorNames: const {'太郎'},
      );
      expect(r.unreadAuthor, isTrue);
      expect(r.labels, contains('未読の作者'));
    });

    test('既知でない作者 → 未読の作者にならない', () {
      final r = buildRecommendationReason(
        candidate: _cand(row: {'id': 1, 'author_name': 'unknown'}),
        recentWorks: const [],
        favoriteWorks: const [],
        knownAuthorNames: const {'太郎'},
      );
      expect(r.unreadAuthor, isFalse);
    });

    test('ローカル候補 → semanticScore バンドラベル', () {
      final r = buildRecommendationReason(
        candidate: _cand(score: 0.9),
        recentWorks: const [],
        favoriteWorks: const [],
        knownAuthorNames: const {},
      );
      expect(r.semanticScore, 0.9);
      expect(r.bandLabel, '類似度が高い');
      expect(r.labels, contains('類似度が高い'));
    });

    test('API候補 → semanticScore なし・バンドラベルなし', () {
      final r = buildRecommendationReason(
        candidate: _cand(source: 'api', score: 0.4),
        recentWorks: const [],
        favoriteWorks: const [],
        knownAuthorNames: const {},
      );
      expect(r.semanticScore, isNull);
      expect(r.bandLabel, isNull);
      expect(r.labels, isNot(contains('類似度が高い')));
    });

    test('理由なし（api + 重複なし）→ hasReasons false', () {
      final r = buildRecommendationReason(
        candidate: _cand(source: 'api', row: {'id': 1, 'tags_json': '["z"]'}),
        recentWorks: _recent,
        favoriteWorks: _favorites,
        knownAuthorNames: const {},
      );
      expect(r.hasReasons, isFalse);
      expect(r.labels, isEmpty);
    });
  });

  group('buildReasonSheetLines（シートモデル）', () {
    test('理由あり → ラベル群を返す', () {
      final r = buildRecommendationReason(
        candidate: _cand(row: {'id': 1, 'tags_json': '["猫"]'}),
        recentWorks: _recent,
        favoriteWorks: _favorites,
        knownAuthorNames: const {},
      );
      expect(buildReasonSheetLines(r), contains('タグ1件一致'));
      expect(buildReasonSheetLines(r), isNot(isEmpty));
    });

    test('理由なし → 「総合的な類似度で推薦」の1行', () {
      final r = RecommendationReason();
      expect(buildReasonSheetLines(r), ['総合的な類似度で推薦']);
    });
  });
}
