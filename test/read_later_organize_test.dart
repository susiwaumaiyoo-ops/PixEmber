// あとで読む整理サービス（非AI機能パック Phase N5）のユニットテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/read_later_organize_service.dart';

OrganizeItemData _it(
  int id, {
  List<String> tags = const [],
  String title = '',
  List<double>? emb,
}) => OrganizeItemData(
  workId: id,
  title: title.isEmpty ? 'work$id' : title,
  tags: tags,
  embedding: emb,
);

OrganizeGroup _g(String id, List<int> ids, [String name = 'x']) =>
    OrganizeGroup(
      id: id,
      suggestedName: name,
      basis: 'tag',
      items: [for (final i in ids) _it(i)],
    );

void main() {
  group('groupByTags', () {
    test('タグ頻度順にグループ化し、作品は最大1グループにのみ属する', () {
      final items = [
        _it(1, tags: ['cat', 'dog']),
        _it(2, tags: ['cat']),
        _it(3, tags: ['cat', 'dog']),
        _it(4, tags: ['dog']),
      ];
      final groups = groupByTags(items);
      // cat は 3 件、dog は 3 件だが cat が先行（頻度同点→名前順）。
      // dog 側は cat 吸収後に未割り当て1件のみ → minSize 不足で「その他」へ。
      expect(groups, hasLength(2));
      expect(groups.first.id, 'tag:cat');
      expect(groups.first.suggestedName, 'cat');
      final ids = groups.first.items.map((i) => i.workId).toList();
      expect(ids, containsAll([1, 2, 3]));
      expect(groups.last.id, 'rest');
      expect(groups.last.items.map((i) => i.workId), [4]);
      // 各作品は高々1グループにのみ属する（重複なし）。
      final all = groups.expand((g) => g.items.map((i) => i.workId)).toList();
      expect(all, hasLength(4));
      expect(all.toSet(), {1, 2, 3, 4});
    });

    test('頻度上位タグが先にグループになる', () {
      final items = [
        _it(1, tags: ['b', 'a']),
        _it(2, tags: ['a']),
        _it(3, tags: ['a']),
        _it(4, tags: ['b']),
      ];
      final groups = groupByTags(items);
      expect(groups.first.id, 'tag:a');
      expect(groups.first.items.map((i) => i.workId).toSet(), {1, 2, 3});
    });

    test('minSize 未満のタグはグループにならない（その他に入る）', () {
      final items = [
        _it(1, tags: ['solo']),
        _it(2, tags: ['solo']),
      ];
      final groups = groupByTags(items, minSize: 3);
      expect(groups, hasLength(1));
      expect(groups.first.id, 'rest');
      expect(groups.first.suggestedName, 'その他');
    });

    test('未割り当ての作品は「その他」に入る', () {
      final items = [
        _it(1, tags: ['cat']),
        _it(2, tags: ['cat']),
        _it(3), // タグなし
      ];
      final groups = groupByTags(items);
      expect(groups, hasLength(2));
      final rest = groups.firstWhere((g) => g.id == 'rest');
      expect(rest.items.map((i) => i.workId), [3]);
    });

    test('maxGroups でグループ数を制限する', () {
      final items = [
        _it(1, tags: ['a', 'b', 'c']),
        _it(2, tags: ['a', 'b', 'c']),
        _it(3, tags: ['a']),
        _it(4, tags: ['b']),
      ];
      final groups = groupByTags(items, maxGroups: 1);
      expect(groups.where((g) => g.basis == 'tag'), hasLength(1));
    });

    test('空リストは空提案', () {
      expect(groupByTags(const []), isEmpty);
    });
  });

  group('suggestGroupName', () {
    test('最頻タグを返す', () {
      expect(suggestGroupName(['cat', 'cat', 'dog']), 'cat');
    });

    test('同点なら上位2つを「・」で結合', () {
      expect(suggestGroupName(['cat', 'dog', 'cat', 'dog']), 'cat・dog');
    });

    test('空なら「混合」', () {
      expect(suggestGroupName(const []), '混合');
    });
  });

  group('clusterByEmbedding', () {
    test('直交ベクトルは別クラスタに分離', () {
      final items = [
        _it(1, emb: [1, 0]),
        _it(2, emb: [0.9, 0.1]),
        _it(3, emb: [0, 1]),
        _it(4, emb: [0.1, 0.9]),
      ];
      final clusters = clusterByEmbedding(items);
      expect(clusters, hasLength(2));
      final flat = clusters.expand((c) => c).toSet();
      expect(flat, {1, 2, 3, 4});
    });

    test('類似ベクトルは同一クラスタにまとまる', () {
      final items = [
        _it(1, emb: [1, 0.1]),
        _it(2, emb: [1, 0.2]),
        _it(3, emb: [1, 0.3]),
      ];
      final clusters = clusterByEmbedding(items);
      expect(clusters, hasLength(1));
      expect(clusters.first, [1, 2, 3]);
    });

    test('embedding なしアイテムはクラスタに入れない', () {
      final items = [
        _it(1, emb: [1, 0]),
        _it(2),
      ];
      final clusters = clusterByEmbedding(items);
      expect(clusters.expand((c) => c), [1]);
    });

    test('閾値を超えるかぎりクラスタに割り込まない', () {
      final items = [
        _it(1, emb: [1, 0]),
        _it(2, emb: [0.3, 0.95]), // 1 との cosine ≒ 0.29
      ];
      final clusters = clusterByEmbedding(items);
      expect(clusters, hasLength(2));
    });
  });

  group('mergeSmall', () {
    test('minSize 未満のグループを末尾に統合', () {
      final out = mergeSmall([
        [1, 2],
        [3],
      ]);
      expect(out, hasLength(2));
      expect(out.first, [1, 2]);
      expect(out.last, [3]);
    });

    test('すべて大きい場合はそのまま', () {
      final out = mergeSmall([
        [1, 2],
        [3, 4],
      ]);
      expect(out, hasLength(2));
    });

    test('空は空', () {
      expect(mergeSmall(const []), isEmpty);
    });
  });

  group('useSemanticMode', () {
    test('埋め込み3件以上かつカバレッジ60%以上で採用', () {
      expect(useSemanticMode(10, 10), isTrue);
      expect(useSemanticMode(10, 6), isTrue);
      expect(useSemanticMode(10, 5), isFalse);
    });

    test('埋め込み3件未満では不採用', () {
      expect(useSemanticMode(3, 3), isTrue);
      expect(useSemanticMode(5, 2), isFalse);
      expect(useSemanticMode(10, 2), isFalse);
    });

    test('全件0件では不採用', () {
      expect(useSemanticMode(0, 0), isFalse);
    });
  });

  group('OrganizeSession', () {
    test('adopt のみ → そのグループだけのプラン', () {
      final s = OrganizeSession([
        _g('a', [1, 2]),
        _g('b', [3, 4]),
      ]);
      s.adopt('a', 'フォルダA');
      final plan = s.buildPlan();
      expect(plan, hasLength(1));
      expect(plan.first.folderName, 'フォルダA');
      expect(plan.first.workIds, [1, 2]);
    });

    test('skip したグループはプランに含めない（自動移動しない）', () {
      final s = OrganizeSession([
        _g('a', [1, 2]),
        _g('b', [3, 4]),
      ]);
      s.adopt('a', 'A');
      s.adopt('b', 'B');
      s.skip('b');
      final plan = s.buildPlan();
      expect(plan, hasLength(1));
      expect(plan.first.folderName, 'A');
    });

    test('skip 後に adopt すれば採用が優先', () {
      final s = OrganizeSession([
        _g('a', [1, 2]),
      ]);
      s.adopt('a', 'A');
      s.skip('a');
      s.adopt('a', 'A2');
      final plan = s.buildPlan();
      expect(plan, hasLength(1));
      expect(plan.first.folderName, 'A2');
    });

    test('操作なし（dry-run）ならプランは空', () {
      final s = OrganizeSession([
        _g('a', [1, 2]),
        _g('b', [3]),
      ]);
      expect(s.buildPlan(), isEmpty);
    });
  });
}
