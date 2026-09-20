// 17c: feed / search サーフェスの表示要素分離テスト。
//
// 16c-3c では feed/search の 2 サーフェスで表示要素を切り替えていたが、
// 17c で検索サーフェスを削除したため「SearchAssistView を表示するか」
// だけが残った。判定は [HomeSearchUiMode] 単体になった:
//
// - assisting（検索バーへの明示的フォーカス等）→ SearchAssistView を表示
// - browsing / results → 表示しない
//
// 本番の [PixivViewerHome] は build 内で DatabaseService にアクセスするため
// widget test で pump できない（`databaseFactory not initialized`）。
// そのため [PixivViewerHomeState] を直接インスタンス化し、
// `@visibleForTesting` な getter で表示判定ロジックだけを検証する
// （16c-3a/16c-3c と同じ手法）。
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';
import 'package:pixiv_viewer/utils/home_search_ui_mode.dart';

void main() {
  group('SearchAssistView の表示判定（17c）', () {
    late PixivViewerHomeState state;

    setUp(() {
      state = PixivViewerHomeState();
    });

    test('browsing では表示しない', () {
      state.homeSearchUiMode = HomeSearchUiMode.browsing;
      expect(state.shouldShowSearchAssistForTest, isFalse);
    });

    test('assisting では表示する', () {
      state.homeSearchUiMode = HomeSearchUiMode.assisting;
      expect(state.shouldShowSearchAssistForTest, isTrue);
    });

    test('results では表示しない', () {
      state.homeSearchUiMode = HomeSearchUiMode.results;
      expect(state.shouldShowSearchAssistForTest, isFalse);
    });
  });
}
