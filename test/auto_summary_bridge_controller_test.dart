// Phase 9-B2/B2-6: AutoSummaryBridgeController.runNow の回帰テスト。
//
// runNow() は内部で ensureServiceReady() を経てから kCmdRun を送る（修正案B）。
// FGS プラットフォームチャネルに依存しないよう、ensureReady / sendToTask を
// 注入して挙動を検証する。
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/services/auto_summary_bridge_controller.dart';
import 'package:pixiv_viewer/services/auto_summary_task_handler.dart';

void main() {
  test('FGS 未起動: runNow は ensure 成功後に kCmdRun を1回だけ送る', () async {
    var ensureCalls = 0;
    final sent = <Object>[];
    final c = AutoSummaryBridgeController(
      ensureReady: () async {
        ensureCalls++;
        return true;
      },
      sendToTask: sent.add,
    );

    final ok = await c.runNow();

    expect(ok, isTrue);
    expect(ensureCalls, 1);
    expect(sent, [kCmdRun]);
    c.dispose();
  });

  test('ensure 失敗: runNow は false を返しコマンドを送らない', () async {
    var ensureCalls = 0;
    final sent = <Object>[];
    final c = AutoSummaryBridgeController(
      ensureReady: () async {
        ensureCalls++;
        return false;
      },
      sendToTask: sent.add,
    );

    final ok = await c.runNow();

    expect(ok, isFalse);
    expect(ensureCalls, 1);
    expect(sent, isEmpty);
    c.dispose();
  });

  test('稼働中(ensure 即時 true): 二重 startService せずコマンドのみ送る', () async {
    // ensureReady が true を返す＝既に起動済みで内部 startService は走らない前提。
    // runNow は ensure を1回だけ呼び、コマンド送信は1回に留まることを確認。
    var ensureCalls = 0;
    final sent = <Object>[];
    final c = AutoSummaryBridgeController(
      ensureReady: () async {
        ensureCalls++;
        return true;
      },
      sendToTask: sent.add,
    );

    final ok = await c.runNow();

    expect(ok, isTrue);
    expect(ensureCalls, 1);
    expect(sent, [kCmdRun]);
    c.dispose();
  });

  test('連続 runNow: 毎回 ensure→送信される（runNow 側は二重抑止しない）', () async {
    // 二重起動抑止は TaskHandler 側 service.runNow の責務。ブリッジは
    // ensure 成功時に毎回コマンドを送ることを確認（抑止はしない）。
    var ensureCalls = 0;
    final sent = <Object>[];
    final c = AutoSummaryBridgeController(
      ensureReady: () async {
        ensureCalls++;
        return true;
      },
      sendToTask: sent.add,
    );

    await c.runNow();
    await c.runNow();

    expect(ensureCalls, 2);
    expect(sent, [kCmdRun, kCmdRun]);
    c.dispose();
  });
}
