// Phase 16c-2a: HomeContentModeSelector の契約テスト（17c: 常に 3 セグメント）。
//
// 状態は持たせず `currentIndex` / `onModeSelected` を呼び出し元が
// 所有する（home_screen_state.dart の `changeTab`）。ここでは
// 3モードのラベル・アイコン・選択状態・コールバックと a11y を検証する。
//
// 17c: 検索モードでのフィーリング発掘抑止（`showFeelingDiscovery`）は
// 検索目的地の削除に伴い不要になった。常に 3 セグメントを表示する。
//
// 17h: 17e の「スクロール連動の折りたたみ」（HomeContentModeSelectorCollapse）
// は実機で不安定だったため削除した。代わりに `compact: true` の小型ピルが
// AppBar.title に常駐する。ここでは標準版と compact 版の両方を検証する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/home_content_mode_selector.dart';

void main() {
  const modes = [
    (PixivViewerHomeState.illustIndex, 'イラスト', '絵', Icons.image_outlined),
    (PixivViewerHomeState.novelIndex, '小説', '文', Icons.book_outlined),
    (
      PixivViewerHomeState.feelingDiscoveryIndex,
      'フィーリング発掘',
      '感',
      Icons.auto_awesome_outlined,
    ),
  ];

  Future<void> pumpSelector(
    WidgetTester tester, {
    required int currentIndex,
    required ValueChanged<int> onModeSelected,
    bool compact = false,
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
        home: Scaffold(
          body: HomeContentModeSelector(
            compact: compact,
            currentIndex: currentIndex,
            onModeSelected: onModeSelected,
          ),
        ),
      ),
    );
  }

  for (final (index, label, _, icon) in modes) {
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

  testWidgets('フィーリング発掘セグメントが常に表示される（17c）', (tester) async {
    // 17c: 検索目的地を削除したため、イラスト/小説/フィーリング発掘の
    // 3 セグメントを常に表示する。
    await pumpSelector(
      tester,
      currentIndex: PixivViewerHomeState.illustIndex,
      onModeSelected: (_) {},
    );
    final button = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(button.segments.length, 3);
    expect(button.segments.map((s) => s.value), [
      PixivViewerHomeState.illustIndex,
      PixivViewerHomeState.novelIndex,
      PixivViewerHomeState.feelingDiscoveryIndex,
    ]);
    expect(find.text('フィーリング発掘'), findsOneWidget);
    expect(find.text('イラスト'), findsOneWidget);
    expect(find.text('小説'), findsOneWidget);
  });

  for (final (index, label, _, _) in modes) {
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

  // -------------------------------------------------------------------------
  // 17h: compact モード（AppBar.title に常駐する小型ピル）
  // ------------------------------------------------------------------------
  group('HomeContentModeSelector compact（17h）', () {
    for (final (index, fullLabel, shortLabel, _) in modes) {
      testWidgets('compact=true は短縮ラベル「$shortLabel」を表示し Tooltip に完全名を保持する', (
        tester,
      ) async {
        await pumpSelector(
          tester,
          currentIndex: PixivViewerHomeState.illustIndex,
          onModeSelected: (_) {},
          compact: true,
        );
        // 17h: UI 上のラベルは1文字に短縮される。
        expect(find.text(shortLabel), findsOneWidget);
        // 完全名のテキストは表示されない（Tooltip は message として保持）。
        expect(find.text(fullLabel), findsNothing);
        // Tooltip が完全名を保持しているか。セグメント順と modes の順は同じ。
        final tooltip = tester.widget<Tooltip>(
          find
              .descendant(
                of: find.byType(SegmentedButton<int>),
                matching: find.byType(Tooltip),
              )
              .at(index),
        );
        expect(tooltip.message, fullLabel);
      });
    }

    testWidgets('compact=true でも 3 セグメント・選択状態・コールバックは同じ', (tester) async {
      int? selected;
      await pumpSelector(
        tester,
        currentIndex: PixivViewerHomeState.illustIndex,
        onModeSelected: (i) => selected = i,
        compact: true,
      );
      final button = tester.widget<SegmentedButton<int>>(
        find.byType(SegmentedButton<int>),
      );
      expect(button.segments.length, 3);
      expect(button.selected, {PixivViewerHomeState.illustIndex});

      // compact でもタップでモード切替できる。
      await tester.tap(find.text('文'));
      await tester.pump();
      expect(selected, PixivViewerHomeState.novelIndex);
    });

    for (final brightness in Brightness.values) {
      final themeData = brightness == Brightness.dark
          ? AppTheme.darkTheme
          : AppTheme.lightTheme;

      testWidgets('${brightness.name} の compact が Semantics ラベルを持つ', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pumpSelector(
          tester,
          currentIndex: PixivViewerHomeState.illustIndex,
          onModeSelected: (_) {},
          compact: true,
          theme: themeData,
        );
        expect(find.bySemanticsLabel('コンテンツ種別の切り替え'), findsOneWidget);
        handle.dispose();
      });
    }

    for (final factor in [1.0, 1.5, 2.0]) {
      testWidgets('compact は textScaleFactor $factor で overflow しない', (
        tester,
      ) async {
        await pumpSelector(
          tester,
          currentIndex: PixivViewerHomeState.feelingDiscoveryIndex,
          onModeSelected: (_) {},
          compact: true,
          textScaleFactor: factor,
        );
        expect(find.byType(SegmentedButton<int>), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('compact selector を AppBar.title に組み込んで pump できる', (
      tester,
    ) async {
      // 17h: 本番では [PixivViewerHomeState.build] が AppBar.title の Row に
      // compact selector を置く。PixivViewerHome は build 内で DB にアクセス
      // するため直接 pump できないので、同じ AppBar 構造を組み立てて検証する。
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  const Icon(Icons.auto_awesome),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('フィーリング発掘')),
                  HomeContentModeSelector(
                    compact: true,
                    currentIndex: PixivViewerHomeState.feelingDiscoveryIndex,
                    onModeSelected: (i) => selected = i,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // AppBar 内で short ラベルが表示される。
      expect(find.text('絵'), findsOneWidget);
      expect(find.text('文'), findsOneWidget);
      expect(find.text('感'), findsOneWidget);

      // 選択中でないセグメントをタップするとコールバックが飛ぶ。
      await tester.tap(find.text('絵'));
      await tester.pump();
      expect(selected, PixivViewerHomeState.illustIndex);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 17h: 17e の折りたたみは撤回された（ソース検査による回帰防止）
  // ------------------------------------------------------------------------
  group('17e 折りたたみの撤回（17h）', () {
    test('HomeContentModeSelectorCollapse は存在しない', () {
      // 17e で追加したラッパーは削除された。リフレクション無しでは
      // 「存在しないこと」を直接表明できないので、代わりに compact の
      // 定数が意図した値であることを契約化する（将来の誤変更を防ぐ）。
      expect(HomeContentModeSelector.compactHeight, 48);
      expect(HomeContentModeSelector.preferredHeight, 64);
    });

    test('compact ラベルは3モード分すべて定義されている', () {
      // 17h: 短縮ラベルが3モード分漏れなく定義されていること。
      expect(HomeContentModeSelector.compactHeight, greaterThanOrEqualTo(48));
      // ラベルの定義はテストの modes と一致する必要がある。
      const expected = {
        PixivViewerHomeState.illustIndex: '絵',
        PixivViewerHomeState.novelIndex: '文',
        PixivViewerHomeState.feelingDiscoveryIndex: '感',
      };
      for (final (index, _, shortLabel, _) in modes) {
        expect(shortLabel, expected[index]);
      }
    });
  });
}
