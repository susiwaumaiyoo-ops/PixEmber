// Phase 16c-1: AppShell の契約テスト。
//
// 本番構成（PixivViewerHome 入り）の pump は、DB/認証依存で
// home_encyclopedia_card_test 等も Widget pump せず State を直接
// インスタンス化しているのと同じ理由で要求しない。AppShell が
// IndexedStack で tabs を保持することだけを検証する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/app_shell.dart';

void main() {
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
    await tester.pumpWidget(
      const MaterialApp(home: AppShell(tabs: [Text('A'), Text('B')])),
    );
    // index 0 が表示されている。
    expect(find.text('A'), findsOneWidget);
    // index 1 は offstage でもツリーに存在する（IndexedStack が
    // 常に全タブをビルド・状態保持する性質の確認）。
    expect(find.text('B', skipOffstage: false), findsOneWidget);
  });

  test('tabs 未指定なら本番構成（PixivViewerHome）になる', () {
    // `tabs == null` が本番構成のセンチネル。対応するリスト
    // (`const [PixivViewerHome()]`) は app_shell.dart に直接定義されている。
    //
    // 【pump しない理由】PixivViewerHome は build 内で DatabaseService
    // （購読タグの未読数・home_screen_state.dart:1779）にアクセスし、
    // sqflite の ffi 初期化無しには `Bad state: databaseFactory not
    // initialized` が投げられる。home_encyclopedia_card_test 等も State を
    // 直接インスタンス化してこれを回避しているので、ここでも本番タブの
    // 構成（センチネル）だけを検証する。
    expect(const AppShell().tabs, isNull);
  });

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
