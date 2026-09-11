// Phase 9-B2: fake 実行主体・表示バッチ・進捗画面のテスト。
//
// 対象要件:
// - §1/§2-A: 件数は items から導出（独立カウンタなし）。処理中は最大1、
//   対象 = 保存+処理中+待ち+失敗+スキップ、保存済みは最終保存まで増えない。
// - §3-B: run/pause/resume/stop が同一コントローラ経由で状態遷移する。
// - §3-C: 解析はチャンク x/y で進み、統合・保存が残る限り 100% にならない。
// - §3-D: 表示バッチ（terminal は即時、実行中は間隔でまとまる）。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/services/auto_summary_controller.dart';
import 'package:pixiv_viewer/services/auto_summary_fake_runner.dart';
import 'package:pixiv_viewer/services/auto_summary_snapshot.dart';

List<AutoSummaryItem> _seed(int n, {String tag = '百合'}) => [
  for (var i = 1; i <= n; i++)
    AutoSummaryItem(workId: i, tags: [tag], title: '作品$i'),
];

void main() {
  group('件数導出と進行（§2-A）', () {
    test('開始直後は 1件だけ処理中・対象不変', () {
      final c = FakeAutoSummaryController(seedItems: _seed(3), nowMillis: 0);
      c.runNow();
      final s = c.current;
      expect(s.targetCount, 3);
      expect(s.processingCount, 1, reason: '処理中は最大1');
      expect(s.savedCount, 0, reason: 'まだ最終保存前');
      expect(
        s.targetCount,
        s.savedCount +
            s.processingCount +
            s.waitingCount +
            s.failedCount +
            s.skippedCount,
      );
      c.dispose();
    });

    test('1作品は段階を進めて最終保存のときだけ saved が増える', () {
      final c = FakeAutoSummaryController(
        seedItems: _seed(1),
        chunkTotal: 2,
        nowMillis: 0,
      );
      c.runNow();
      // bodyFetch 表示済み。modelPrepare → bodyParse(1/2) → bodyParse(2/2)
      // → pointMerge → save。save 完了前は saved 0。
      c.advance(); // → modelPrepare
      c.advance(); // → bodyParse chunk1
      expect(c.current.savedCount, 0);
      c.advance(); // chunk2/2
      expect(c.current.workStage, AutoSummaryWorkStage.bodyParse);
      c.advance(); // → pointMerge
      expect(c.current.savedCount, 0);
      c.advance(); // → save
      expect(c.current.savedCount, 0, reason: '保存段階でも確定前は増やさない');
      c.advance(); // save 完了 → saved++ → 全件完了
      expect(c.current.savedCount, 1);
      expect(c.current.phase, AutoSummaryPhase.completed);
      c.dispose();
    });

    test('チャンク進捗は 1..chunkTotal で刻み総数は保持', () {
      final c = FakeAutoSummaryController(
        seedItems: _seed(1),
        chunkTotal: 4,
        nowMillis: 0,
      );
      c.runNow();
      c.advance(); // modelPrepare
      c.advance(); // bodyParse 1/4
      expect(c.current.chunkTotal, 4);
      expect(c.current.chunkCurrent, 1);
      c.advance(); // 2/4
      c.advance(); // 3/4
      c.advance(); // 4/4
      expect(c.current.chunkCurrent, 4);
      c.dispose();
    });

    test('スキップ作品は saved に含めず completedWithErrors 要因', () {
      final c = FakeAutoSummaryController(
        seedItems: _seed(2),
        skipWorkIds: {1},
        nowMillis: 0,
      );
      c.runNow();
      // work1 は skip → work2 が処理中。work2 を完走させる。
      for (var i = 0; i < 6; i++) {
        if (c.current.phase.isTerminal) break;
        c.advance();
      }
      // work2 未完の可能性があるので完走するまで回す。
      while (!c.current.phase.isTerminal) {
        c.advance();
      }
      expect(c.current.skippedCount, 1);
      expect(c.current.savedCount, 1);
      expect(
        c.current.phase,
        AutoSummaryPhase.completedWithErrors,
        reason: 'スキップ1件あり',
      );
      c.dispose();
    });

    test('失敗作品は saved に数えない', () {
      final c = FakeAutoSummaryController(
        seedItems: _seed(1),
        failWorkIds: {1},
        nowMillis: 0,
      );
      c.runNow();
      while (!c.current.phase.isTerminal) {
        c.advance();
      }
      expect(c.current.savedCount, 0);
      expect(c.current.failedCount, 1);
      expect(c.current.phase, AutoSummaryPhase.completedWithErrors);
      c.dispose();
    });
  });

  group('停止・一時停止・再開（§3-B）', () {
    test('pause → paused、resume で処理に戻る', () {
      final c = FakeAutoSummaryController(seedItems: _seed(2), nowMillis: 0);
      c.runNow();
      c.pause();
      expect(c.current.phase, AutoSummaryPhase.pausing);
      c.advance(); // pausing → paused へ確定
      expect(c.current.phase, AutoSummaryPhase.paused);
      final frozenSaved = c.current.savedCount;
      c.advance(); // 一時停止中は進まない
      expect(c.current.phase, AutoSummaryPhase.paused);
      expect(c.current.savedCount, frozenSaved);
      c.resume();
      expect(c.current.phase.isActive, isTrue);
      c.dispose();
    });

    test('stop → finishing → 保存済みは保持して完了', () {
      final c = FakeAutoSummaryController(seedItems: _seed(3), nowMillis: 0);
      c.runNow();
      // 1作品を完走させて saved を1にしてから stop（保存段階完了で saved++）。
      for (var i = 0; i < 20 && c.current.savedCount < 1; i++) {
        c.advance();
      }
      expect(c.current.savedCount, greaterThanOrEqualTo(1));
      c.stop();
      expect(c.current.phase, AutoSummaryPhase.finishing);
      while (!c.current.phase.isTerminal) {
        c.advance();
      }
      // 保存済みは失われない。未処理分は saved に加算されない。
      expect(c.current.savedCount, greaterThanOrEqualTo(1));
      c.dispose();
    });

    test('二重 runNow は処理中件数を2にしない', () {
      final c = FakeAutoSummaryController(seedItems: _seed(2), nowMillis: 0);
      c.runNow();
      c.runNow(); // 実行中なので無視
      c.runNow();
      expect(c.current.processingCount, 1);
      c.dispose();
    });
  });

  group('表示バッチング（§3-D）', () {
    test('terminal phase は待機せず即時反映', () {
      final src = ValueNotifier<AutoSummarySnapshot>(
        const AutoSummarySnapshot(phase: AutoSummaryPhase.parsingBody),
      );
      final batcher = AutoSummarySnapshotBatcher(
        source: src,
        interval: const Duration(seconds: 10),
      );
      src.value = const AutoSummarySnapshot(phase: AutoSummaryPhase.completed);
      expect(batcher.latest.phase, AutoSummaryPhase.completed);
      batcher.dispose();
      src.dispose();
    });

    test('実行中は先頭即反映→間隔内の追加分は最後にまとまる', () async {
      final src = ValueNotifier<AutoSummarySnapshot>(
        const AutoSummarySnapshot(
          phase: AutoSummaryPhase.parsingBody,
          chunkCurrent: 1,
        ),
      );
      final batcher = AutoSummarySnapshotBatcher(
        source: src,
        interval: const Duration(milliseconds: 120),
      );
      // 初期値。
      expect(batcher.latest.chunkCurrent, 1);
      // 先頭の変更は即反映（leading edge）。
      src.value = const AutoSummarySnapshot(
        phase: AutoSummaryPhase.parsingBody,
        chunkCurrent: 2,
      );
      expect(batcher.latest.chunkCurrent, 2);
      // 窓内に続けて到着した 3 は保留（pending）。
      src.value = const AutoSummarySnapshot(
        phase: AutoSummaryPhase.parsingBody,
        chunkCurrent: 3,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      // まだ間隔未満なので 2 のまま（3 はまとまって未放出）。
      expect(batcher.latest.chunkCurrent, 2);
      // 間隔経過 → 最新の 3 のみ反映（中間の更新がまとまった証拠）。
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(batcher.latest.chunkCurrent, 3);
      batcher.dispose();
      src.dispose();
    });
  });

  group('ラベル・状態区分（§1/§3-A）', () {
    test('待機理由は userMessage が優先表示', () {
      const s = AutoSummarySnapshot(
        phase: AutoSummaryPhase.waitingCondition,
        waitReason: AutoSummaryWaitReason.power,
      );
      expect(autoSummaryStatusLabel(s), '充電器が接続されると再開します');
    });

    test('active 段階は workStage ラベル＋チャンクを含む', () {
      const s = AutoSummarySnapshot(
        phase: AutoSummaryPhase.parsingBody,
        workStage: AutoSummaryWorkStage.bodyParse,
        chunkCurrent: 2,
        chunkTotal: 4,
      );
      expect(autoSummaryStatusLabel(s), contains('本文を解析中 2/4ブロック'));
    });

    test('coolingDown は待機中に分類', () {
      const s = AutoSummarySnapshot(phase: AutoSummaryPhase.coolingDown);
      expect(autoSummaryRunStateLabel(s), '待機中');
    });
  });
}
