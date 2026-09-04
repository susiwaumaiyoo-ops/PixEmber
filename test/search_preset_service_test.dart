// 検索プリセットサービス（非AI機能パック Phase N1）のユニットテスト。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pixiv_viewer/services/search_preset_service.dart';

void main() {
  final svc = SearchPresetService();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('decodePresets', () {
    test('null / 空 → 空リスト', () {
      expect(decodePresets(null), isEmpty);
      expect(decodePresets(''), isEmpty);
      expect(decodePresets('   '), isEmpty);
    });

    test('不正 JSON / 旧形式 → 空リスト（旧データ互換）', () {
      expect(decodePresets('{not json'), isEmpty);
      expect(decodePresets('{"a":1}'), isEmpty);
    });

    test('欠落フィールド → 既定値', () {
      final list = decodePresets(
        jsonEncode([
          {'id': 'p1', 'name': 'test'},
        ]),
      );
      expect(list, hasLength(1));
      expect(list.first.category, 'illust');
      expect(list.first.keywordMode, 'and');
      expect(list.first.filterJson, isEmpty);
      expect(list.first.lastUsedAt, isNull);
    });

    test('id がないエントリはスキップ', () {
      expect(
        decodePresets(
          jsonEncode([
            {'name': 'no id'},
          ]),
        ),
        isEmpty,
      );
    });
  });

  group('filter_json ラウンドトリップ', () {
    test('ネストマップが encode/decode を Survive する', () {
      final filterJson = <String, dynamic>{
        'illust': {
          'searchTarget': 'exact_match_for_tags',
          'ageLimit': 'r18',
          'bookmarkFilter': 1000,
          'minBookmarkText': '1000',
        },
        'novel': {
          'excludeTags': ['tag1', 'tag2'],
          'seriesOnly': true,
          'minText': '',
        },
        'common': {
          'startDate': DateTime(2026, 1, 2).toIso8601String(),
          'useEndDate': true,
          'endDate': null,
        },
      };
      final preset = SearchPreset(
        id: 'p1',
        name: 'n',
        category: 'novel',
        keyword: 'k',
        filterJson: filterJson,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      final decoded = decodePresets(encodePresets([preset])).single;
      expect(decoded.filterJson, filterJson);
      expect(decoded.filterJson['novel']['excludeTags'], ['tag1', 'tag2']);
      expect(
        decoded.filterJson['common']['startDate'],
        '2026-01-02T00:00:00.000',
      );
      expect(decoded.keyword, 'k');
      expect(decoded.category, 'novel');
      expect(decoded.name, 'n');
    });
  });

  group('normalizePresets', () {
    test('同名 + 同カテゴリ + 同キーワードは重複排除（最新を保持）', () {
      final a = _preset('p1', name: 'A', updated: DateTime(2026, 1, 1));
      final b = _preset('p2', name: 'A', updated: DateTime(2026, 1, 2));
      final result = normalizePresets([a, b]);
      expect(result, hasLength(1));
      expect(result.single.id, 'p2');
    });

    test('カテゴリ違いは重複排除しない', () {
      final a = _preset('p1', name: 'A', category: 'illust');
      final b = _preset('p2', name: 'A', category: 'novel');
      expect(normalizePresets([a, b]), hasLength(2));
    });

    test('上限を超えると古い順に削除', () {
      final list = [
        for (var i = 0; i < 35; i++)
          _preset(
            'p$i',
            name: 'P$i',
            keyword: 'k$i',
            updated: DateTime(2026, 1, 1).add(Duration(days: i)),
          ),
      ];
      final result = normalizePresets(list, maxItems: 30);
      expect(result, hasLength(30));
      expect(result.map((p) => p.id), contains('p34'));
      expect(result.map((p) => p.id), isNot(contains('p0')));
    });
  });

  group('sortPresetsByUse', () {
    test('lastUsedAt を優先して新しい順', () {
      final a = _preset('a', updated: DateTime(2026, 1, 10));
      final b = _preset(
        'b',
        updated: DateTime(2026, 1, 1),
        lastUsed: DateTime(2026, 1, 5),
      );
      final c = _preset('c', updated: DateTime(2026, 1, 8));
      final sorted = sortPresetsByUse([a, b, c]);
      expect(sorted.map((p) => p.id).toList(), ['a', 'c', 'b']);
    });
  });

  group('SearchPresetService', () {
    test('save → load ラウンドトリップ', () async {
      await svc.save(
        name: 'マイ検索',
        category: 'novel',
        keyword: 'ねこ 食べ',
        filterJson: {
          'common': {'bmNumMin': '10'},
        },
        keywordMode: 'or',
        excludeKeyword: 'test',
        now: DateTime(2026, 2, 1),
      );
      final list = await svc.load();
      expect(list, hasLength(1));
      expect(list.first.name, 'マイ検索');
      expect(list.first.keyword, 'ねこ 食べ');
      expect(list.first.category, 'novel');
      expect(list.first.keywordMode, 'or');
      expect(list.first.excludeKeyword, 'test');
      expect(list.first.filterJson['common']['bmNumMin'], '10');
    });

    test('同名保存は更新扱い（重複しない）', () async {
      await svc.save(
        name: 'X',
        category: 'illust',
        keyword: 'k',
        filterJson: {'a': 1},
        now: DateTime(2026, 2, 1),
      );
      final p2 = await svc.save(
        name: 'X',
        category: 'illust',
        keyword: 'k',
        filterJson: {'a': 2},
        now: DateTime(2026, 2, 2),
      );
      final list = await svc.load();
      expect(list, hasLength(1));
      expect(list.first.id, p2.id);
      expect(list.first.filterJson['a'], 2);
    });

    test('rename で名前変更', () async {
      await svc.save(
        name: '旧',
        category: 'illust',
        keyword: 'k',
        filterJson: const {},
        now: DateTime(2026, 2, 1),
      );
      final list = await svc.load();
      await svc.rename(list.single.id, '新');
      expect((await svc.load()).single.name, '新');
    });

    test('空名 rename は無視', () async {
      await svc.save(
        name: '旧',
        category: 'illust',
        keyword: 'k',
        filterJson: const {},
        now: DateTime(2026, 2, 1),
      );
      final list = await svc.load();
      await svc.rename(list.single.id, '   ');
      expect((await svc.load()).single.name, '旧');
    });

    test('delete で削除', () async {
      await svc.save(
        name: 'D',
        category: 'illust',
        keyword: 'k',
        filterJson: const {},
        now: DateTime(2026, 2, 1),
      );
      final list = await svc.load();
      await svc.delete(list.single.id);
      expect(await svc.load(), isEmpty);
    });

    test('markUsed で lastUsedAt が設定される', () async {
      await svc.save(
        name: 'M',
        category: 'illust',
        keyword: 'k',
        filterJson: const {},
        now: DateTime(2026, 2, 1),
      );
      final list = await svc.load();
      await svc.markUsed(list.single.id, now: DateTime(2026, 3, 1));
      expect((await svc.load()).single.lastUsedAt, DateTime(2026, 3, 1));
    });

    test('上限超過で最も古いものが削除される', () async {
      for (var i = 0; i < 32; i++) {
        await svc.save(
          name: 'P$i',
          category: 'illust',
          keyword: 'k$i',
          filterJson: const {},
          now: DateTime(2026, 1, 1).add(Duration(days: i)),
        );
      }
      final list = await svc.load();
      expect(list, hasLength(30));
      expect(list.map((p) => p.name), isNot(contains('P0')));
      expect(list.map((p) => p.name), isNot(contains('P1')));
      expect(list.map((p) => p.name), contains('P31'));
    });
  });
}

SearchPreset _preset(
  String id, {
  String name = 'n',
  String category = 'illust',
  String keyword = 'k',
  DateTime? updated,
  DateTime? lastUsed,
}) {
  final u = updated ?? DateTime(2026, 1, 1);
  return SearchPreset(
    id: id,
    name: name,
    category: category,
    keyword: keyword,
    filterJson: const {},
    createdAt: u,
    updatedAt: u,
    lastUsedAt: lastUsed,
  );
}
