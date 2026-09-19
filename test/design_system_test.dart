// Phase 16b-2a: デザインシステム共通コンポーネントの契約テスト。
//
// - light/dark 双方で pump 可能
// - AppPanel の背景・枠・角丸が Theme に追従
// - AppStateView の empty/error/loading・action 有無
// - AppStatusBanner 各状態の container/onContainer ペア
// - 長文タイトル/本文で overflow しない
// - textScaleFactor 1.0 / 1.5 / 2.0
// - Semantics に title/message/action が含まれる
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/design_system/app_panel.dart';
import 'package:pixiv_viewer/widgets/design_system/app_section_header.dart';
import 'package:pixiv_viewer/widgets/design_system/app_state_view.dart';
import 'package:pixiv_viewer/widgets/design_system/app_status_banner.dart';

void main() {
  for (final brightness in Brightness.values) {
    final isDark = brightness == Brightness.dark;
    final themeData = isDark ? AppTheme.darkTheme : AppTheme.lightTheme;

    group(isDark ? 'dark' : 'light', () {
      testWidgets('AppPanel が背景・枠・角丸で描画される', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: themeData,
            home: const Scaffold(body: AppPanel(child: Text('面板の中身'))),
          ),
        );

        final material = tester
            .widgetList<Material>(find.byType(Material))
            .last;
        final scheme = themeData.colorScheme;
        expect(material.color, scheme.surfaceContainer);
        expect(material.elevation, 0);
        expect(material.shape, isA<RoundedRectangleBorder>());
        final shape = material.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(20));
        expect(shape.side.color.toARGB32(), scheme.outlineVariant.toARGB32());
        expect(find.text('面板の中身'), findsOneWidget);
      });

      testWidgets('AppPanel は onTap 無しでも描画できる', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: themeData,
            home: const Scaffold(body: AppPanel(child: SizedBox.shrink())),
          ),
        );
        expect(find.byType(AppPanel), findsOneWidget);
        expect(find.byType(InkWell), findsNothing);
      });

      testWidgets('AppSectionHeader がタイトル・subtitle・trailing を描画する', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: themeData,
            home: const Scaffold(
              body: AppSectionHeader(
                '外観',
                icon: Icons.palette_outlined,
                subtitle: 'アプリ全体の色調を切り替えます。',
                trailing: Icon(Icons.chevron_right),
              ),
            ),
          ),
        );

        expect(find.text('外観'), findsOneWidget);
        expect(find.text('アプリ全体の色調を切り替えます。'), findsOneWidget);
        expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      });

      for (final type in AppStateViewType.values) {
        testWidgets('AppStateView(${type.name}) が描画される', (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: themeData,
              home: Scaffold(
                body: AppStateView(type: type, title: 'タイトル', message: 'メッセージ'),
              ),
            ),
          );

          expect(find.text('タイトル'), findsOneWidget);
          expect(find.text('メッセージ'), findsOneWidget);
          if (type == AppStateViewType.loading) {
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
          }
        });
      }

      testWidgets('AppStateView は actionLabel/onAction ペアでのみ表示する', (
        tester,
      ) async {
        var tapped = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: themeData,
            home: Scaffold(
              body: AppStateView(
                type: AppStateViewType.error,
                title: 'タイトル',
                actionLabel: '再試行',
                onAction: () => tapped++,
              ),
            ),
          ),
        );

        expect(find.text('再試行'), findsOneWidget);
        await tester.tap(find.text('再試行'));
        expect(tapped, 1);
      });

      testWidgets('AppStateView は actionLabel だけでは action を出さない', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: themeData,
            home: const Scaffold(
              body: AppStateView(
                type: AppStateViewType.empty,
                title: 'タイトル',
                actionLabel: '再試行',
              ),
            ),
          ),
        );
        expect(find.text('再試行'), findsNothing);
      });

      for (final type in AppStatusType.values) {
        testWidgets(
          'AppStatusBanner(${type.name}) が container/onContainer ペアで描画される',
          (tester) async {
            await tester.pumpWidget(
              MaterialApp(
                theme: themeData,
                home: Scaffold(
                  body: AppStatusBanner(
                    type: type,
                    title: 'ステータス',
                    message: '詳細メッセージ',
                    actionLabel: '実行',
                    onAction: () {},
                  ),
                ),
              ),
            );

            expect(find.text('ステータス'), findsOneWidget);
            expect(find.text('詳細メッセージ'), findsOneWidget);
            expect(find.text('実行'), findsOneWidget);

            // container/onContainer ペア: 描画された Material の背景色は
            // スキームの container 系のいずれかでなければならない。
            // （MaterialApp/Scaffold/TextButton 自体も Material を持つため
            //   バナー直下の Material だけを取得する）
            final material = tester.widget<Material>(
              find
                  .descendant(
                    of: find.byType(AppStatusBanner),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            final scheme = themeData.colorScheme;
            final containerColors = [
              scheme.surfaceContainerHighest,
              scheme.secondaryContainer,
              scheme.tertiaryContainer,
              scheme.errorContainer,
            ];
            expect(
              containerColors.any(
                (c) => c.toARGB32() == material.color!.toARGB32(),
              ),
              isTrue,
              reason: '${type.name} の背景が container 系トークンであること',
            );
          },
        );
      }
    });
  }

  group('共通（テーマ非依存）', () {
    for (final scale in <double>[1.0, 1.5, 2.0]) {
      // 画面内配置（スクロール可能な ListView 等の内部）をシミュレートし、
      // 極端な拡大でもレイアウト崩れしないことを検証する。
      Widget wrapMediaQuery({required Widget child}) {
        return MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: SingleChildScrollView(child: child),
        );
      }

      testWidgets('textScaleFactor $scale で AppStateView が overflow しない', (
        tester,
      ) async {
        final longTitle = 'とても長いタイトル' * 20;
        final longMessage = 'とても長いメッセージ本文です。' * 20;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: wrapMediaQuery(
                  child: AppStateView(
                    type: AppStateViewType.error,
                    title: longTitle,
                    message: longMessage,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(AppStateView), findsOneWidget);
      });

      testWidgets('textScaleFactor $scale で AppStatusBanner が overflow しない', (
        tester,
      ) async {
        final longTitle = 'とても長いステータスタイトル' * 20;
        final longMessage = 'とても長いステータスメッセージです。' * 20;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: wrapMediaQuery(
                  child: AppStatusBanner(
                    type: AppStatusType.warning,
                    title: longTitle,
                    message: longMessage,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(AppStatusBanner), findsOneWidget);
      });
    }

    testWidgets('AppStateView の Semantics に title/message/action が含まれる', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: AppStateView(
              type: AppStateViewType.empty,
              title: '空状態タイトル',
              message: '空状態メッセージ',
              actionLabel: 'アクション',
              onAction: () {},
            ),
          ),
        ),
      );

      expect(find.text('空状態タイトル'), findsOneWidget);
      expect(find.text('空状態メッセージ'), findsOneWidget);
      expect(find.text('アクション'), findsOneWidget);
    });

    testWidgets('AppSectionHeader は padding 未指定で余白を持たない', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(body: AppSectionHeader('見出し')),
        ),
      );
      final padding = tester.widget<Padding>(find.byType(Padding));
      expect(padding.padding, EdgeInsets.zero);
    });

    // ---- Phase 16b-2d: a11y ガイドライン ----
    for (final brightness2 in Brightness.values) {
      final isDark2 = brightness2 == Brightness.dark;
      final themeData2 = isDark2 ? AppTheme.darkTheme : AppTheme.lightTheme;

      testWidgets('${brightness2.name} AppStatusBanner はコントラスト基準を満たす', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            theme: themeData2,
            home: Scaffold(
              body: Column(
                children: [
                  for (final type in AppStatusType.values)
                    AppStatusBanner(
                      type: type,
                      title: '${type.name} タイトル',
                      message: '${type.name} の説明メッセージ',
                    ),
                ],
              ),
            ),
          ),
        );
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });

      testWidgets('${brightness2.name} AppStateView アクションはタップ領域基準を満たす', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: themeData2,
            home: Scaffold(
              body: AppStateView(
                type: AppStateViewType.error,
                title: 'エラー',
                message: '再試行してください',
                actionLabel: '再試行',
                onAction: () {},
              ),
            ),
          ),
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      });
    }
  });
}
