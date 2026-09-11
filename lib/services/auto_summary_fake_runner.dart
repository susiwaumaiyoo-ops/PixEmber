// Phase 9-B2: 実行基盤（B2-3）が繋がる前に、進捗UI・通知を動作検証するための
// fake 実行主体。AutoSummaryController を実装し、正本スナップショットだけを
// 保持して段階を進行させる（件数は items から毎回導出 — 独立カウンタを持たない）。
//
// テストは決定論的に [advance] を呼んで進行を検証する。UI で「動く」様子を見る
// 場合だけ [startTicker] で周期ティックを有効化する。
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auto_summary_controller.dart';
import 'auto_summary_snapshot.dart';

/// fake 用・作品ごとのチャンク総数。
const int kFakeChunkTotal = 4;

/// 進行シナリオを決定論的に駆動する fake コントローラ。
class FakeAutoSummaryController implements AutoSummaryController {
  FakeAutoSummaryController({
    required List<AutoSummaryItem> seedItems,
    this.chunkTotal = kFakeChunkTotal,
    List<AutoSummaryTagStat> tagStats = const [],
    int cooldownSeconds = 0,
    Set<int> failWorkIds = const {},
    Set<int> skipWorkIds = const {},
    String runId = 'fake-run',
    int? nowMillis,
  })  : _tagStats = tagStats,
        _cooldownSeconds = cooldownSeconds,
        _failWorkIds = failWorkIds,
        _skipWorkIds = skipWorkIds,
        _now = nowMillis ?? DateTime.now().millisecondsSinceEpoch {
    _items = _normalize(seedItems);
    _snapshot = AutoSummarySnapshot(
      runId: runId,
      startedAtMillis: _now,
      updatedAtMillis: _now,
      phase: AutoSummaryPhase.disabled,
      items: _items,
      tagStats: _tagStats,
    );
    _notifier.value = _snapshot;
  }

  final int chunkTotal;
  final int _cooldownSeconds;
  final Set<int> _failWorkIds;
  final Set<int> _skipWorkIds;
  final List<AutoSummaryTagStat> _tagStats;

  int _now;
  late final List<AutoSummaryItem> _items;
  late AutoSummarySnapshot _snapshot;
  final ValueNotifier<AutoSummarySnapshot> _notifier =
      ValueNotifier<AutoSummarySnapshot>(const AutoSummarySnapshot());
  Timer? _ticker;

  AutoSummarySnapshotBatcher? _batcher;

  @override
  AutoSummarySnapshot get current => _snapshot;

  @override
  ValueListenable<AutoSummarySnapshot> get state {
    return (_batcher ??= AutoSummarySnapshotBatcher(
      source: _notifier,
    )).listenable;
  }

  /// テストから時刻を制御する（クールダウン境界の検証用）。
  set now(int millis) => _now = millis;

  /// UI での可視デモ用に周期ティックを ON にする（既定は手動 [advance]）。
  void startTicker({Duration every = const Duration(milliseconds: 250)}) {
    _ticker?.cancel();
    _ticker = Timer.periodic(every, (_) => advance());
  }

  void _emit() {
    _notifier.value = _snapshot;
  }

  /// workId で重複排除しつつ tags を統合（全体件数は workId ユニーク）。
  static List<AutoSummaryItem> _normalize(List<AutoSummaryItem> seed) {
    final byId = <int, AutoSummaryItem>{};
    for (final it in seed) {
      final prev = byId[it.workId];
      if (prev == null) {
        byId[it.workId] = it;
      } else {
        final merged = <String>{...prev.tags, ...it.tags}.toList();
        byId[it.workId] = prev.copyWith(tags: merged);
      }
    }
    return byId.values.toList();
  }

  // ---------------------------------------------------------------------------
  // 実行命令（画面ボタン / 通知アクションが同一メソッドを呼ぶ）
  // ---------------------------------------------------------------------------

  bool _pauseRequested = false;
  bool _stopRequested = false;

  @override
  void runNow() {
    if (_snapshot.phase.isActive ||
        _snapshot.phase == AutoSummaryPhase.scheduled ||
        _snapshot.phase == AutoSummaryPhase.fetchingCandidates) {
      return; // 二重起動しない。
    }
    // 全件を待機に戻して開始（今回のキュー）。clear 前に正規化コピーを作る
    // （clear 後に _items を写すと空になり対象が消えるため）。
    final reset = _normalize(_items)
        .map((e) => e.copyWith(
              status: AutoSummaryItemStatus.waiting,
              errorReason: null,
            ))
        .toList();
    _items
      ..clear()
      ..addAll(reset);
    _snapshot = _snapshot.copyWith(
      phase: AutoSummaryPhase.fetchingCandidates,
      waitReason: AutoSummaryWaitReason.none,
      updatedAtMillis: _now,
      currentWorkId: null,
      workStage: AutoSummaryWorkStage.none,
      stopReason: null,
      items: List.of(_items),
    );
    _emit();
    // 候補取得完了 → 先頭を取り出して処理開始。
    _startNextOrFinish();
  }

