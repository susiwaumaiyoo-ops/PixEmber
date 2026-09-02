// 検索リビルド修正後のユニットテスト。
//
// 検証内容:
// 1. PixivApiService.normalizeSearchWord:
//    - 半角スペース区切り（「猫 イラスト」）はそのまま維持
//    - 全角スペース区切り（「猫　イラスト」）→ 半角スペースへ正規化
//    - 連続空白・改行・タブ → 単一半角スペースへ圧縮
//    - 前後の空白は除去
// 2. PixivApiService.buildSearchParams:
//    - スペース区切りクエリが word パラメータとして正しく組み込まれる
//    - merge_results=true が送信される（削除前 pixiv_api_search.dart と同等）
//    - 全角スペースを含む入力でも正規化済み word になる
// 3. PixivApiService.mergeById:
//    - タグ検索結果と本文検索結果の ID 統合・重複除去
//    - 片方が空でも成功側の結果を維持（並行検索の縮退運転）
//    - 順序の維持（primary → secondary の追加順）
// 4. AllTextSearchState:
//    - hasNext / hasError / primaryNextOffset の状態判定
//    - text 検索が終了済みでも tag 検索が続けば primaryNextOffset が非 null
//    - エラー記録（片方失敗）とエラーなし（両成功）の区別

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/illust_model.dart' show Author;
import 'package:pixiv_viewer/novel_model.dart';
import 'package:pixiv_viewer/services/pixiv_api_service.dart';

Novel _novel(int id) => Novel(
  id: id,
  title: 'n$id',
  caption: '',
  author: Author(id: 0, name: '名無しユーザー', account: ''),
  tags: const [],
  coverUrl: '',
  textCount: 100,
  wordCount: 100,
  textLength: 100,
  pageCount: 1,
  createDate: '2026-01-01T00:00:00+00:00',
  totalView: 0,
  totalBookmarks: 0,
  isBookmarked: false,
);

/// x_restrict を指定した小説を作成する（年齢制限フィルタのテスト用）。
Novel _novelWithX(int id, int xRestrict) => Novel(
  id: id,
  title: 'n$id',
  caption: '',
  author: Author(id: 0, name: '名無しユーザー', account: ''),
  tags: const [],
  coverUrl: '',
  textCount: 100,
  wordCount: 100,
  textLength: 100,
  pageCount: 1,
  createDate: '2026-01-01T00:00:00+00:00',
  totalView: 0,
  totalBookmarks: 0,
  isBookmarked: false,
  xRestrict: xRestrict,
);

