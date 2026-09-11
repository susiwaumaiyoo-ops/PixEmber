// Phase 9-B2: 進捗ダッシュボード画面のウィジェットスモークテスト（fake 駆動）。
//
// 実行主体＝fake、UI＝表示のみ、の分離が保たれていること／画面が正本スナップ
// ショットの件数導出をそのまま表示すること／ボタンがコントローラを駆動することを検証。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/screens/auto_summary_status_screen.dart';
import 'package:pixiv_viewer/services/auto_summary_fake_runner.dart';
import 'package:pixiv_viewer/services/auto_summary_snapshot.dart';

List<AutoSummaryItem> _seed(int n) => [
  for (var i = 1; i <= n; i++)
    AutoSummaryItem(workId: i, tags: const ['百合'], title: '作品$i'),
];

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('完了状態: 対象・保存済件数と『完了』ラベルが表示される', (tester) async {
    final c = FakeAutoSummaryController(seedItems: _seed(3), nowMillis: 0);
    c.runNow();
    while (!c.current.phase.isTerminal) {
      c.advance();
    }
    expect(c.current.phase, AutoSummaryPhase.completed);

    await tester.pumpWidget(_wrap(AutoSummaryStatusScreen(controller: c)));
    await tester.pump();

    expect(find.text('停止中'), findsOneWidget); // completed は停止扱い
    expect(find.textContaining('対象 3件'), findsOneWidget);
    c.dispose();
  });

  testWidgets('一時停止押下でコントローラが pausing に遷移する', (tester) async {
    final c = FakeAutoSummaryController(seedItems: _seed(3), nowMillis: 0);
    c.runNow();
    await tester.pumpWidget(_wrap(AutoSummaryStatusScreen(controller: c)));
    await tester.pump();

    expect(find.text('実行中'), findsOneWidget);
    await tester.tap(find.text('一時停止'));
    await tester.pump(); // 命令反映（バッチ: active → 即 or 次tick）
    c.advance(); // pausing → paused 確定を進行
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('一時停止中'), findsOneWidget);
    c.dispose();
  });

  testWidgets('タグ別内訳に『タグ総数: 未取得』を正直表示（§2-C）', (tester) async {
    final c = FakeAutoSummaryController(
      seedItems: _seed(2),
      tagStats: const [
        AutoSummaryTagStat(
          tag: '百合',
          candidatesChecked: 40,
          hasMoreCandidates: true,
        ),
      ],
      nowMillis: 0,
    );
    await tester.pumpWidget(_wrap(AutoSummaryStatusScreen(controller: c)));
    await tester.pump();

    expect(find.textContaining('#百合'), findsWidgets);
    expect(find.textContaining('タグ総数: 未取得'), findsOneWidget);
    expect(find.textContaining('追加候補あり'), findsOneWidget);
    c.dispose();
  });
}