  @override
  void pause() {
    if (_snapshot.phase == AutoSummaryPhase.paused ||
        _snapshot.phase.isTerminal ||
        _snapshot.phase == AutoSummaryPhase.disabled) {
      return;
    }
    _pauseRequested = true;
    _snapshot = _snapshot.copyWith(
      phase: AutoSummaryPhase.pausing,
      updatedAtMillis: _now,
    );
    _emit();
  }

  @override
  void resume() {
    if (_snapshot.phase != AutoSummaryPhase.paused) return;
    _pauseRequested = false;
    // 処理中だった段階に戻して続行。
    final back = _snapshot.currentWorkId != null
        ? AutoSummaryPhase.parsingBody
        : AutoSummaryPhase.fetchingCandidates;
    _snapshot = _snapshot.copyWith(
      phase: back,
      workStage: _snapshot.currentWorkId != null
          ? AutoSummaryWorkStage.bodyParse
          : AutoSummaryWorkStage.none,
      updatedAtMillis: _now,
    );
    _emit();
  }

  @override
  void stop() {
    if (_snapshot.phase.isTerminal ||
        _snapshot.phase == AutoSummaryPhase.disabled) {
      return;
    }
    _stopRequested = true;
    _snapshot = _snapshot.copyWith(
      phase: AutoSummaryPhase.finishing,
      stopReason: 'ユーザーが今回の処理を終了しました',
      updatedAtMillis: _now,
    );
    _emit();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    _batcher?.dispose();
    _batcher = null;
    _notifier.dispose();
  }

  // ---------------------------------------------------------------------------
  // 進行ロジック（決定論的。テストはこれを呼ぶ）
  // ---------------------------------------------------------------------------

  /// 1ステップ進行させる。停止/一時停止要求を優先的に反映する。
  void advance() {
    final phase = _snapshot.phase;

    // 停止処理中: 処理中の作品を待機に戻さず打ち切り、残り待機はスキップ扱いに
    // しない（=今回のキューは終了、保存済みは保持）。
    if (phase == AutoSummaryPhase.finishing) {
      _finish();
      return;
    }
    if (phase == AutoSummaryPhase.pausing) {
      _snapshot = _snapshot.copyWith(
        phase: AutoSummaryPhase.paused,
        updatedAtMillis: _now,
      );
      _emit();
      return;
    }
    if (_snapshot.phase != AutoSummaryPhase.fetchingCandidates &&
        !_snapshot.phase.isActive) {
      return; // 停止中/完了では進めない。
    }

    // 一時停止要求が進行中にきたら、次のステップ境界で pausing に入る。
    if (_pauseRequested && phase.isActive) {
      _snapshot = _snapshot.copyWith(
        phase: AutoSummaryPhase.pausing,
        updatedAtMillis: _now,
      );
      _emit();
      return;
    }

    // 終了要求が進行中にきたら、次の境界で finishing に入る。
    if (_stopRequested && phase.isActive) {
      _snapshot = _snapshot.copyWith(
        phase: AutoSummaryPhase.finishing,
        stopReason: 'ユーザーが今回の処理を終了しました',
        updatedAtMillis: _now,
      );
      _emit();
      return;
    }

    // クールダウン中: 時刻が進んだら解除して次へ。
    if (phase == AutoSummaryPhase.coolingDown) {
      if (_now >= _snapshot.cooldownUntilMillis) {
        _startNextOrFinish();
      }
      return;
    }

    // まだ現作品がいなければ次の待機を拾う（候補取得中／待ち受け）。
    final cur = _snapshot.currentWorkId;
    if (cur == null) {
      _startNextOrFinish();
      return;
    }

    switch (_snapshot.workStage) {
      case AutoSummaryWorkStage.none:
        _setStage(AutoSummaryWorkStage.bodyFetch);
        break;
      case AutoSummaryWorkStage.bodyFetch:
        _setStage(AutoSummaryWorkStage.modelPrepare);
        break;
      case AutoSummaryWorkStage.modelPrepare:
        _setStage(AutoSummaryWorkStage.bodyParse, chunk: 1);
        break;
      case AutoSummaryWorkStage.bodyParse:
        final cc = _snapshot.chunkCurrent;
        if (cc < chunkTotal) {
          _snapshot = _snapshot.copyWith(
            chunkCurrent: cc + 1,
            updatedAtMillis: _now,
          );
          _emit();
        } else {
          _setStage(AutoSummaryWorkStage.pointMerge);
        }
        break;
      case AutoSummaryWorkStage.pointMerge:
        _setStage(AutoSummaryWorkStage.save);
        break;
      case AutoSummaryWorkStage.save:
        _completeCurrent();
        break;
    }
  }

