// Phase 16c-2a: HomeContentModeSelector の契約テスト。
//
// 状態は持たせず `currentIndex` / `onModeSelected` を呼び出し元が
// 所有する（home_screen_state.dart の `changeTab`）。ここでは
// 3モードのラベル・アイコン・選択状態・コールバックと a11y を検証する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/home_content_mode_selector.dart';

void main() {
  const modes = [
    (PixivViewerHomeState.illustIndex, 'イラスト', Icons.image_outlined),
    (PixivViewerHomeState.novelIndex, '小説', Icons.book_outlined),
    (
      PixivViewerHomeState.feelingDiscoveryIndex,
      'フィーリング発掘',
      Icons.auto_awesome_outlined,
    ),
  ];

  Future<void> pumpSelector(
    WidgetTester tester, {
    required int currentIndex,
    required ValueChanged<int> onModeSelected,
    ThemeData? theme,
    double textScaleFactor = 1.0,
    bool showFeelingDiscovery = true,
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
        home: Scaffold(
          body: HomeContentModeSelector(
            currentIndex: currentIndex,
            onModeSelected: onModeSelected,
            showFeelingDiscovery: showFeelingDiscovery,
          ),
        ),
      ),
    );
  }

  for (final (index, label, icon) in modes) {
    testWidgets('モード $label（$index）のラベルとアイコンが表示される', (tester) async {
      await pumpSelector(tester, currentIndex: index, onModeSelected: (_) {});
      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
    });
  }

  testWidgets('currentIndex に対応するセグメントだけが選択状態', (tester) async {
    await pumpSelector(
      tester,
      currentIndex: PixivViewerHomeState.novelIndex,
      onModeSelected: (_) {},
    );
    final button = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(button.selected, {PixivViewerHomeState.novelIndex});
    expect(button.segments.length, 3);
    // 選択中アイコンは表示しない（NavigationBar の selectedIcon に相当する
    // 装飾を持たせない設計）。
    expect(button.showSelectedIcon, isFalse);
  });

  // 16c-3a: 検索モードではフィーリング発掘を出さない
  testWidgets('showFeelingDiscovery=false だとセグメントが 2 つになる', (tester) async {
    await pumpSelector(
      tester,
      currentIndex: PixivViewerHomeState.illustIndex,
      onModeSelected: (_) {},
      showFeelingDiscovery: false,
    );
    final button = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(button.segments.length, 2);
    expect(button.segments.map((s) => s.value), [
      PixivViewerHomeState.illustIndex,
      PixivViewerHomeState.novelIndex,
    ]);
    expect(find.text('フィーリング発掘'), findsNothing);
    expect(find.text('イラスト'), findsOneWidget);
    expect(find.text('小説'), findsOneWidget);
  });

  testWidgets('showFeelingDiscovery=false で小説をタップすると novelIndex が通知される', (
    tester,
  ) async {
    int? selected;
    await pumpSelector(
      tester,
      currentIndex: PixivViewerHomeState.illustIndex,
      onModeSelected: (i) => selected = i,
      showFeelingDiscovery: false,
    );
    await tester.tap(find.text('小説'));
    await tester.pump();
    expect(selected, PixivViewerHomeState.novelIndex);
  });

  for (final (index, label, _) in modes) {
    testWidgets('「$label」をタップすると index $index が通知される', (tester) async {
      // SegmentedButton は「選択中」のセグメントをタップしても
      // onSelectionChanged を呼ばない。そのため初期選択をターゲット以外にする。
      final initial = (index + 1) % modes.length;
      int? selected;
      await pumpSelector(
        tester,
        currentIndex: initial,
        onModeSelected: (i) => selected = i,
      );
      await tester.tap(find.text(label));
      await tester.pump();
      expect(selected, index);
    });
  }

  for (final brightness in Brightness.values) {
    final themeData = brightness == Brightness.dark
        ? AppTheme.darkTheme
        : AppTheme.lightTheme;

    testWidgets('${brightness.name} で例外が出ず Semantics ラベルが設定される', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSelector(
        tester,
        currentIndex: PixivViewerHomeState.illustIndex,
        onModeSelected: (_) {},
        theme: themeData,
      );
      expect(find.bySemanticsLabel('コンテンツ種別の切り替え'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('${brightness.name} はタップ領域基準を満たす', (tester) async {
      await pumpSelector(
        tester,
        currentIndex: PixivViewerHomeState.illustIndex,
        onModeSelected: (_) {},
        theme: themeData,
      );
      // セグメント本体（Material + InkWell）が 48dp 以上であること。
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });
  }

  for (final factor in [1.0, 1.5, 2.0]) {
    testWidgets('textScaleFactor $factor で overflow しない', (tester) async {
      await pumpSelector(
        tester,
        currentIndex: PixivViewerHomeState.feelingDiscoveryIndex,
        onModeSelected: (_) {},
        textScaleFactor: factor,
      );
      // flutter_test の overflow 検出（RenderFlex overflow）は
      // pump 後に自動でエラーとして投げられる。ここまで到達すれば合格。
      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
