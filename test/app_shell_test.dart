// Phase 16c-1/16c-2c/16c-3b: AppShell の契約テスト。
//
// 本番構成（PixivViewerHome 入り）の pump は、DB/認証依存で
// home_encyclopedia_card_test 等も Widget pump せず State を直接
// インスタンス化しているのと同じ理由で要求しない。シェルの構造
// （4 目的地・3 物理 Navigator・目的地↔物理タブの対応・戻る操作）
// だけを検証する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/home_screen_widget.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/app_shell.dart';

/// タブ内に push するためのダミー画面。タップで1枚積む。
class _TabPage extends StatelessWidget {
  const _TabPage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text(label)),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                Scaffold(body: Center(child: Text('pushed-$label'))),
          ),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// タップ回数を数える StatefulWidget（タブ切替後の state 保持の検証用）。
class _CounterTab extends StatefulWidget {
  const _CounterTab({required this.label});

  final String label;

  @override
  State<_CounterTab> createState() => _CounterTabState();
}

class _CounterTabState extends State<_CounterTab> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('${widget.label}-$_count')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _count++),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// 2 タブのテストで使う目的地（NavigationBar のラベルと区別するため
/// 本文のテキストとは違う文字列にする）。
const twoDestinations = <NavigationDestination>[
  NavigationDestination(icon: Icon(Icons.home), label: 'タブA'),
  NavigationDestination(icon: Icon(Icons.home), label: 'タブB'),
];

/// 2 タブ構成で「目的地を1つしか持たない」ことを検証するための目的地。
/// [NavigationBar] は常に 2 つ以上の目的地を要求するため、
/// 単一目的地のテストは（フレームワークの制約として）書けない。
const dummyTwoDestinations = <NavigationDestination>[
  NavigationDestination(icon: Icon(Icons.home), label: 'ダミーA'),
  NavigationDestination(icon: Icon(Icons.home), label: 'ダミーB'),
];

/// 本番の 3 物理 Navigator に相当するテスト用タブ。
/// ホーム/検索で共有するタブには NavigationBar のラベルと衝突しない
/// 文字列を与える（`find.text('ホーム')` が NavigationBar のラベルに
/// ヒットするのを防ぐため）。
const threeTabs = <Widget>[
  _TabPage(label: 'ホーム本文'),
  _TabPage(label: 'ライブラリ本文'),
  _TabPage(label: '設定本文'),
];

/// カウンタ版の 3 タブ（ホーム State の共有検証用）。
/// NavigationBar のラベル（ホーム/ライブラリ/設定）と衝突しないよう
/// 本文のラベルには「本文」を付ける。
const threeCounterTabs = <Widget>[
  _CounterTab(label: 'ホーム本文'),
  _CounterTab(label: 'ライブラリ本文'),
  _CounterTab(label: '設定本文'),
];