  void _setStage(AutoSummaryWorkStage stage, {int chunk = 0}) {
    final phase = switch (stage) {
      AutoSummaryWorkStage.bodyFetch => AutoSummaryPhase.fetchingBody,
      AutoSummaryWorkStage.modelPrepare => AutoSummaryPhase.preparingModel,
      AutoSummaryWorkStage.bodyParse => AutoSummaryPhase.parsingBody,
      AutoSummaryWorkStage.pointMerge => AutoSummaryPhase.integratingPoints,
      AutoSummaryWorkStage.save => AutoSummaryPhase.saving,
      AutoSummaryWorkStage.none => AutoSummaryPhase.fetchingCandidates,
    };
    _snapshot = _snapshot.copyWith(
      phase: phase,
      workStage: stage,
      chunkCurrent: chunk,
      chunkTotal: chunk == 0 ? 0 : chunkTotal,
      updatedAtMillis: _now,
    );
    _emit();
  }

  /// 次の待機作品を処理中に遷移。無ければ完了判定。
  void _startNextOrFinish() {
    AutoSummaryItem? next;
    int idx = -1;
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].status == AutoSummaryItemStatus.waiting) {
        next = _items[i];
        idx = i;
        break;
      }
    }
    if (next == null) {
      // 全部処理済み → 終了フェーズへ。
      _snapshot = _snapshot.copyWith(
        phase: AutoSummaryPhase.finishing,
        updatedAtMillis: _now,
      );
      _emit();
      _finish();
      return;
    }

    final willSkip = _skipWorkIds.contains(next.workId);
    final willFail = _failWorkIds.contains(next.workId);
    if (willSkip) {
      _items[idx] = next.copyWith(
        status: AutoSummaryItemStatus.skipped,
        errorReason: '既存の有効キャッシュあり',
        updatedAtMillis: _now,
      );
      _snapshot = _snapshot.copyWith(
        items: List.of(_items),
        updatedAtMillis: _now,
      );
      _emit();
      _startNextOrFinish();
      return;
    }

    _items[idx] = next.copyWith(
      status: AutoSummaryItemStatus.processing,
      updatedAtMillis: _now,
    );
    _snapshot = _snapshot.copyWith(
      items: List.of(_items),
      phase: AutoSummaryPhase.fetchingBody,
      currentWorkId: next.workId,
      currentWorkTitle: next.title.isEmpty ? '作品 ${next.workId}' : next.title,
      currentTag: next.tags.isNotEmpty ? next.tags.first : null,
      workStage: AutoSummaryWorkStage.bodyFetch,
      chunkCurrent: 0,
      chunkTotal: 0,
      modelLabel: _snapshot.modelLabel ?? 'fake-model',
      backendName: _snapshot.backendName ?? 'CPU',
      // 失敗予定の作品は、処理を進めた末尾で失敗させる（下方で判定）。
      updatedAtMillis: _now,
    );
    _emit();
    if (willFail) {
      _pendingFailWorkId = next.workId;
    }
  }

  int? _pendingFailWorkId;

  /// 現作品を保存済み（or 失敗）で確定し、クールダウン or 次に進む。
  void _completeCurrent() {
    final cur = _snapshot.currentWorkId;
    if (cur == null) {
      _startNextOrFinish();
      return;
    }
    final fail = _pendingFailWorkId == cur;
    final idx = _items.indexWhere((e) => e.workId == cur);
    if (idx >= 0) {
      _items[idx] = _items[idx].copyWith(
        status: fail
            ? AutoSummaryItemStatus.failed
            : AutoSummaryItemStatus.saved,
        errorReason: fail ? 'モデル生成に失敗しました' : null,
        updatedAtMillis: _now,
      );
    }
    _pendingFailWorkId = null;
    _snapshot = _snapshot.copyWith(
      items: List.of(_items),
      workStage: AutoSummaryWorkStage.none,
      chunkCurrent: 0,
      chunkTotal: 0,
      currentWorkId: null,
      updatedAtMillis: _now,
    );
    _emit();

    if (_cooldownSeconds > 0) {
      _snapshot = _snapshot.copyWith(
        phase: AutoSummaryPhase.coolingDown,
        cooldownUntilMillis: _now + _cooldownSeconds * 1000,
        updatedAtMillis: _now,
      );
      _emit();
    } else {
      _startNextOrFinish();
    }
  }

  void _finish() {
    _pauseRequested = false;
    _stopRequested = false;
    _snapshot = _snapshot.resolvedFinished(nowMillis: _now);
    _emit();
  }
}
