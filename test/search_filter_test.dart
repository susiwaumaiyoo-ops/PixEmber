// 検索リビルド Phase 2 のユニットテスト。
//
// 検証内容:
// 1. SearchFilter モデル: toJson / fromJson / copyWith / null 値の扱い
// 2. SearchFilter の静的ヘルパー: duration 変換 / 日付 → Unix 秒
// 3. PixivApiService.buildSearchParams:
//    - 新パラメータ null で呼んだ場合、既存パラメータのみ（既存動作維持）
//    - duration='within_last_week' → URL パラメータに 'duration' が含まれる
//    - bookmarkNumMin=1000 → URL パラメータに 'bookmark_num_min' が含まれる
//    - 日付範囲指定時は duration より優先して start_date/end_date を送信

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/models/search_filter.dart';
import 'package:pixiv_viewer/services/pixiv_api_service.dart';

void main() {
  group('SearchFilter モデル', () {
    test('デフォルト値', () {
      const f = SearchFilter();
      expect(f.searchTarget, 'partial_match_for_tags');
      expect(f.sort, 'date_desc');
      expect(f.ageLimit, 'all');
      expect(f.workType, 'all');
      expect(f.aiFilter, 'all');
      expect(f.bookmarkFilter, 0);
      expect(f.duration, isNull);
      expect(f.startDate, isNull);
      expect(f.endDate, isNull);
      expect(f.bookmarkNumMin, isNull);
      expect(f.bookmarkNumMax, isNull);
    });

    test('copyWith で一部フィールドのみ上書きできる', () {
      const base = SearchFilter(sort: 'date_asc');
      final updated = base.copyWith(sort: 'popular_desc', bookmarkNumMin: 100);
      expect(updated.sort, 'popular_desc');
      expect(updated.bookmarkNumMin, 100);
      // 未指定フィールドは保持される
      expect(updated.searchTarget, 'partial_match_for_tags');
      expect(updated.bookmarkNumMax, isNull);
      expect(updated, isNot(base));
    });

    test('copyWith で null を渡しても上書きされない（null 値の扱い）', () {
      const base = SearchFilter(duration: '7d', bookmarkNumMax: 5000);
      final updated = base.copyWith(duration: null, bookmarkNumMax: null);
      expect(updated.duration, '7d');
      expect(updated.bookmarkNumMax, 5000);
    });

    test('toJson: null フィールドはキー自体が存在しない', () {
      const f = SearchFilter();
      final json = f.toJson();
      expect(json['searchTarget'], 'partial_match_for_tags');
      expect(json.containsKey('duration'), isFalse);
      expect(json.containsKey('startDate'), isFalse);
      expect(json.containsKey('endDate'), isFalse);
      expect(json.containsKey('bookmarkNumMin'), isFalse);
      expect(json.containsKey('bookmarkNumMax'), isFalse);
    });

    test('toJson: 設定済みフィールドは含まれる', () {
      final f = SearchFilter(
        duration: '7d',
        startDate: DateTime(2026, 1, 5),
        endDate: DateTime(2026, 1, 20),
        bookmarkNumMin: 100,
        bookmarkNumMax: 1000,
      );
      final json = f.toJson();
      expect(json['duration'], '7d');
      expect(json['startDate'], '2026-01-05T00:00:00.000');
      expect(json['endDate'], '2026-01-20T00:00:00.000');
      expect(json['bookmarkNumMin'], 100);
      expect(json['bookmarkNumMax'], 1000);
    });

    test('fromJson: null 値でデフォルト値に丸められる', () {
      final f = SearchFilter.fromJson(const {});
      expect(f.searchTarget, 'partial_match_for_tags');
      expect(f.sort, 'date_desc');
      expect(f.duration, isNull);
      expect(f.bookmarkNumMin, isNull);
    });

    test('fromJson: 文字列日付が DateTime に変換される', () {
      final f = SearchFilter.fromJson(const {
        'startDate': '2026-01-05T00:00:00.000',
        'endDate': '2026-01-20T00:00:00.000',
        'bookmarkNumMin': 100,
      });
      expect(f.startDate, DateTime(2026, 1, 5));
      expect(f.endDate, DateTime(2026, 1, 20));
      expect(f.bookmarkNumMin, 100);
    });

    test('toJson → fromJson で等価（ラウンドトリップ）', () {
      final original = SearchFilter(
        searchTarget: 'exact_match_for_tags',
        sort: 'popular_desc',
        ageLimit: 'include_r18',
        workType: 'manga',
        aiFilter: 'hide',
        bookmarkFilter: 100,
        duration: '30d',
        startDate: DateTime(2026, 2, 1),
        endDate: DateTime(2026, 2, 28),
        bookmarkNumMin: 1000,
        bookmarkNumMax: 5000,
      );
      final restored = SearchFilter.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.hashCode, original.hashCode);
    });

    test('== はフィールド全てで比較される', () {
      const a = SearchFilter(sort: 'date_asc');
      const b = SearchFilter(sort: 'date_asc');
      const c = SearchFilter(sort: 'date_desc');
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('SearchFilter 静的ヘルパー', () {
    test('durationToApiValue: 従来値 → API 値', () {
      expect(SearchFilter.durationToApiValue(null), isNull);
      expect(SearchFilter.durationToApiValue(''), isNull);
      expect(SearchFilter.durationToApiValue('all'), isNull);
      expect(SearchFilter.durationToApiValue('1d'), 'within_last_day');
      expect(SearchFilter.durationToApiValue('7d'), 'within_last_week');
      expect(SearchFilter.durationToApiValue('30d'), 'within_last_month');
      expect(SearchFilter.durationToApiValue('180d'), 'within_last_halfyear');
      expect(SearchFilter.durationToApiValue('365d'), 'within_last_year');
      // 不明値はそのまま（UI 側が有効値のみ選択させる前提）
      expect(
        SearchFilter.durationToApiValue('within_last_week'),
        'within_last_week',
      );
    });

    test('hasDateRange', () {
      expect(SearchFilter.hasDateRange(null, null), isFalse);
      expect(SearchFilter.hasDateRange(DateTime(2026, 1, 1), null), isTrue);
      expect(SearchFilter.hasDateRange(null, DateTime(2026, 1, 1)), isTrue);
      expect(
        SearchFilter.hasDateRange(DateTime(2026, 1, 1), DateTime(2026, 1, 2)),
        isTrue,
      );
    });

    test('日付 → Unix 秒（開始=当日00:00 / 終了=当日23:59:59）', () {
      final d = DateTime(2026, 1, 5, 13, 45); // 時刻は無視される
      expect(
        SearchFilter.startDateTimeToUnixSeconds(d),
        DateTime(2026, 1, 5).millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        SearchFilter.endDateTimeToUnixSeconds(d),
        DateTime(2026, 1, 5, 23, 59, 59).millisecondsSinceEpoch ~/ 1000,
      );
      expect(SearchFilter.startDateTimeToUnixSeconds(null), isNull);
      expect(SearchFilter.endDateTimeToUnixSeconds(null), isNull);
    });
  });

  group('PixivApiService.buildSearchParams', () {
    test('新パラメータ null: 既存動作維持（新キーなし）', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
      );
      expect(params['word'], '猫');
      expect(params['search_target'], 'partial_match_for_tags');
      expect(params['sort'], 'date_desc');
      expect(params['offset'], '0');
      expect(params['filter'], 'for_android');
      expect(params.containsKey('duration'), isFalse);
      expect(params.containsKey('start_date'), isFalse);
      expect(params.containsKey('end_date'), isFalse);
      expect(params.containsKey('bookmark_num_min'), isFalse);
      expect(params.containsKey('bookmark_num_max'), isFalse);
      expect(params.containsKey('start_text_length'), isFalse);
      expect(params.containsKey('end_text_length'), isFalse);
    });

    test("duration='within_last_week' → URL パラメータに含まれる", () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        duration: 'within_last_week',
      );
      expect(params['duration'], 'within_last_week');
      expect(params.containsKey('start_date'), isFalse);
      expect(params.containsKey('end_date'), isFalse);
    });

    test("duration='7d'（従来値）も API 値に変換されて含まれる", () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        duration: '7d',
      );
      expect(params['duration'], 'within_last_week');
    });

    test("duration='all' / null → 送信されない", () {
      for (final d in [null, 'all']) {
        final params = PixivApiService.buildSearchParams(
          word: '猫',
          searchTarget: 'partial_match_for_tags',
          isNovel: false,
          sort: 'date_desc',
          offset: 0,
          duration: d,
        );
        expect(params.containsKey('duration'), isFalse, reason: 'd=$d');
      }
    });

    test('bookmarkNumMin=1000 → URL パラメータに含まれる', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        bookmarkNumMin: 1000,
        bookmarkNumMax: 5000,
      );
      expect(params['bookmark_num_min'], '1000');
      expect(params['bookmark_num_max'], '5000');
    });

    test('bookmarkNumMin/Max が 0 以下の場合は送信されない', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        bookmarkNumMin: 0,
        bookmarkNumMax: -1,
      );
      expect(params.containsKey('bookmark_num_min'), isFalse);
      expect(params.containsKey('bookmark_num_max'), isFalse);
    });

    test('日付範囲指定: start_date / end_date が Unix 秒で含まれる', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        startDate: DateTime(2026, 1, 5),
        endDate: DateTime(2026, 1, 20),
      );
      expect(
        params['start_date'],
        (DateTime(2026, 1, 5).millisecondsSinceEpoch ~/ 1000).toString(),
      );
      expect(
        params['end_date'],
        (DateTime(2026, 1, 20, 23, 59, 59).millisecondsSinceEpoch ~/ 1000)
            .toString(),
      );
    });

    test('日付範囲 + duration 同時指定: 日付範囲が優先し duration は含まれない', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        duration: '7d',
        startDate: DateTime(2026, 1, 5),
      );
      expect(params.containsKey('start_date'), isTrue);
      expect(params.containsKey('duration'), isFalse);
      expect(params.containsKey('end_date'), isFalse);
    });

    test('従来の bookmarkFilter はワード接尾方式を維持（新パラメータと両立）', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        bookmarkFilter: 1000,
        bookmarkNumMin: 100,
      );
      // 既存動作: 「Nusers入り」ワード接尾
      expect(params['word'], '猫 1000users入り');
      // 新動作: 数値範囲パラメータ
      expect(params['bookmark_num_min'], '100');
      expect(params.containsKey('bookmark_num_max'), isFalse);
    });

    test('xRestrict=r18 の場合は R-18 がワードに付与される（既存動作維持）', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        xRestrict: 'r18',
      );
      expect(params['word'], '猫 R-18');
    });

    test('小説: 文字数制限（start_text_length / end_text_length）は維持', () {
      final params = PixivApiService.buildSearchParams(
        word: '冒険',
        searchTarget: 'text',
        isNovel: true,
        sort: 'popular_desc',
        offset: 30,
        startTextLength: 1000,
        endTextLength: 90000,
      );
      expect(params['start_text_length'], '1000');
      expect(params['end_text_length'], '90000');
      expect(params['search_target'], 'text');
      expect(params['offset'], '30');
    });

    test('search_target 正規化: 無効値は既定値へ丸められる（既存動作維持）', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'invalid_target',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
      );
      expect(params['search_target'], 'partial_match_for_tags');
    });
  });
}