void main() {
  Future<void> pumpShell(
    WidgetTester tester, {
    List<Widget>? tabs,
    List<NavigationDestination>? destinations,
    List<int>? destinationToTab,
    ThemeData? theme,
    double textScaleFactor = 1.0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScaleFactor)),
          child: child!,
        ),
        home: AppShell(
          tabs: tabs,
          destinations: destinations,
          destinationToTab: destinationToTab,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 2 タブ構成のデフォルト引数（目的地↔物理タブは 1:1）。
  Future<void> pumpTwoTabShell(
    WidgetTester tester, {
    required List<Widget> tabs,
    ThemeData? theme,
  }) async {
    await pumpShell(
      tester,
      tabs: tabs,
      destinations: twoDestinations,
      destinationToTab: const [0, 1],
      theme: theme,
    );
  }

  group('構成の注入と検証', () {
    testWidgets('tabs を差し替えるとその内容が表示される', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            tabs: [
              Placeholder(key: key),
              const SizedBox(),
            ],
            destinations: dummyTwoDestinations,
            destinationToTab: const [0, 1],
          ),
        ),
      );
      expect(find.byKey(key), findsOneWidget);
    });

    testWidgets('複数タブでは index 0 が表示され、他のタブも保持される', (tester) async {
      await pumpTwoTabShell(tester, tabs: const [Text('A'), Text('B')]);
      // index 0 が表示されている。
      expect(find.text('A'), findsOneWidget);
      // index 1 は offstage でもツリーに存在する（Offstage が
      // 常に全タブをビルド・状態保持する性質の確認）。
      expect(find.text('B', skipOffstage: false), findsOneWidget);
    });

    test('tabs 未指定なら本番構成になる', () {
      // `tabs == null` が本番構成のセンチネル。
      //
      // 【pump しない理由】PixivViewerHome は build 内で DatabaseService
      // （購読タグの未読数・home_screen_state.dart:1779）にアクセスし、
      // sqflite の ffi 初期化無しには `Bad state: databaseFactory not
      // initialized` が投げられる。home_encyclopedia_card_test 等も State を
      // 直接インスタンス化してこれを回避しているので、ここでも本番タブの
      // 構成（センチネル）だけを検証する。
      expect(const AppShell().tabs, isNull);
      expect(const AppShell().destinations, isNull);
      expect(const AppShell().destinationToTab, isNull);
    });

    testWidgets('destinations と destinationToTab の長さが不一致なら assert が出る', (
      tester,
    ) async {
      // 検証は State.initState で行う（const コンストラクタ内では
      // `.length` を評価できないため）。pump して初回 build を走らせ、
      // 構築中に投げられた AssertionError を takeException で受け取る。
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            tabs: const [SizedBox()],
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'a'),
              NavigationDestination(icon: Icon(Icons.home), label: 'b'),
            ],
            destinationToTab: const [0],
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isAssertionError);
    });

    testWidgets('destinationToTab が tabs の範囲外なら assert が出る', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            tabs: const [SizedBox(), SizedBox()],
            destinations: dummyTwoDestinations,
            destinationToTab: const [0, 5],
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isAssertionError);
    });

    testWidgets('tabs が空なら assert が出る', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AppShell(tabs: [])));
      await tester.pump();
      expect(tester.takeException(), isAssertionError);
    });
  });

  group('目的地と物理タブ（Phase 16c-3b）', () {
    testWidgets('本番の 4 目的地が NavigationBar に表示される', (tester) async {
      await pumpShell(tester, tabs: threeTabs);
      for (final label in ['ホーム', '検索', 'ライブラリ', '設定']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('ホームと検索は同じ物理タブを共有する', (tester) async {
      await pumpShell(tester, tabs: threeTabs);

      // 初期状態: ホーム目的地 = 物理 tab 0。
      expect(find.text('ホーム本文'), findsOneWidget);
      expect(find.byIcon(Icons.home), findsOneWidget);

      // 検索目的地へ。
      await tester.tap(find.text('検索'));
      await tester.pumpAndSettle();

      // 同じ物理タブを使うため、表示中の Widget は切り替わらない。
      expect(find.text('ホーム本文'), findsOneWidget);
      expect(find.text('ライブラリ本文'), findsNothing);
      // NavigationBar の選択状態は検索に移動している。
      expect(find.byIcon(Icons.manage_search), findsOneWidget);
      expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    });

    testWidgets('ホームから検索へ切替えても同じ State を使い続ける', (tester) async {
      await pumpShell(tester, tabs: threeCounterTabs);
      final state = tester.state<AppShellState>(find.byType(AppShell));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('ホーム本文-1'), findsOneWidget);

      // 検索目的地へ切替えても、ホーム物理タブの State はそのまま。
      await tester.tap(find.text('検索'));
      await tester.pumpAndSettle();
      expect(find.text('ホーム本文-1'), findsOneWidget);
      expect(state.homeSurfaceModeForTest, HomeSurfaceMode.search);
    });

    testWidgets('検索ワークスペースの State はホームへ戻っても維持される', (tester) async {
      await pumpShell(tester, tabs: threeCounterTabs);
      final state = tester.state<AppShellState>(find.byType(AppShell));

      await tester.tap(find.text('検索'));
      await tester.pumpAndSettle();
      expect(state.homeSurfaceModeForTest, HomeSurfaceMode.search);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('ホーム本文-1'), findsOneWidget);

      // ホームへ戻す: 同じ State なのでカウントは維持される。
      await tester.tap(find.text('ホーム'));
      await tester.pumpAndSettle();
      expect(find.text('ホーム本文-1'), findsOneWidget);
      expect(state.homeSurfaceModeForTest, HomeSurfaceMode.feed);

      // 再び検索へ: カウントもサーフェスモードも維持されたまま。
      await tester.tap(find.text('検索'));
      await tester.pumpAndSettle();
      expect(find.text('ホーム本文-1'), findsOneWidget);
      expect(state.homeSurfaceModeForTest, HomeSurfaceMode.search);
    });

    testWidgets('ホーム/検索の切替で詳細 Route はルートまで pop される', (tester) async {
      await pumpShell(tester, tabs: threeTabs);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('pushed-ホーム本文'), findsOneWidget);

      // 検索へ: 検索ワークスペースが詳細画面に隠れないように pop する。
      await tester.tap(find.text('検索'));
      await tester.pumpAndSettle();
      expect(find.text('pushed-ホーム本文'), findsNothing);
      expect(find.text('ホーム本文'), findsOneWidget);

      // ホームへ戻しても、やはりルートまで pop されている。
      await tester.tap(find.text('ホーム'));
      await tester.pumpAndSettle();
      expect(find.text('pushed-ホーム本文'), findsNothing);
    });

    testWidgets('ライブラリと設定の履歴は切替えても保持される', (tester) async {
      await pumpShell(tester, tabs: threeTabs);

      // ライブラリ物理タブで push。
      await tester.tap(find.text('ライブラリ'));
      await tester.pumpAndSettle();
      expect(find.text('ライブラリ本文'), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('pushed-ライブラリ本文'), findsOneWidget);

      // 設定物理タブへ（ホーム/検索と違い pop されない）。
      await tester.tap(find.text('設定'));
      await tester.pumpAndSettle();
      expect(find.text('設定本文'), findsOneWidget);

      // ライブラリへ戻す: ネスト Navigator の履歴がそのまま残っている。
      await tester.tap(find.text('ライブラリ'));
      await tester.pumpAndSettle();
      expect(find.text('pushed-ライブラリ本文'), findsOneWidget);
    });

    testWidgets('ライブラリのタグ操作で検索目的地へ切り替わる', (tester) async {
      await pumpShell(tester, tabs: threeTabs);
      final state = tester.state<AppShellState>(find.byType(AppShell));

      expect(find.text('ホーム本文'), findsOneWidget);
      expect(state.homeSurfaceModeForTest, HomeSurfaceMode.feed);

      // 本番では LibraryHubScreen の onTagTap がこの処理を呼ぶ。
      state.searchForTagForTest('小説');
      await tester.pumpAndSettle();

      expect(state.homeSurfaceModeForTest, HomeSurfaceMode.search);
      expect(find.byIcon(Icons.manage_search), findsOneWidget);
      // 同じ物理タブ（ホーム/検索共有）を表示したまま。
      expect(find.text('ホーム本文'), findsOneWidget);
      // テスト注入タブで PixivViewerHome が未構築でも例外を出さない。
      expect(tester.takeException(), isNull);
    });
  });

  group('2 タブ構成の基本動作', () {
    testWidgets('目的地をタップするとタブが切り替わる', (tester) async {
      await pumpTwoTabShell(
        tester,
        tabs: const [
          _TabPage(label: 'A'),
          _TabPage(label: 'B'),
        ],
      );
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsNothing);

      await tester.tap(find.text('タブB'));
      await tester.pumpAndSettle();

      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('タブ内で push するとそのタブの Navigator にだけ積まれる', (tester) async {
      final observer = NavigatorObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: AppShell(
            tabs: const [
              _TabPage(label: 'A'),
              _TabPage(label: 'B'),
            ],
            destinations: twoDestinations,
            destinationToTab: const [0, 1],
          ),
        ),
      );
      await tester.pumpAndSettle();
      // MaterialApp の home ルート自身が 1 枚積まれている。
      // ネスト Navigator の push はこの root observer には届かない。
      expect(tester.widgetList(find.byType(Navigator)).length, greaterThan(1));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // タブ A のネスト Navigator に 1 枚積まれ、画面に表示される。
      expect(find.text('pushed-A'), findsOneWidget);
      expect(find.text('pushed-B'), findsNothing);
    });

    testWidgets('ホーム目的地へ切り替えると共有 Navigator はルートまで pop される', (tester) async {
      // 16c-3b の設計: ホーム/検索は同じ物理 Navigator を共有するため、
      // ホーム目的地が選ばれたときは詳細 Route をルートまで pop して
      // フィードワークスペースを表示する（State は破棄しない）。
      await pumpShell(tester, tabs: threeTabs);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('pushed-ホーム本文'), findsOneWidget);

      // ライブラリ物理タブ（履歴は維持される）へ切り替え。
      await tester.tap(find.text('ライブラリ'));
      await tester.pumpAndSettle();
      expect(find.text('ライブラリ本文'), findsOneWidget);

      // ホームへ戻す: 共有 Navigator の詳細 Route はルートまで pop される。
      await tester.tap(find.text('ホーム'));
      await tester.pumpAndSettle();
      expect(find.text('pushed-ホーム本文'), findsNothing);
      expect(find.text('ホーム本文'), findsOneWidget);
    });

    testWidgets('選択中タブを再タップするとルートまで pop する', (tester) async {
      await pumpTwoTabShell(
        tester,
        tabs: const [
          _TabPage(label: 'A'),
          _TabPage(label: 'B'),
        ],
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('pushed-A'), findsOneWidget);

      // 選択中タブ（タブA）を再タップ。
      await tester.tap(find.text('タブA'));
      await tester.pumpAndSettle();
      expect(find.text('pushed-A'), findsNothing);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('タブを切り替えても Widget state が保持される', (tester) async {
      await pumpTwoTabShell(
        tester,
        tabs: const [
          _CounterTab(label: 'A'),
          _CounterTab(label: 'B'),
        ],
      );
      expect(find.text('A-0'), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('A-1'), findsOneWidget);

      // タブ B へ切り替えてカウントアップ。
      await tester.tap(find.text('タブB'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('B-1'), findsOneWidget);

      // タブ A のカウントはそのまま。
      await tester.tap(find.text('タブA'));
      await tester.pumpAndSettle();
      expect(find.text('A-1'), findsOneWidget);
    });
  });

  // ---- 16c-2d / 16c-3b: 戻る操作（ネスト Navigator + PopScope） ----

  group('戻る操作', () {
    testWidgets('タブ内 push 後の戻るは現在タブだけを pop する', (tester) async {
      await pumpTwoTabShell(
        tester,
        tabs: const [
          _TabPage(label: 'A'),
          _TabPage(label: 'B'),
        ],
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('pushed-A'), findsOneWidget);

      // OS の戻るをシミュレート（handlePopRoute は PopScope/Navigator の
      // 処理結果を bool で返す: true = アプリが消費した）。
      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: 'ネスト Navigator が pop を消費');
      expect(find.text('pushed-A'), findsNothing);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('検索のルートで戻るとホームへ切替わる', (tester) async {
      await pumpShell(tester, tabs: threeTabs);
      final state = tester.state<AppShellState>(find.byType(AppShell));

      await tester.tap(find.text('検索'));
      await tester.pumpAndSettle();
      expect(state.homeSurfaceModeForTest, HomeSurfaceMode.search);

      // OS 戻る: 検索ルートは pop できないので AppShell が消費して
      // ホーム目的地へ切替える（handlePopRoute はアプリが消費すると true）。
      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: 'AppShell が戻るを消費してホームへ切替');
      expect(state.homeSurfaceModeForTest, HomeSurfaceMode.feed);
      expect(find.byIcon(Icons.home), findsOneWidget);
    });

    testWidgets('ライブラリ/設定のルートで戻るとホームへ切替わる', (tester) async {
      await pumpTwoTabShell(
        tester,
        tabs: const [
          _TabPage(label: 'A'),
          _TabPage(label: 'B'),
        ],
      );

      // タブ B（ルート、pop 不可）へ切り替え。
      await tester.tap(find.text('タブB'));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);

      // OS 戻る: ルートなのでアプリが戻るを処理し、PopScope が
      // ホームへ切替える（handlePopRoute はアプリが消費すると true）。
      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: 'AppShell が戻るを消費してホームへ切替');
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsNothing);
    });

    testWidgets('ホームのルートで戻る操作を握りつぶさない', (tester) async {
      await pumpTwoTabShell(
        tester,
        tabs: const [
          _TabPage(label: 'A'),
          _TabPage(label: 'B'),
        ],
      );

      // タブ A（ホーム相当）のルート。OS 戻るはそのまま通す。
      // （ネスト Navigator は pop できず、PopScope の canPop は true）
      final handled = await tester.binding.handlePopRoute();
      expect(handled, isFalse, reason: 'ホームルートでは OS へ戻す');
    });

    testWidgets('root Navigator に push した画面はタブより上に表示される', (tester) async {
      await pumpTwoTabShell(
        tester,
        tabs: const [
          _TabPage(label: 'A'),
          _TabPage(label: 'B'),
        ],
      );

      // タブ B を選択した状態で root Navigator にダイアログを出す
      // （ログイン WebView ダイアログと同じスコープ）。
      await tester.tap(find.text('タブB'));
      await tester.pumpAndSettle();

      final rootContext = tester.element(find.byType(AppShell));
      showDialog<void>(
        context: rootContext,
        useRootNavigator: true,
        builder: (_) => const AlertDialog(title: Text('root dialog')),
      );
      await tester.pumpAndSettle();

      // タブ B の上に重なる。
      expect(find.text('root dialog'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);

      // 戻るでダイアログだけが閉じ、タブ B は残る。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('root dialog'), findsNothing);
      expect(find.text('B'), findsOneWidget);
    });
  });

  group('アクセシビリティ', () {
    for (final brightness in Brightness.values) {
      final themeData = brightness == Brightness.dark
          ? AppTheme.darkTheme
          : AppTheme.lightTheme;

      testWidgets('${brightness.name} の 4 目的地がタップ領域基準を満たす', (tester) async {
        await pumpShell(tester, tabs: threeTabs, theme: themeData);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      });

      testWidgets('${brightness.name} の 4 目的地が textScaleFactor 2.0 でも崩れない', (
        tester,
      ) async {
        await pumpShell(
          tester,
          tabs: threeTabs,
          theme: themeData,
          textScaleFactor: 2.0,
        );
        for (final label in ['ホーム', '検索', 'ライブラリ', '設定']) {
          expect(find.text(label), findsOneWidget);
        }
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      });
    }

    testWidgets('light / dark 両テーマでウィジェット例外が出ない', (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final theme = brightness == Brightness.dark
            ? AppTheme.darkTheme
            : AppTheme.lightTheme;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: AppShell(
              tabs: const [SizedBox(), SizedBox()],
              destinations: dummyTwoDestinations,
              destinationToTab: const [0, 1],
            ),
          ),
        );
        expect(find.byType(AppShell), findsOneWidget);
        // 次のループでリークしないよう破棄。
        await tester.pumpWidget(Container());
      }
    });
  });
}
