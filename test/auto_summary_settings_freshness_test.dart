// バグ修正 #1（maxPerSession / 設定の鮮度）の回帰テスト。
//
// 検証対象:
//  - AutoSummarySettings.load() は prefs.reload() 経由で最新値を拾う。
//  - runNow() は run 境界で reloadSettings を適用し、構築時の古い上限を
//    使い続けない（常駐 FGS の陳腐化設定バグの核心）。
//  - maxPerSession は「今回キューに入れた作品数」の上限で、キャッシュヒット
//    （skipped）も上限に算入される（実生成件数のみで数えない）。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pixiv_viewer/services/auto_summary_service.dart';
import 'package:pixiv_viewer/services/auto_summary_settings.dart';
import 'package:pixiv_viewer/services/auto_summary_snapshot.dart';
import 'package:pixiv_viewer/services/auto_summary_task_handler.dart';

AutoSummaryCandidatePage _page(List<AutoSummaryItem> items) =>
    AutoSummaryCandidatePage(items: items, hasNext: false);

AutoSummaryItem _cand(int id, {String tag = '百合'}) =>
    AutoSummaryItem(workId: id, tags: [tag], title: '作品$id');

/// 決定論的に動くスタブポート。reloadSettings だけ注入可能にする。
class _Stub {
  _Stub({
    required this.candidates,
    this.cachedWorkIds = const {},
    this.summarizedWorkIds = const {},
    this.reloadSettings,
  });

  final List<AutoSummaryItem> candidates;
  final Set<int> cachedWorkIds;
  final Set<int> summarizedWorkIds;
  final Future<AutoSummarySettings?> Function()? reloadSettings;

  int generateCalls = 0;
  int reloadCalls = 0;

  AutoSummaryPorts build() {
    return AutoSummaryPorts(
      requestGap: Duration.zero,
      fetchCandidates: (tag, page) async =>
          page == 0 ? _page(candidates) : _page(const []),
      resolveBody: (workId) async => 'あ' * 500,
      isCachedValid: (workId, fp) async => cachedWorkIds.contains(workId),
      prepareModel: () async =>
          const AutoSummaryModelInfo(modelLabel: 'm', backendName: 'CPU'),
      fingerprintOf: (title, tags, body) => 'fp:$title',
      generate: (workId, title, tags, body, onStage) async {
        generateCalls++;
      },
      saveSummary: (workId) async {},
      getSummarizedWorkIds: () async => summarizedWorkIds,
      reloadSettings: reloadSettings == null
          ? null
          : () async {
              reloadCalls++;
              return reloadSettings!();
            },
    );
  }
}

AutoSummarySettings _settings({int maxPerSession = 20}) {
  return AutoSummarySettings(
    enabled: true,
    tags: const ['百合'],
    cooldownSeconds: 0,
    maxPerSession: maxPerSession,
  );
}

