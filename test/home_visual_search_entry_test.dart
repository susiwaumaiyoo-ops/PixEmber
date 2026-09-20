// Phase 16c-3c: 検索ワークスペースの「似た画像を探す」導線の契約テスト。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/home_visual_search_entry.dart';

void main() {
  Future<void> pumpEntry(
    WidgetTester tester, {
    required VoidCallback onTap,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        home: Scaffold(
          body: ListView(children: [HomeVisualSearchEntry(onTap: onTap)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('従来の Drawer と同じ文言・アイコンを表示する', (tester) async {
    await pumpEntry(tester, onTap: () {});

    // Drawer の「似た画像を探す / 画像の特徴から近い作品を検索」を
    // そのまま再利用する（新文言は作らない）。
    expect(find.text('似た画像を探す'), findsOneWidget);
    expect(find.text('画像の特徴から近い作品を検索'), findsOneWidget);
    expect(find.byIcon(Icons.image_search), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('タップでコールバックが呼ばれる（画面の push は呼び出し元）', (tester) async {
    var tapped = 0;
    await pumpEntry(tester, onTap: () => tapped++);

    await tester.tap(find.text('似た画像を探す'));
    await tester.pumpAndSettle();

    expect(tapped, 1);
    // 本ウィジェット自身は VisualSearchScreen を push しない
    // （検索ロジックを持たない・呼び出し元が push する）。
    expect(find.text('似た画像を探す'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    final themeData = brightness == Brightness.dark
        ? AppTheme.darkTheme
        : AppTheme.lightTheme;

    testWidgets('${brightness.name} でタップ領域基準を満たす', (tester) async {
      await pumpEntry(tester, onTap: () {}, theme: themeData);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });
  }
}
