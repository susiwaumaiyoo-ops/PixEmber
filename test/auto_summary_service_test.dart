// Phase 9-B2/B2-3: 実 AutoSummaryService のオーケストレーション検証。
//
// スタブの AutoSummaryPorts で決定論的に駆動し、§7 必須テストを確認する:
// - タグ/作品重複で二重生成しない
// - 全件キャッシュ済 / 候補0
// - 長編チャンク進捗 → 保存
// - 失敗を保存済に数えない
// - ミュート除外 / maxPerSession / hasMoreCandidates（総数未知）
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/services/auto_summary_service.dart';
import 'package:pixiv_viewer/services/auto_summary_settings.dart';
import 'package:pixiv_viewer/services/auto_summary_snapshot.dart';

/// テスト用スタブポート。生成・保存・キャッシュを呼び出し回数で追跡する。
class _StubPorts {
  _StubPorts({
    this.candidatesByTag = const {},
    this.bodies = const {},
    this.cachedWorkIds = const {},
    this.failWorkIds = const {},
    this.mutedWorkIds = const {},
    this.mutedTags = const {},
    this.chunksPerWork = 1,
    this.modelInfo = const AutoSummaryModelInfo(
      modelLabel: 'test-model',
      backendName: 'CPU',
    ),
    this.waitReason,
  });

  final Map<String, List<AutoSummaryCandidatePage>> candidatesByTag;
  final Map<int, String> bodies;
  final Set<int> cachedWorkIds;
  final Set<int> failWorkIds;
  final Set<int> mutedWorkIds;
  final Set<String> mutedTags;
  final int chunksPerWork;
  final AutoSummaryModelInfo modelInfo;
  final AutoSummaryWaitReason? waitReason;

  int generateCalls = 0;
  int saveCalls = 0;
  int prepareCalls = 0;
  final List<int> generatedWorkIds = <int>[];
  final List<AutoSummarySnapshot> persisted = <AutoSummarySnapshot>[];
  final List<String> stageLog = <String>[];

  AutoSummaryPorts build() {
    return AutoSummaryPorts(
      requestGap: Duration.zero,
      fetchCandidates: (tag, page) async {
        final pages = candidatesByTag[tag] ?? const [];
        if (page < 0 || page >= pages.length) {
          return const AutoSummaryCandidatePage(items: [], hasNext: false);
        }
        return pages[page];
      },
      resolveBody: (workId) async => bodies[workId],
      isCachedValid: (workId, fp) async => cachedWorkIds.contains(workId),
      prepareModel: () async {
        prepareCalls++;
        return modelInfo;
      },
      fingerprintOf: (title, tags, body) => 'fp:$title',
      generate: (workId, title, tags, body, onStage) async {
        generateCalls++;
        generatedWorkIds.add(workId);
        for (var c = 1; c <= chunksPerWork; c++) {
          stageLog.add('$workId:$c/$chunksPerWork');
          onStage(c, chunksPerWork);
        }
        if (failWorkIds.contains(workId)) {
          throw Exception('生成に失敗しました（スタブ）');
        }
      },
      saveSummary: (workId) async {
        saveCalls++;
      },
      isMuted: (workId, tags) =>
          mutedWorkIds.contains(workId) ||
          tags.any((t) => mutedTags.contains(t)),
      checkConditions: () async => waitReason,
      persist: (snapshot) async {
        persisted.add(snapshot);
      },
    );
  }
}

AutoSummaryCandidatePage _page(
  List<AutoSummaryItem> items, {
  bool hasNext = false,
}) => AutoSummaryCandidatePage(items: items, hasNext: hasNext);

AutoSummaryItem _cand(int id, {String tag = '百合', String? title}) =>
    AutoSummaryItem(workId: id, tags: [tag], title: title ?? '作品$id');

AutoSummarySettings _settings({
  List<String> tags = const ['百合'],
  int maxPerSession = 20,
  int cooldownSeconds = 0,
}) {
  return AutoSummarySettings(
    enabled: true,
    tags: tags,
    cooldownSeconds: cooldownSeconds,
    maxPerSession: maxPerSession,
  );
}

final _longBody = 'あ' * 500;

