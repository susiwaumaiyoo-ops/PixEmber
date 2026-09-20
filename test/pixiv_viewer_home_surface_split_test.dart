// Phase 16c-3c: feed / search サーフェスの表示要素分離の契約テスト。
//
// 本番の [PixivViewerHome] は build 内で DatabaseService にアクセスするため
// widget test で pump できない（`databaseFactory not initialized`）。
// そのため [PixivViewerHomeState] を直接インスタンス化し、
// `@visibleForTesting` な getter で「どのサーフェスでどの要素が出るか」
// の判定ロジックだけを検証する（16c-3a と同じ手法）。
//
// 各表示要素の on/off は build() 内の `if` に相当する getter が
// 単独にテストできる形になっている:
//
// - 検索入力欄・SearchAssistView・百科事典カード・Visual Search 導線
//   → 検索サーフェスだけで有効
// - ソースチップ・おすすめ/ランキング切替・ランキングフィルター・
//   フィーリング発掘・Google Drive 同期 HUD
//   → フィードサーフェスだけで有効
// - 16c-4b で combined を廃止。表示分岐は isSearchMode だけになった。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';
import 'package:pixiv_viewer/utils/home_search_ui_mode.dart';

void main() {
  group('feed / search サーフェスの表示要素', () {
    late PixivViewerHomeState state;
    late ValueNotifier<HomeSurfaceMode> notifier;

    setUp(() {
      state = PixivViewerHomeState();
      // 16c-4b: combined 廃止。既定は feed。
      notifier = ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.feed);
      state.attachSurfaceMode(notifier);
    });

    tearDown(() => notifier.dispose);

    test('feed はフィード専用サーフェス', () {
      expect(state.surfaceMode, HomeSurfaceMode.feed);
      expect(state.isFeedSurfaceForTest, isTrue);
    });

    test('search はフィード専用サーフェスではない', () {
      notifier.value = HomeSurfaceMode.search;
      expect(state.isFeedSurfaceForTest, isFalse);
    });

    group('SearchAssistView の表示判定', () {
      test('feed ではどの検索 UI モードでも表示しない', () {
        for (final mode in HomeSearchUiMode.values) {
          state.homeSearchUiMode = mode;
          expect(
            state.shouldShowSearchAssistForTest,
            isFalse,
            reason: 'feed では $mode でもアシストを表示しない',
          );
        }
      });

      test('search では検索結果表示中以外は常時表示', () {
        notifier.value = HomeSurfaceMode.search;

        state.homeSearchUiMode = HomeSearchUiMode.browsing;
        expect(state.shouldShowSearchAssistForTest, isTrue);

        state.homeSearchUiMode = HomeSearchUiMode.assisting;
        expect(state.shouldShowSearchAssistForTest, isTrue);

        // 検索結果一覧が表示中はアシストを隠して結果を表示する。
        state.homeSearchUiMode = HomeSearchUiMode.results;
        expect(state.shouldShowSearchAssistForTest, isFalse);
      });

      test('feed ではどの検索 UI モードでも表示しない', () {
        notifier.value = HomeSurfaceMode.feed;

        for (final mode in HomeSearchUiMode.values) {
          state.homeSearchUiMode = mode;
          expect(
            state.shouldShowSearchAssistForTest,
            isFalse,
            reason: 'feed では $mode でもアシストを表示しない',
          );
        }
      });
    });

    // 検索状態の保持（サーフェスを切り替えてもリセットしない）
    //
    // 【注意】searchController は `late final` で initState でのみ初期化
    // されるため、build を通さない本テストでは未初期化（LateInitializationError）。
    // そのため query の代わりに「検索結果表示中」を示すサブモード
    // （illustSubMode == 1 / novelSubMode == 1）で保持を検証する。
    // resetSearch() を呼ぶと results → browsing へ戻るため、
    // これがサーフェス切替で呼ばれないことを検証できる。

    test('ホームへ切り替えても検索 UI モードは維持される', () {
      notifier.value = HomeSurfaceMode.search;
      state.homeSearchUiMode = HomeSearchUiMode.assisting;

      // ホーム（フィード）へ切り替えても resetSearch() は呼ばない。
      notifier.value = HomeSurfaceMode.feed;
      expect(state.homeSearchUiMode, HomeSearchUiMode.assisting);

      // 検索へ戻す: 再 API リクエストなしで状態が復帰する。
      notifier.value = HomeSurfaceMode.search;
      expect(state.homeSearchUiMode, HomeSearchUiMode.assisting);
    });

    test('ホームへ切り替えても検索結果のサブモードは維持される', () {
      notifier.value = HomeSurfaceMode.search;
      // 検索結果表示中（results 相当）をエミュレート。
      state.illustSubMode = 1;
      state.homeSearchUiMode = HomeSearchUiMode.results;

      notifier.value = HomeSurfaceMode.feed;
      expect(state.illustSubMode, 1);
      expect(state.homeSearchUiMode, HomeSearchUiMode.results);

      // 検索へ戻す: 結果もサブモードもそのまま。
      notifier.value = HomeSurfaceMode.search;
      expect(state.illustSubMode, 1);
      expect(state.homeSearchUiMode, HomeSearchUiMode.results);
    });
  });
}
