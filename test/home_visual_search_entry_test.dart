// 17c: 「似た画像を探す」導線の契約テスト。
//
// 16c-3c では検索サーフェス（[HomeSurfaceMode].search）に配置していたが、
// 17c で検索目的地を削除したため [SearchAssistView] の末尾へ移設した。
// 本テストは移設先の文脈で検証する: SearchAssistView の末尾に
// [HomeVisualSearchEntry] があり、タップで [VisualSearchScreen] を開く。
//
// 本番の [PixivViewerHomeState] は initState で DB にアクセスするため
// widget test で pump できない（`databaseFactory not initialized`）。
// そのため DB/認証に触れない最小のサブクラスを作り、SearchAssistView の
// 表示要素（と末尾の導線）だけを検証する。SearchAssistView の履歴読み込みは
// try/catch で包まれているため、DB 未初期化でも例外を出さない。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/home_search_assist_view.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/home_visual_search_entry.dart';

/// SearchAssistView が参照する最小のダミー State。
/// 本番の [PixivViewerHomeState] と違い、DB/認証に一切触れない。
class _DummyHomeState extends PixivViewerHomeState {
  _DummyHomeState() {
    // SearchAssistView が検索文字の読み取り/外部変更通知で参照する。
    searchController = TextEditingController();
  }

  int _visualSearchCalls = 0;

  /// [openVisualSearch] が呼ばれた回数（本番は [VisualSearchScreen] を push）。
  int get visualSearchCalls => _visualSearchCalls;

  @override
  void openVisualSearch() => _visualSearchCalls++;
}

void main() {
  late _DummyHomeState state;

  setUp(() {
    state = _DummyHomeState();
  });

  Future<void> pumpAssist(WidgetTester tester, {ThemeData? theme}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        home: Scaffold(body: SearchAssistView(state: state, isNovelTab: false)),
      ),
    );
    // 履歴/トレンド/プリセットの非同期ロード（try/catch 済み）を待つ。
    await tester.pumpAndSettle();
  }

  testWidgets('SearchAssistView の末尾に「似た画像を探す」導線がある（17c）', (tester) async {
    await pumpAssist(tester);

    // 従来の Drawer / 検索サーフェスと同じ文言・アイコンを再利用する。
    expect(find.byType(HomeVisualSearchEntry), findsOneWidget);
    expect(find.text('似た画像を探す'), findsOneWidget);
    expect(find.text('画像の特徴から近い作品を検索'), findsOneWidget);
    expect(find.byIcon(Icons.image_search), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('タップで state.openVisualSearch が呼ばれる（画面の push は State）', (
    tester,
  ) async {
    await pumpAssist(tester);

    await tester.tap(find.text('似た画像を探す'));
    await tester.pumpAndSettle();

    // 本ウィジェット自身は VisualSearchScreen を push しない
    // （検索ロジックを持たない・State が push する）。
    expect(state.visualSearchCalls, 1);
    expect(find.text('似た画像を探す'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    final themeData = brightness == Brightness.dark
        ? AppTheme.darkTheme
        : AppTheme.lightTheme;

    testWidgets('${brightness.name} でタップ領域基準を満たす', (tester) async {
      await pumpAssist(tester, theme: themeData);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });
  }
}
