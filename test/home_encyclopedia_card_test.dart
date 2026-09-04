// B2: 検索実行の瞬間に出現する「ピクシブ百科事典カード」が、
// 表示可能高さが狭いとき（キーボード表示中等）に body 下端で
// BOTTOM OVERFLOWED を起こさないことを検証する。
//
// 修正前はカードが固定natural高さ（要約3行＋リンクで最大≒179px）のまま
// 検索バー(≒56)＋ソースチップ(44) と共に積まれ、body が縮小した際に
// 下端をあふらせていた。修正後は使用可能高さを MediaQuery から算出し、
// 収まらない場合は高さを上限切りしてカード内を縦スクロール可能にする。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/screens/home_screen_state.dart';
import 'package:pixiv_viewer/screens/home_ui_components.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 百科事典カードを論理高さ [viewHeight]px の環境で組み立て、
/// pump してオーバーフローが起きないことを確認する。
Future<void> _pumpCard(
  WidgetTester tester, {
  required double viewHeight,
  required SearchItem searchItem,
}) async {
  final state = PixivViewerHomeState();
  // 検索結果モード（subMode=1）＋百科事典データありの状態を模擬。
  // これは buildEncyclopediaCard の表示条件（activeSubMode==1 && searchItem!=null）
  // を満たすための最小セットアップである。
  state
    ..currentIndex = PixivViewerHomeState.illustIndex
    ..illustSubMode = 1
    ..searchItem = searchItem;

  tester.view.physicalSize = Size(1080, viewHeight);
  tester.view.devicePixelRatio = 1.0;

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(1080, viewHeight),
          devicePixelRatio: 1.0,
          padding: const EdgeInsets.only(top: 24),
        ),
        child: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                // 検索バー + ソースチップに相当する固定高さブロック（≒100px）。
                const SizedBox(height: 100),
                Expanded(
                  child: HomeUIComponents(state).buildEncyclopediaCard(context),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('表示可能高さが狭くても百科事典カードで overflow しない', (tester) async {
    // 論理高さ 360px：body が縮小した状況を模擬。
    final item = SearchItem(
      name: '猫',
      dicUrl: 'https://dic.pixiv.net/a/%E7%8C%AB',
      summary: 'とても長い要約。' * 40, // 3行 maxLines でも最大高さ近くになる。
      wordCount: 12345,
    );
    await _pumpCard(tester, viewHeight: 360, searchItem: item);
    // 黄黒の overflow バナー（_DebugOverflowIndicator 等）が出ていないこと。
    expect(
      tester.takeException(),
      isNull,
      reason: '表示可能高さが狭いとき百科事典カードで overflow 例外が起きてはならない',
    );
    expect(find.byType(Card), findsOneWidget);
  });

  testWidgets('空き高さがカード最大高さ未満なら上限で切られてスクロール可能', (tester) async {
    // 論理高さ 280px：available が _kEncyclopediaCardMaxHeight(180) 未満になり
    // カードは高さ上限で切られて内部スクロールになるはず。
    final item = SearchItem(
      name: '犬',
      dicUrl: 'https://dic.pixiv.net/a/%E7%8A%AC',
      summary: '要約。' * 60,
      wordCount: 999,
    );
    await _pumpCard(tester, viewHeight: 280, searchItem: item);

    final card = tester.widget<Card>(find.byType(Card));
    final box = tester.renderObject<RenderBox>(find.byType(Card));
    // カード自体が画面全体より高くならない（スクロールで収まる）。
    expect(box.size.height, lessThanOrEqualTo(280 - 100 + 1));
    expect(card.clipBehavior, Clip.antiAlias);
    // カード内に SingleChildScrollView が配置されスクロール可能になっている。
    expect(
      find.descendant(
        of: find.byType(Card),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
  });
}
