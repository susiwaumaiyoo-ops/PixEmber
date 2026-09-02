// 小説カード（NovelListCard）のレイアウト回帰テスト。
//
// 背景:
// 小説タブの1列リスト（画面幅 <700px、SliverList）は高さ無制限
// （maxHeight = infinity）で構築される。旧実装では無制限値をそのまま
// カバー画像のサイズ計算に使い SizedBox(∞, ∞) を生成するため、
// 「RenderBox was given an infinite size during layout」でクラッシュ
// していた（タブレットの2列グリッド＝高さ固定では発生しない端末依存障害）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/novel_model.dart';
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