void main() {
  test('候補0 → 完了（生成なし・永続化あり）', () async {
    final ports = _StubPorts(candidatesByTag: const {'百合': []});
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    expect(svc.current.phase, AutoSummaryPhase.completed);
    expect(svc.current.targetCount, 0);
    expect(ports.generateCalls, 0);
    expect(ports.persisted.isNotEmpty, true);
    svc.dispose();
  });

  test('正常系 2件 → 生成・保存各2・savedCount=2', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1), _cand(2)]),
        ],
      },
      bodies: {1: _longBody, 2: _longBody},
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    final s = svc.current;
    expect(s.phase, AutoSummaryPhase.completed);
    expect(s.savedCount, 2);
    expect(s.targetCount, 2);
    expect(ports.generateCalls, 2);
    expect(ports.saveCalls, 2);
    expect(ports.prepareCalls, 1); // モデル準備は1セッション1回。
    svc.dispose();
  });

  test('別タグで同一作品 → workId ユニークで二重生成しない', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(7, tag: '百合')], hasNext: false),
        ],
        '科学': [
          _page([_cand(7, tag: '科学')], hasNext: false),
        ],
      },
      bodies: {7: _longBody},
    );
    final svc = AutoSummaryService(
      settings: _settings(tags: const ['百合', '科学']),
      ports: ports.build(),
    );
    svc.runNow();
    await svc.finished;
    expect(svc.current.targetCount, 1);
    expect(ports.generateCalls, 1);
    expect(ports.generatedWorkIds, [7]);
    // 該当タグは統合されている。
    final item = svc.current.items.single;
    expect(item.tags.toSet(), {'百合', '科学'});
    svc.dispose();
  });

  test('全件キャッシュ済 → 生成0・saved 計上・existingValid 増加', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1), _cand(2)]),
        ],
      },
      bodies: {1: _longBody, 2: _longBody},
      cachedWorkIds: const {1, 2},
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    final s = svc.current;
    expect(ports.generateCalls, 0);
    expect(s.savedCount, 2);
    final stat = s.tagStats.firstWhere((t) => t.tag == '百合');
    expect(stat.existingValid, 2);
    expect(stat.generatedSaved, 0);
    svc.dispose();
  });

  test('生成失敗 → failed 計上・completedWithErrors・savedに数えない', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1), _cand(2)]),
        ],
      },
      bodies: {1: _longBody, 2: _longBody},
      failWorkIds: const {2},
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    final s = svc.current;
    expect(s.savedCount, 1);
    expect(s.failedCount, 1);
    expect(s.phase, AutoSummaryPhase.completedWithErrors);
    expect(s.progressDone, s.savedCount); // 失敗は進行に含めない。
    final failedItem = s.items.firstWhere((e) => e.workId == 2);
    expect(failedItem.status, AutoSummaryItemStatus.failed);
    expect(failedItem.errorReason, isNotNull);
    svc.dispose();
  });

  test('短すぎる本文は失敗扱い（保存しない）', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1)]),
        ],
      },
      bodies: {1: '短い'},
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    final s = svc.current;
    expect(ports.generateCalls, 0);
    expect(s.savedCount, 0);
    expect(s.failedCount, 1);
    svc.dispose();
  });

  test('ミュート作品はキューに入れない（生成しない）', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1), _cand(2), _cand(3)]),
        ],
      },
      bodies: {1: _longBody, 2: _longBody, 3: _longBody},
      mutedWorkIds: const {2},
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    expect(svc.current.targetCount, 2);
    expect(ports.generatedWorkIds, [1, 3]);
    svc.dispose();
  });

  test('maxPerSession 到達 → 以降は候補に入れず hasMoreCandidates=true', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1), _cand(2), _cand(3)], hasNext: true),
          _page([_cand(4), _cand(5)], hasNext: true),
        ],
      },
      bodies: {1: _longBody, 2: _longBody},
    );
    final svc = AutoSummaryService(
      settings: _settings(maxPerSession: 2),
      ports: ports.build(),
    );
    svc.runNow();
    await svc.finished;
    final s = svc.current;
    expect(s.targetCount, 2);
    expect(s.hasMoreCandidates, true);
    expect(ports.generateCalls, 2);
    svc.dispose();
  });

  test('条件待ち → waitingCondition + waitReason（生成しない）', () async {
    final ports = _StubPorts(
      candidatesByTag: const {'百合': []},
      waitReason: AutoSummaryWaitReason.power,
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    final s = svc.current;
    expect(s.phase, AutoSummaryPhase.waitingCondition);
    expect(s.waitReason, AutoSummaryWaitReason.power);
    expect(ports.generateCalls, 0);
    expect(ports.prepareCalls, 0); // 条件待ちではモデルをロードしない。
    svc.dispose();
  });

  test('二重 runNow → 完了まで再入しない（生成回数は1セッション分）', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1)]),
        ],
      },
      bodies: {1: _longBody},
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    svc.runNow(); // 実行中 → 無視されるはず。
    await svc.finished;
    expect(ports.generateCalls, 1);
    svc.dispose();
  });

  test('件数整合: 対象 = saved+processing+waiting+failed+skipped（終端で整合）', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1), _cand(2), _cand(3), _cand(4)]),
        ],
      },
      bodies: {1: _longBody, 2: _longBody, 3: _longBody, 4: _longBody},
      cachedWorkIds: const {2},
      failWorkIds: const {3},
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    final s = svc.current;
    final sum =
        s.savedCount +
        s.processingCount +
        s.waitingCount +
        s.failedCount +
        s.skippedCount;
    expect(sum, s.targetCount);
    expect(s.targetCount, 4);
    expect(s.savedCount, 3); // 1(生成) + 2(キャッシュ) + 4(生成)
    expect(s.failedCount, 1); // 3
    svc.dispose();
  });

  test('長編: チャンク進捗が onStage で伝播 → 最終保存で saved', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1)]),
        ],
      },
      bodies: {1: _longBody},
      chunksPerWork: 3,
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    expect(ports.stageLog, ['1:1/3', '1:2/3', '1:3/3']);
    final savedSnap = ports.persisted.last;
    expect(savedSnap.savedCount, 1);
    expect(savedSnap.phase, AutoSummaryPhase.completed);
    svc.dispose();
  });

  test('タグミュート: 該タグ作品はキューに入れない', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1, tag: '百合'), _cand(2, tag: 'R-18')]),
        ],
      },
      bodies: {1: _longBody, 2: _longBody},
      mutedTags: const {'R-18'},
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    expect(svc.current.targetCount, 1);
    expect(ports.generatedWorkIds, [1]);
    svc.dispose();
  });

  test('モデル/バックエンド情報をスナップショットへ記録', () async {
    final ports = _StubPorts(
      candidatesByTag: {
        '百合': [
          _page([_cand(1)]),
        ],
      },
      bodies: {1: _longBody},
      modelInfo: const AutoSummaryModelInfo(
        modelLabel: 'Qwen-0.5B',
        backendName: 'NPU',
      ),
    );
    final svc = AutoSummaryService(settings: _settings(), ports: ports.build());
    svc.runNow();
    await svc.finished;
    expect(svc.current.modelLabel, 'Qwen-0.5B');
    expect(svc.current.backendName, 'NPU');
    svc.dispose();
  });
}