void main() {
  test('load() は prefs.reload 経由で最新 maxPerSession を拾う', () async {
    SharedPreferences.setMockInitialValues({
      AutoSummarySettings.keyMaxPerSession: 20,
      AutoSummarySettings.keyCooldown: 15,
    });
    final first = await AutoSummarySettings.load();
    expect(first.maxPerSession, 20);

    // UI 側 save() を模擬してプラットフォーム値を変える。
    SharedPreferences.setMockInitialValues({
      AutoSummarySettings.keyMaxPerSession: 5,
      AutoSummarySettings.keyCooldown: 15,
    });
    final after = await AutoSummarySettings.load();
    expect(after.maxPerSession, 5);
  });

  test('runNow は reloadSettings を適用し構築時の古い上限を使わない（#1核心）', () async {
    // 構築時は 20 だが、run 境界で再読込すると 3 になる。
    final stub = _Stub(
      candidates: [for (var i = 1; i <= 10; i++) _cand(i)],
      reloadSettings: () async => _settings(maxPerSession: 3),
    );
    final svc = AutoSummaryService(
      settings: _settings(maxPerSession: 20),
      ports: stub.build(),
    );
    final started = await svc.runNow();
    expect(started, true);
    await svc.finished;

    expect(stub.reloadCalls, 1);
    // 再読込後の 3 が適用され、キューは 3 件で止まる。
    expect(svc.current.targetCount, 3);
    expect(svc.current.items.length, 3);
    expect(stub.generateCalls, 3);
    svc.dispose();
  });

  test('maxPerSession=3・候補10件（キャッシュなし）→ 3件生成で停止', () async {
    final stub = _Stub(candidates: [for (var i = 1; i <= 10; i++) _cand(i)]);
    final svc = AutoSummaryService(
      settings: _settings(maxPerSession: 3),
      ports: stub.build(),
    );
    await svc.runNow();
    await svc.finished;
    expect(svc.current.targetCount, 3);
    expect(stub.generateCalls, 3);
    expect(svc.current.phase, AutoSummaryPhase.completed);
    svc.dispose();
  });

  test('maxPerSession=3・候補5件 all cached → 3件で止まり生成0（#1スキップ算入）', () async {
    final stub = _Stub(
      candidates: [for (var i = 1; i <= 5; i++) _cand(i)],
      cachedWorkIds: const {1, 2, 3, 4, 5},
    );
    final svc = AutoSummaryService(
      settings: _settings(maxPerSession: 3),
      ports: stub.build(),
    );
    await svc.runNow();
    await svc.finished;

    // キャッシュヒットも上限にカウント → キューは 3、うち 3 件がスキップ。
    expect(svc.current.targetCount, 3);
    expect(stub.generateCalls, 0);
    // キャッシュヒットは existing→saved 計上（skip ではない）ので savedCount=3。
    expect(svc.current.savedCount, 3);
    // saved + skipped + failed == 上限（今回の処理対象作品数）。
    final total =
        svc.current.savedCount +
        svc.current.skippedCount +
        svc.current.failedCount;
    expect(total, 3);
    svc.dispose();
  });

  test('生成済みは構築時に事前除外され上限枠を消費しない（#3核心）', () async {
    // 候補1..10、うち1..5は生成済み（llm_summaries に存在）。
    // 事前除外で1..5はスキップし、上限3は未生成の6,7,8で満たされる。
    final stub = _Stub(
      candidates: [for (var i = 1; i <= 10; i++) _cand(i)],
      summarizedWorkIds: const {1, 2, 3, 4, 5},
    );
    final svc = AutoSummaryService(
      settings: _settings(maxPerSession: 3),
      ports: stub.build(),
    );
    await svc.runNow();
    await svc.finished;

    // 生成済みは枠を食わない → キューは未生成3件。
    expect(svc.current.targetCount, 3);
    // 未生成3件を実際に生成（cachedWorkIds は空なので isCachedValid=false）。
    expect(stub.generateCalls, 3);
    expect(svc.current.items.map((e) => e.workId).toList(), [6, 7, 8]);
    svc.dispose();
  });

  test('reloadSettings が null を返す → 既存設定を維持', () async {
    final stub = _Stub(
      candidates: [for (var i = 1; i <= 10; i++) _cand(i)],
      reloadSettings: () async => null,
    );
    final svc = AutoSummaryService(
      settings: _settings(maxPerSession: 3),
      ports: stub.build(),
    );
    await svc.runNow();
    await svc.finished;
    expect(stub.reloadCalls, 1);
    // 再読込 null → 20 ではなく構築時 3 を維持 → 3 件。
    expect(svc.current.targetCount, 3);
    svc.dispose();
  });

  test('アイドル解放待機時間は debug=60s / release=5m（#2切替）', () {
    final expected = kDebugMode
        ? const Duration(seconds: 60)
        : const Duration(minutes: 5);
    expect(kAutoSummaryIdleRelease, expected);
  });
}
