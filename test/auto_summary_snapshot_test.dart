// Phase 9-B: 自動要約スナップショット（状態モデル・件数導出）のテスト。
//
// 重点: §2 の件数定義（items から毎回導出・加算しない・失敗/スキップを
// 保存済みに含めない・チャンク完了≠作品完了）と §1 の状態/待機理由、
// engine 間送信に必要な Map シリアライズ往復。

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/auto_summary_snapshot.dart';

void main() {
  group('件数導出（§2-A）', () {
    test('対象=保存済+処理中+待ち+失敗+スキップ', () {
      final s = AutoSummarySnapshot(
        items: [
          AutoSummaryItem(
            workId: 1,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.saved,
          ),
          AutoSummaryItem(
            workId: 2,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.saved,
          ),
          AutoSummaryItem(
            workId: 3,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.processing,
          ),
          AutoSummaryItem(
            workId: 4,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.waiting,
          ),
          AutoSummaryItem(
            workId: 5,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.waiting,
          ),
          AutoSummaryItem(
            workId: 6,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.failed,
          ),
          AutoSummaryItem(
            workId: 7,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.skipped,
          ),
        ],
      );
      expect(s.targetCount, 7);
      expect(s.savedCount, 2);
      expect(s.processingCount, 1);
      expect(s.waitingCount, 2);
      expect(s.failedCount, 1);
      expect(s.skippedCount, 1);
      expect(
        s.savedCount +
            s.processingCount +
            s.waitingCount +
            s.failedCount +
            s.skippedCount,
        s.targetCount,
      );
      // 失敗・スキップを保存済みに含めない。
      expect(s.progressDone, s.savedCount);
    });

    test('全件キャッシュ済み（=スキップのみ）は保存済み0', () {
      final s = AutoSummarySnapshot(
        items: [
          AutoSummaryItem(
            workId: 1,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.skipped,
            errorReason: '既存要約あり',
          ),
          AutoSummaryItem(
            workId: 2,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.skipped,
            errorReason: '既存要約あり',
          ),
        ],
      );
      expect(s.savedCount, 0);
      expect(s.skippedCount, 2);
      expect(s.resolvedFinished().phase, AutoSummaryPhase.completedWithErrors);
    });

    test('候補0件（空items）は保存済0・完了判定で completed', () {
      const s = AutoSummarySnapshot(items: []);
      expect(s.targetCount, 0);
      expect(s.savedCount, 0);
      expect(s.resolvedFinished().phase, AutoSummaryPhase.completed);
    });

    test('失敗0なら completed、1以上なら completedWithErrors', () {
      final ok = AutoSummarySnapshot(
        items: [
          AutoSummaryItem(
            workId: 1,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.saved,
          ),
        ],
      );
      final bad = AutoSummarySnapshot(
        items: [
          AutoSummaryItem(
            workId: 1,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.saved,
          ),
          AutoSummaryItem(
            workId: 2,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.failed,
            errorReason: 'decode エラー',
          ),
        ],
      );
      expect(ok.resolvedFinished().phase, AutoSummaryPhase.completed);
      expect(
        bad.resolvedFinished().phase,
        AutoSummaryPhase.completedWithErrors,
      );
    });
  });

  group('状態・待機理由（§1）', () {
    test('isActive / isTerminal 区分', () {
      expect(AutoSummaryPhase.parsingBody.isActive, isTrue);
      expect(AutoSummaryPhase.saving.isActive, isTrue);
      expect(AutoSummaryPhase.completed.isTerminal, isTrue);
      expect(AutoSummaryPhase.error.isTerminal, isTrue);
      expect(AutoSummaryPhase.waitingCondition.isActive, isFalse);
      expect(AutoSummaryPhase.waitingCondition.isTerminal, isFalse);
    });

    test('waitReason に自然な日本語メッセージ', () {
      expect(AutoSummaryWaitReason.power.userMessage, contains('充電'));
      expect(AutoSummaryWaitReason.manualPending.userMessage, contains('手動要約'));
      expect(AutoSummaryWaitReason.none.userMessage, isEmpty);
    });
  });

  group('作品進捗・重複（§2-B/§3-C）', () {
    test('currentItem は currentWorkId 一致を返す', () {
      final s = AutoSummarySnapshot(
        currentWorkId: 42,
        items: [
          AutoSummaryItem(
            workId: 1,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.saved,
          ),
          AutoSummaryItem(
            workId: 42,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.processing,
          ),
        ],
      );
      expect(s.currentItem?.workId, 42);
      expect(s.currentItem?.status, AutoSummaryItemStatus.processing);
    });

    test('同一作品が複数タグ該当でも tags に保持（全体は workId で一意）', () {
      const multi = AutoSummaryItem(
        workId: 7,
        tags: ['百合', '原作'],
        status: AutoSummaryItemStatus.saved,
      );
      expect(multi.tags.length, 2);
      final s = AutoSummarySnapshot(items: [multi]);
      expect(s.targetCount, 1);
      expect(s.savedCount, 1);
    });
  });

  group('Map 往復（engine 間/isolate 送信）', () {
    test('rich なスナップショットが toMap/fromMap で保持される', () {
      final s = AutoSummarySnapshot(
        runId: 'r-1',
        startedAtMillis: 100,
        updatedAtMillis: 200,
        phase: AutoSummaryPhase.parsingBody,
        waitReason: AutoSummaryWaitReason.temperature,
        currentTag: '百合',
        currentWorkId: 55,
        currentWorkTitle: 'タイトル',
        modelLabel: 'smol',
        backendName: 'HTP0 (NPU)',
        workStage: AutoSummaryWorkStage.bodyParse,
        chunkCurrent: 2,
        chunkTotal: 4,
        inputTokensProcessed: 1200,
        inputTokensTotal: 5600,
        outputTokensGenerated: 84,
        cooldownUntilMillis: 0,
        items: [
          AutoSummaryItem(
            workId: 55,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.processing,
          ),
          AutoSummaryItem(
            workId: 56,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.saved,
          ),
          AutoSummaryItem(
            workId: 57,
            tags: const ['百合'],
            status: AutoSummaryItemStatus.failed,
            errorReason: '通信',
          ),
        ],
        tagStats: const [
          AutoSummaryTagStat(
            tag: '百合',
            candidatesChecked: 30,
            existingValid: 3,
            generatedSaved: 1,
            processing: 1,
            waiting: 0,
            failed: 1,
            hasMoreCandidates: true,
          ),
        ],
        candidatesFetched: 40,
        hasMoreCandidates: true,
      );
      final back = AutoSummarySnapshot.fromMap(s.toMap());
      expect(back.runId, 'r-1');
      expect(back.phase, AutoSummaryPhase.parsingBody);
      expect(back.waitReason, AutoSummaryWaitReason.temperature);
      expect(back.currentWorkId, 55);
      expect(back.workStage, AutoSummaryWorkStage.bodyParse);
      expect(back.chunkCurrent, 2);
      expect(back.chunkTotal, 4);
      expect(back.inputTokensProcessed, 1200);
      expect(back.outputTokensGenerated, 84);
      expect(back.savedCount, 1);
      expect(back.failedCount, 1);
      expect(back.items.length, 3);
      expect(back.items[2].errorReason, '通信');
      expect(back.tagStats.single.hasMoreCandidates, isTrue);
      expect(back.hasMoreCandidates, isTrue);
    });

    test('未知 phase 名は disabled、未知 item status は waiting にフォールバック', () {
      final s = AutoSummarySnapshot.fromMap({
        'phase': 'no_such_phase',
        'items': [
          {'workId': 1, 'status': 'nope'},
        ],
      });
      expect(s.phase, AutoSummaryPhase.disabled);
      expect(s.items.single.status, AutoSummaryItemStatus.waiting);
    });

    test('トークン進捗は未指定なら null（不定進捗と区別）', () {
      const s = AutoSummarySnapshot();
      expect(s.inputTokensProcessed, isNull);
      expect(s.inputTokensTotal, isNull);
      expect(s.outputTokensGenerated, isNull);
    });
  });
}