void main() {
  group('normalizeSearchWord（スペース区切りクエリの正規化）', () {
    test('半角スペース1つはそのまま維持される', () {
      expect(PixivApiService.normalizeSearchWord('猫 イラスト'), '猫 イラスト');
    });

    test('全角スペースは半角スペースに置換される', () {
      expect(PixivApiService.normalizeSearchWord('猫\u3000イラスト'), '猫 イラスト');
    });

    test('連続する空白は単一の半角スペースに圧縮される', () {
      expect(
        PixivApiService.normalizeSearchWord('猫 \u3000  \n\t イラスト'),
        '猫 イラスト',
      );
    });

    test('前後の空白は除去される', () {
      expect(PixivApiService.normalizeSearchWord('  猫 イラスト \u3000'), '猫 イラスト');
    });

    test('空文字列・空白のみは空文字列になる', () {
      expect(PixivApiService.normalizeSearchWord(''), '');
      expect(PixivApiService.normalizeSearchWord('  \u3000 '), '');
    });
  });

  group('buildSearchParams（スペース区切り検索のパラメータ構築）', () {
    test('スペース区切りクエリが word にそのまま含まれる', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫 イラスト',
        searchTarget: 'partial_match_for_tags',
        isNovel: true,
        sort: 'date_desc',
        offset: 0,
      );
      expect(params['word'], '猫 イラスト');
    });

    test('全角スペースを含むクエリは正規化して word に入る', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫\u3000イラスト',
        searchTarget: 'text',
        isNovel: true,
        sort: 'date_desc',
        offset: 0,
      );
      expect(params['word'], '猫 イラスト');
    });

    test('merge_results=true が送信される（削除前実装と同等）', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'partial_match_for_tags',
        isNovel: true,
        sort: 'date_desc',
        offset: 0,
      );
      expect(params['merge_results'], 'true');
    });

    test('all_text は無効ターゲットなので partial_match_for_tags に丸められる', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫',
        searchTarget: 'all_text',
        isNovel: true,
        sort: 'date_desc',
        offset: 0,
      );
      expect(params['search_target'], 'partial_match_for_tags');
    });
  });

  group('mergeById（並行検索結果のマージ）', () {
    test('タグ検索と本文検索の結果を ID で統合し重複を除去する', () {
      final tagItems = [_novel(1), _novel(2)];
      final textItems = [_novel(2), _novel(3)];
      final merged = PixivApiService.mergeById<Novel>(
        tagItems,
        textItems,
        (n) => n.id,
      );
      expect(merged.map((n) => n.id), [1, 2, 3]);
    });

    test('片方が空でも成功側の結果を維持する（縮退運転）', () {
      final tagItems = [_novel(1), _novel(2)];
      final merged = PixivApiService.mergeById<Novel>(
        tagItems,
        const [],
        (n) => n.id,
      );
      expect(merged.length, 2);
      expect(merged.map((n) => n.id), [1, 2]);
    });

    test('両方空なら空リストを返す', () {
      final merged = PixivApiService.mergeById<Novel>(
        const [],
        const [],
        (n) => n.id,
      );
      expect(merged, isEmpty);
    });

    test('順序は primary → secondary の追加順を維持する', () {
      final tagItems = [_novel(10), _novel(20)];
      final textItems = [_novel(30), _novel(10)];
      final merged = PixivApiService.mergeById<Novel>(
        tagItems,
        textItems,
        (n) => n.id,
      );
      expect(merged.map((n) => n.id), [10, 20, 30]);
    });
  });

  group('AllTextSearchState（全文検索の状態管理）', () {
    test('初回状態は hasNext=false, hasError=false', () {
      const state = AllTextSearchState.empty;
      expect(state.hasNext, isFalse);
      expect(state.hasError, isFalse);
      expect(state.primaryNextOffset, isNull);
    });

    test('両検索に次ページがある場合は hasNext=true', () {
      const state = AllTextSearchState(tagNextOffset: 30, textNextOffset: 60);
      expect(state.hasNext, isTrue);
      // タグ側を優先する
      expect(state.primaryNextOffset, 30);
    });

    test('text 検索が終了済みでも tag 検索が続けば primaryNextOffset は非 null', () {
      const state = AllTextSearchState(tagNextOffset: 30, textNextOffset: null);
      expect(state.hasNext, isTrue);
      expect(state.primaryNextOffset, 30);
    });

    test('tag 検索が終了済みでも text 検索が続けば primaryNextOffset は非 null', () {
      const state = AllTextSearchState(tagNextOffset: null, textNextOffset: 60);
      expect(state.hasNext, isTrue);
      expect(state.primaryNextOffset, 60);
    });

    test('両検索とも終了したら primaryNextOffset は null（無限スクロール停止）', () {
      const state = AllTextSearchState(
        tagNextOffset: null,
        textNextOffset: null,
      );
      expect(state.hasNext, isFalse);
      expect(state.primaryNextOffset, isNull);
    });

    test('片方の検索が失敗した場合 hasError=true でエラー詳細が記録される', () {
      const state = AllTextSearchState(
        textError: 'Pixiv APIのレート制限（429）に達しました。',
      );
      expect(state.hasError, isTrue);
      expect(state.textError, isNotNull);
      expect(state.tagError, isNull);
    });

    test('両検索とも成功した場合は hasError=false', () {
      const state = AllTextSearchState(tagNextOffset: 30, textNextOffset: 60);
      expect(state.hasError, isFalse);
    });
  });

  group('FetchResult.nextOffset（全文検索のページング抽出）', () {
    test('next_url から offset を抽出する', () {
      const result = FetchResult<Novel>(
        items: [],
        nextUrl:
            'https://app-api.pixiv.net/v1/search/novel'
            '?word=%E7%8C%AB&offset=30',
      );
      expect(result.nextOffset, 30);
      expect(result.hasNext, isTrue);
    });

    test('next_url が空なら hasNext=false', () {
      const result = FetchResult<Novel>(items: [], nextUrl: null);
      expect(result.hasNext, isFalse);
      expect(result.nextOffset, isNull);
    });

    test('AllTextSearchResult.hasNext は result と state の OR 合成', () {
      // result 側は終了（next_url なし）だが state 側のタグ検索が継続中
      const result = AllTextSearchResult<Novel>(
        result: FetchResult<Novel>(items: [], nextUrl: null),
        state: AllTextSearchState(tagNextOffset: 30),
      );
      expect(result.hasNext, isTrue);
    });
  });

  group('containsR18Token（R-18 トークン検出）', () {
    test('R-18 / R18 / R-18G トークンを検出する', () {
      expect(PixivApiService.containsR18Token('恋愛 R-18'), isTrue);
      expect(PixivApiService.containsR18Token('R18 猫'), isTrue);
      expect(PixivApiService.containsR18Token('猫 r-18g'), isTrue);
      expect(PixivApiService.containsR18Token('R-18'), isTrue);
    });

    test('単語の一部としての R-18 は誤検出しない', () {
      // タグ名や本文の一部に「R-18」が含まれるケースはトークンではない
      expect(PixivApiService.containsR18Token('R-18作品まとめ'), isFalse);
      expect(PixivApiService.containsR18Token('r18gの使い方'), isFalse);
      expect(PixivApiService.containsR18Token('猫 イラスト'), isFalse);
    });
  });

  group('buildSearchWord（年齢制限と検索ワードの分離）', () {
    test('タグ検索 + r18 は R-18 を補助付与する', () {
      expect(
        PixivApiService.buildSearchWord(
          rawQuery: '恋愛',
          ageLimit: 'r18',
          searchTarget: 'partial_match_for_tags',
        ),
        '恋愛 R-18',
      );
      expect(
        PixivApiService.buildSearchWord(
          rawQuery: '恋愛',
          ageLimit: 'r18',
          searchTarget: 'exact_match_for_tags',
        ),
        '恋愛 R-18',
      );
    });

    test('全文検索（text / title_and_caption / keyword）では付与しない', () {
      for (final target in ['text', 'title_and_caption', 'keyword']) {
        expect(
          PixivApiService.buildSearchWord(
            rawQuery: '恋愛',
            ageLimit: 'r18',
            searchTarget: target,
          ),
          '恋愛',
          reason: 'searchTarget=$target では R-18 を付与しない',
        );
      }
    });

    test('クエリに既に R-18 が含まれる場合は二重付与しない', () {
      expect(
        PixivApiService.buildSearchWord(
          rawQuery: '恋愛 R-18',
          ageLimit: 'r18',
          searchTarget: 'partial_match_for_tags',
        ),
        '恋愛 R-18',
      );
    });

    test('スペース区切りクエリ + r18 は正規化してから R-18 を付与する', () {
      expect(
        PixivApiService.buildSearchWord(
          rawQuery: '猫\u3000イラスト',
          ageLimit: 'r18',
          searchTarget: 'partial_match_for_tags',
        ),
        '猫 イラスト R-18',
      );
    });

    test('all / include_r18 / r18g / 空 では R-18 を付与しない', () {
      for (final ageLimit in ['all', 'include_r18', 'r18g', '']) {
        expect(
          PixivApiService.buildSearchWord(
            rawQuery: '恋愛',
            ageLimit: ageLimit,
            searchTarget: 'partial_match_for_tags',
          ),
          '恋愛',
          reason: 'ageLimit=$ageLimit では R-18 を付与しない',
        );
      }
    });
  });

  group('applyAgeLimitFilter（x_restrict による絞り込み）', () {
    test('all / all_ages / safe は x_restrict==0 のみ残す', () {
      final items = [0, 1, 2, 0];
      expect(PixivApiService.applyAgeLimitFilter(items, 'all', (x) => x), [
        0,
        0,
      ]);
      expect(PixivApiService.applyAgeLimitFilter(items, 'all_ages', (x) => x), [
        0,
        0,
      ]);
      expect(PixivApiService.applyAgeLimitFilter(items, 'safe', (x) => x), [
        0,
        0,
      ]);
    });

    test('r18 は x_restrict==1 のみ残す', () {
      final items = [0, 1, 2, 1];
      expect(PixivApiService.applyAgeLimitFilter(items, 'r18', (x) => x), [
        1,
        1,
      ]);
    });

    test('r18g は x_restrict==2 のみ残す', () {
      final items = [0, 1, 2, 2];
      expect(PixivApiService.applyAgeLimitFilter(items, 'r18g', (x) => x), [
        2,
        2,
      ]);
    });

    test('include_r18 と未知の値は絞り込まない', () {
      final items = [0, 1, 2];
      expect(
        PixivApiService.applyAgeLimitFilter(items, 'include_r18', (x) => x),
        [0, 1, 2],
      );
      expect(PixivApiService.applyAgeLimitFilter(items, 'unknown', (x) => x), [
        0,
        1,
        2,
      ]);
    });

    test('Novel リストを x_restrict で絞り込める', () {
      final novels = [_novelWithX(1, 0), _novelWithX(2, 1), _novelWithX(3, 2)];
      expect(
        PixivApiService.applyAgeLimitFilter(
          novels,
          'all',
          (n) => n.xRestrict,
        ).map((n) => n.id),
        [1],
      );
      expect(
        PixivApiService.applyAgeLimitFilter(
          novels,
          'r18',
          (n) => n.xRestrict,
        ).map((n) => n.id),
        [2],
      );
      expect(
        PixivApiService.applyAgeLimitFilter(
          novels,
          'r18g',
          (n) => n.xRestrict,
        ).map((n) => n.id),
        [3],
      );
      expect(
        PixivApiService.applyAgeLimitFilter(
          novels,
          'include_r18',
          (n) => n.xRestrict,
        ).map((n) => n.id),
        [1, 2, 3],
      );
    });
  });

  group('buildSearchParams（年齢制限のワード分離）', () {
    test('小説全文検索 + r18 では word に R-18 を含まない', () {
      final params = PixivApiService.buildSearchParams(
        word: '恋愛',
        searchTarget: 'text',
        isNovel: true,
        sort: 'date_desc',
        offset: 0,
        xRestrict: 'r18',
      );
      expect(params['word'], '恋愛');
    });

    test('小説タグ検索 + r18 では word に R-18 を補助付与する', () {
      final params = PixivApiService.buildSearchParams(
        word: '恋愛',
        searchTarget: 'partial_match_for_tags',
        isNovel: true,
        sort: 'date_desc',
        offset: 0,
        xRestrict: 'r18',
      );
      expect(params['word'], '恋愛 R-18');
    });

    test('タイトル・キャプション検索 + r18 では R-18 を付与しない', () {
      final params = PixivApiService.buildSearchParams(
        word: '恋愛',
        searchTarget: 'title_and_caption',
        isNovel: true,
        sort: 'date_desc',
        offset: 0,
        xRestrict: 'r18',
      );
      expect(params['word'], '恋愛');
    });

    test('スペース区切り + r18 は正規化し、タグ検索のみ R-18 を付与', () {
      final tagParams = PixivApiService.buildSearchParams(
        word: '猫\u3000イラスト',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        xRestrict: 'r18',
      );
      expect(tagParams['word'], '猫 イラスト R-18');

      final textParams = PixivApiService.buildSearchParams(
        word: '猫\u3000イラスト',
        searchTarget: 'text',
        isNovel: true,
        sort: 'date_desc',
        offset: 0,
        xRestrict: 'r18',
      );
      expect(textParams['word'], '猫 イラスト');
    });

    test('全年齢（all）ではワードを変更しない', () {
      final params = PixivApiService.buildSearchParams(
        word: '猫 イラスト',
        searchTarget: 'partial_match_for_tags',
        isNovel: false,
        sort: 'date_desc',
        offset: 0,
        xRestrict: 'all',
      );
      expect(params['word'], '猫 イラスト');
    });
  });
}
