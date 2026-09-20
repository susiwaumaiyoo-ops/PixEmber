// Phase 16c-1/16c-2c: AppShell の契約テスト。
//
// 本番構成（PixivViewerHome 入り）の pump は、DB/認証依存で
// home_encyclopedia_card_test 等も Widget pump せず State を直接
// インスタンス化しているのと同じ理由で要求しない。シェルの構造
// （タブ・ネスト Navigator・NavigationBar）だけを検証する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  Future<void> pumpShell(
    WidgetTester tester, {
    List<Widget>? tabs,
    List<NavigationDestination>? destinations,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        home: AppShell(tabs: tabs, destinations: destinations),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tabs を差し替えるとその内容が表示される', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(tabs: [Placeholder(key: key)]),
      ),
    );
    expect(find.byKey(key), findsOneWidget);
  });

  testWidgets('複数タブでは index 0 が表示され、他のタブも保持される', (tester) async {
    await pumpShell(
      tester,
      tabs: const [Text('A'), Text('B')],
      destinations: twoDestinations,
    );
    // index 0 が表示されている。
    expect(find.text('A'), findsOneWidget);
    // index 1 は offstage でもツリーに存在する（IndexedStack が
    // 常に全タブをビルド・状態保持する性質の確認）。
    expect(find.text('B', skipOffstage: false), findsOneWidget);
  });

  test('tabs 未指定なら本番構成（3 画面）になる', () {
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
  });

  testWidgets('tabs と destinations の数が不一致なら assert が出る', (tester) async {
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
  testWidgets('目的地をタップするとタブが切り替わる', (tester) async {
    await pumpShell(
      tester,
      tabs: const [
        _TabPage(label: 'A'),
        _TabPage(label: 'B'),
      ],
      destinations: twoDestinations,
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

  testWidgets('タブを切り替えて戻ると push した画面が残っている', (tester) async {
    await pumpShell(
      tester,
      tabs: const [
        _TabPage(label: 'A'),
        _TabPage(label: 'B'),
      ],
      destinations: twoDestinations,
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('pushed-A'), findsOneWidget);

    // タブ B へ切り替え。
    await tester.tap(find.text('タブB'));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);

    // タブ A へ戻す: ネスト Navigator の履歴が保持されている。
    await tester.tap(find.text('タブA'));
    await tester.pumpAndSettle();
    expect(find.text('pushed-A'), findsOneWidget);
  });

  testWidgets('選択中タブを再タップするとルートまで pop する', (tester) async {
    await pumpShell(
      tester,
      tabs: const [
        _TabPage(label: 'A'),
        _TabPage(label: 'B'),
      ],
      destinations: twoDestinations,
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
    await pumpShell(
      tester,
      tabs: const [
        _CounterTab(label: 'A'),
        _CounterTab(label: 'B'),
      ],
      destinations: twoDestinations,
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

  for (final brightness in Brightness.values) {
    final themeData = brightness == Brightness.dark
        ? AppTheme.darkTheme
        : AppTheme.lightTheme;

    testWidgets('${brightness.name} で NavigationBar がタップ領域基準を満たす', (
      tester,
    ) async {
      await pumpShell(
        tester,
        tabs: const [
          _TabPage(label: 'A'),
          _TabPage(label: 'B'),
        ],
        destinations: twoDestinations,
        theme: themeData,
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
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
          home: const AppShell(tabs: [SizedBox()]),
        ),
      );
      expect(find.byType(AppShell), findsOneWidget);
      // 次のループでリークしないよう破棄。
      await tester.pumpWidget(Container());
    }
  });
}
