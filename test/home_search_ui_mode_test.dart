import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/utils/home_search_ui_mode.dart';

/// Phase 3 検索UI刷新: ホームタブ内検索の状態遷移テスト。
///
/// 遷移図（仕様）:
///   browsing  -> assisting : 検索バー focus
///   assisting -> results   : submit / 履歴タップ / トレンドタップ
///   results   -> assisting : 検索バー再フォーカス
///   assisting -> browsing  : 文字空 + unfocus + 未検索
///   results   -> browsing  : ソースチップ選択 / clear で検索解除
void main() {
  group('HomeSearchUiModeTransitions.onFocus', () {
    test('どの状態からでも assisting になる', () {
      expect(
        HomeSearchUiModeTransitions.onFocus(HomeSearchUiMode.browsing),
        HomeSearchUiMode.assisting,
      );
      expect(
        HomeSearchUiModeTransitions.onFocus(HomeSearchUiMode.assisting),
        HomeSearchUiMode.assisting,
      );
      expect(
        HomeSearchUiModeTransitions.onFocus(HomeSearchUiMode.results),
        HomeSearchUiMode.assisting,
      );
    });
  });

  group('HomeSearchUiModeTransitions.onSubmit', () {
    test('どの状態からでも results になる（空文字抑止は呼び出し側責務）', () {
      for (final mode in HomeSearchUiMode.values) {
        expect(
          HomeSearchUiModeTransitions.onSubmit(mode),
          HomeSearchUiMode.results,
        );
      }
    });
  });

  group('HomeSearchUiModeTransitions.onUnfocus', () {
    test('assisting + 空欄 + 未検索 -> browsing（元コンテンツへ戻る）', () {
      expect(
        HomeSearchUiModeTransitions.onUnfocus(
          HomeSearchUiMode.assisting,
          hasPendingText: false,
          hasSearchResult: false,
        ),
        HomeSearchUiMode.browsing,
      );
    });

    test('assisting + 検索済み -> 結果表示へ戻る（テキスト有無に依らない）', () {
      expect(
        HomeSearchUiModeTransitions.onUnfocus(
          HomeSearchUiMode.assisting,
          hasPendingText: true,
          hasSearchResult: true,
        ),
        HomeSearchUiMode.results,
      );
      expect(
        HomeSearchUiModeTransitions.onUnfocus(
          HomeSearchUiMode.assisting,
          hasPendingText: false,
          hasSearchResult: true,
        ),
        HomeSearchUiMode.results,
      );
    });

    test('assisting + テキストあり + 未検索 -> browsing（結果が無いので残留不可）', () {
      expect(
        HomeSearchUiModeTransitions.onUnfocus(
          HomeSearchUiMode.assisting,
          hasPendingText: true,
          hasSearchResult: false,
        ),
        HomeSearchUiMode.browsing,
      );
    });

    test('assisting 以外では状態を変えない', () {
      expect(
        HomeSearchUiModeTransitions.onUnfocus(
          HomeSearchUiMode.browsing,
          hasPendingText: true,
          hasSearchResult: true,
        ),
        HomeSearchUiMode.browsing,
      );
      expect(
        HomeSearchUiModeTransitions.onUnfocus(
          HomeSearchUiMode.results,
          hasPendingText: false,
          hasSearchResult: true,
        ),
        HomeSearchUiMode.results,
      );
    });
  });

  group('HomeSearchUiModeTransitions.onClear', () {
    test('results -> browsing（クリアで現在ソースの閲覧へ戻る）', () {
      expect(
        HomeSearchUiModeTransitions.onClear(HomeSearchUiMode.results),
        HomeSearchUiMode.browsing,
      );
    });

    test('assisting -> assisting（フォーカス中は補助画面を維持）', () {
      expect(
        HomeSearchUiModeTransitions.onClear(HomeSearchUiMode.assisting),
        HomeSearchUiMode.assisting,
      );
    });

    test('browsing -> browsing', () {
      expect(
        HomeSearchUiModeTransitions.onClear(HomeSearchUiMode.browsing),
        HomeSearchUiMode.browsing,
      );
    });
  });

  group('HomeSearchUiModeTransitions.onSourceSelected', () {
    test('どの状態からでも browsing（キーワード結果は破棄）', () {
      for (final mode in HomeSearchUiMode.values) {
        expect(
          HomeSearchUiModeTransitions.onSourceSelected(mode),
          HomeSearchUiMode.browsing,
        );
      }
    });
  });

  group('HomeContentSourceLabel', () {
    test('ソースチップの表示ラベルが固定日本語である', () {
      expect(HomeContentSource.recommend.label, 'おすすめ');
      expect(HomeContentSource.latest.label, '新着');
      expect(HomeContentSource.following.label, 'フォロー');
      expect(HomeContentSource.bookmarks.label, 'ブックマーク');
    });

    test('チップは4ソースのみ（ランキングはチップ外で別導線）', () {
      expect(HomeContentSource.values.length, 4);
    });
  });

  group('HomeSearchUiModeTransitions.onFocusIfManual (B3)', () {
    test('明示的タップ時はどの状態からでも assisting になる', () {
      expect(
        HomeSearchUiModeTransitions.onFocusIfManual(
          HomeSearchUiMode.results,
          manualTap: true,
        ),
        HomeSearchUiMode.assisting,
      );
      expect(
        HomeSearchUiModeTransitions.onFocusIfManual(
          HomeSearchUiMode.browsing,
          manualTap: true,
        ),
        HomeSearchUiMode.assisting,
      );
    });

    test('プログラム的フォーカス(manualTap=false)では状態を維持', () {
      // B3: 詳細から pop した際、results のまま結果一覧を表示する。
      expect(
        HomeSearchUiModeTransitions.onFocusIfManual(
          HomeSearchUiMode.results,
          manualTap: false,
        ),
        HomeSearchUiMode.results,
      );
      expect(
        HomeSearchUiModeTransitions.onFocusIfManual(
          HomeSearchUiMode.browsing,
          manualTap: false,
        ),
        HomeSearchUiMode.browsing,
      );
    });
  });
}
