// 小説カード（NovelListCard）のレイアウト回帰テスト。
//
// 背景:
// 小説タブの1列リスト（画面幅 <700px、SliverList）は高さ無制限
// （maxHeight = infinity）で構築される。旧実装では無制限値をそのまま
// カバー画像のサイズ計算に使い SizedBox(∞, ∞) を生成するため、
// 「RenderBox was given an infinite size during layout」でクラッシュ
// していた（タブレットの2列グリッド＝高さ固定では発生しない端末依存障害）。
//
// 17g: 透明感の契約（背景 α0.85・枠線 α0.5・ブラー無し）もここで検証する。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/novel_model.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';
import 'package:pixiv_viewer/widgets/novel_list_card.dart';

Novel _buildNovel() => Novel(
  id: 1,
  title: 'テスト小説',
  caption: 'テスト用のあらすじ',
  author: Author(id: 10, name: '作者名', account: 'author'),
  tags: const ['タグ1', 'タグ2'],
  coverUrl: '',
  textCount: 100,
  wordCount: 100,
  textLength: 100,
  pageCount: 1,
  createDate: '2026-01-01T00:00:00+09:00',
  totalView: 10,
  totalBookmarks: 5,
  isBookmarked: false,
);

void main() {
  group('NovelListCard 透明感（17g）', () {
    for (final (name, theme) in [
      ('light', AppTheme.lightTheme),
      ('dark', AppTheme.darkTheme),
    ]) {
      testWidgets('$name: 背景は surfaceContainer α0.85・枠線は α0.5', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: ListView(children: [NovelListCard(novel: _buildNovel())]),
            ),
          ),
        );

        final card = tester.widget<Card>(find.byType(Card));
        final scheme = theme.colorScheme;

        // 17g: 背景は surfaceContainer を α0.85 した色。
        expect(
          card.color,
          scheme.surfaceContainer.withValues(alpha: NovelListCard.surfaceAlpha),
        );
        // 17g: 完全に不透明ではない（0 < alpha < 1）。
        final bgAlpha = card.color!.a;
        expect(bgAlpha, lessThan(1.0));
        expect(bgAlpha, greaterThan(0.0));

        // 17g: 影は完全に無くなった（透明背景に影は浮く）。
        expect(card.elevation, 0.0);

        // 17g: 枠線は outlineVariant を α0.5 に薄めた色。
        final shape = card.shape! as RoundedRectangleBorder;
        final border = shape.side;
        expect(
          border.color,
          scheme.outlineVariant.withValues(alpha: NovelListCard.outlineAlpha),
        );
        // 17g: 枠線の角丸は AppTheme の CardTheme(=20) と一致。
        expect(
          (shape.borderRadius as BorderRadius).topLeft,
          Radius.circular(NovelListCard.cardRadius),
        );
      });

      testWidgets('$name: BackdropFilter / ImageFilter を使わない', (tester) async {
        // 17g: ブラーは電量と性能の観点で禁止。装飾は色の半透明化のみ。
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: ListView(children: [NovelListCard(novel: _buildNovel())]),
            ),
          ),
        );
        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(ui.ImageFilter), findsNothing);
      });
    }
  });

  group('NovelListCard レイアウト', () {
    testWidgets('高さ無制限（SliverList＝スマホ1列）でも無限サイズ制約でクラッシュしない', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, index) => NovelListCard(novel: _buildNovel()),
                    childCount: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // タイトルは RichText（一致度ラベル連結用）で描画されるため find.richText を使う
      expect(find.byWidgetPredicate((w) => w is RichText), findsWidgets);
    });

    testWidgets('高さ固定（SliverGrid＝タブレット2列）でもクラッシュしない', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisExtent: 156.0,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (ctx, index) => NovelListCard(novel: _buildNovel()),
                    childCount: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byWidgetPredicate((w) => w is RichText), findsWidgets);
    });
  });
}
