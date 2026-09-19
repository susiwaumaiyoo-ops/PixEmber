// Phase 9-B2/B2-3: 実際の自動要約実行サービス（オーケストレーション）。
//
// 責務（§5）:
//   条件判定 → タグ巡回 → ページ単位候補取得 → 重複/ミュート/既存キャッシュ確認
//   → 本文取得 → 生成 → 最終保存 → クールダウン → 次。
//
// 設計方針（ユーザー承認構成）:
// - 正本は AutoSummarySnapshot 1つ。件数は items から毎回導出し独立カウンタを持たない。
// - UI isolate は [AutoSummaryController] 経由で state を購読するだけ。このクラスの
//   runNow/pause/resume/stop を通知アクションと画面ボタンが同一に呼ぶ。
// - 推論・DB・ネットワークへの接触はすべて [AutoSummaryPorts] の関数に集約する。
//   → B2-4 でこのサービスごと FGS TaskHandler 側 FlutterEngine に移す際、実装の
//     組み替えだけで本オーケストレーションは不変に保てる。
// - 一時停止/終了は作品境界で協調的に反映する（ネイティブ生成の途中取消＝
//   service.cancel() による中断は B2-4 の所有権統合で対応。ここでの途中再開は
//   現在作品を先頭から再処理する＝保存済み作品は再生成しない）。
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auto_summary_controller.dart';
import 'auto_summary_settings.dart';
import 'auto_summary_snapshot.dart';

/// 1ページの候補取得結果（ページ総数は返らない = §2-C 準拠で推測しない）。
class AutoSummaryCandidatePage {
  const AutoSummaryCandidatePage({required this.items, required this.hasNext});

  final List<AutoSummaryItem> items;
  final bool hasNext;
}

/// 実行サービスが外部（ネットワーク/DB/推論）へ接触するためのポート群。
///
/// すべて注入可能。本番では実サービスへ結び、テストではスタブで駆動する。
class AutoSummaryPorts {
  const AutoSummaryPorts({
    required this.fetchCandidates,
    required this.resolveBody,
    required this.isCachedValid,
    required this.generate,
    required this.saveSummary,
    required this.prepareModel,
    required this.fingerprintOf,
    this.isMuted = _neverMuted,
    this.checkConditions = _alwaysReady,
    this.persist,
    this.reloadSettings,
    this.getSummarizedWorkIds = _noSummarized,
    this.requestGap = const Duration(milliseconds: 5000),
  });

  /// タグとページ番号（0起点）から1ページの候補を返す（searchNovel 相当）。
  /// 実結線側ではこのページ番号を API の offset（0,30,60…）へ変換する。
  final Future<AutoSummaryCandidatePage> Function(String tag, int page)
  fetchCandidates;

  /// 作品本文を解決（キャッシュ→取得）。取得不能・空は null。
  final Future<String?> Function(int workId) resolveBody;

  /// 同一 workId × 指紋 × モデルで有効キャッシュが存在するか。
  final Future<bool> Function(int workId, String fingerprint) isCachedValid;

  /// 生成（LlmSummaryService.generate 相当）。onStage は (current,total) を
  /// チャンク進捗として呼ぶ。戻り値は結果（保存は saveSummary が行う）。
  final Future<void> Function(
    int workId,
    String title,
    List<String> tags,
    String body,
    void Function(int current, int total) onStage,
  )
  generate;

  /// 生成結果を最終保存（キャッシュ有効性＝手動と同一）。
  final Future<void> Function(int workId) saveSummary;

  /// セッション冒頭で1度だけモデルをロード（M5: 同時1モデル）。
  /// 失敗時は例外を投げる（呼び出し側で modelMissing 等に畳む）。
  final Future<AutoSummaryModelInfo> Function() prepareModel;

  /// 指紋計算（既定は LlmSummaryService.computeSourceFingerprint と同一手順）。
  final String Function(String title, List<String> tags, String body)
  fingerprintOf;

  /// ミュート判定（workId / tags）。既定は常に false。
  final bool Function(int workId, List<String> tags) isMuted;

  /// 実行条件の判定。待機理由を返せば待機、null なら実行可。
  final Future<AutoSummaryWaitReason?> Function() checkConditions;

  /// スナップショットの永続化フック（§6-C、作品境界で呼ぶ）。未設定なら無視。
  final Future<void> Function(AutoSummarySnapshot snapshot)? persist;

  /// 次ページ要求前に空ける間隔（レート制限 §5）。テストではゼロにする。
  final Duration requestGap;

  /// 設定の再読込（run 境界で呼ぶ）。未設定なら null（＝前回設定を維持）。
  /// FGS は別 isolate のため、UI の save() を反映するにはプラットフォームから
  /// 再読込する必要がある（AutoSummarySettings.load() 内部で prefs.reload()）。
  final Future<AutoSummarySettings?> Function()? reloadSettings;

  /// 既に要約が保存されている workId 集合（軽量な事前除外用・バグ修正 #3）。
  /// _buildQueue の候補ループで muted と同じ段階で除外し、上限枠を
  /// 「未処理作品」に届かせる。厳密なキャッシュ有効性（指紋・モデル）は
  /// 従来通り _processItem の isCachedValid で担保する。
  final Future<Set<int>> Function() getSummarizedWorkIds;

  static bool _neverMuted(int workId, List<String> tags) => false;

  static Future<Set<int>> _noSummarized() async => const <int>{};

  static Future<AutoSummaryWaitReason?> _alwaysReady() async => null;
}

/// モデル準備完了時に得られる表示メタ情報。
class AutoSummaryModelInfo {
  const AutoSummaryModelInfo({this.modelLabel, this.backendName});

  final String? modelLabel;
  final String? backendName;
}

/// 本文が短すぎてスキップする閾値（§5）。
const int kAutoSummaryMinBodyChars = 100;

/// タグあたりの候補取得ページ上限（無限ページング防止 §5）。
const int kAutoSummaryMaxPagesPerTag = 5;

/// 自動要約の実行サービス。[AutoSummaryController] を実装する正本保持者。
class AutoSummaryService implements AutoSummaryController {
  AutoSummaryService({
    required AutoSummarySettings settings,
    required AutoSummaryPorts ports,
    String runId = 'auto-run',
    int Function()? clock,
  }) : _settings = settings,
       _ports = ports,
       _runId = runId,
       _clock = clock ?? _systemClock {
    _snapshot = AutoSummarySnapshot(
      runId: _runId,
      startedAtMillis: _clock(),
      updatedAtMillis: _clock(),
      phase: AutoSummaryPhase.disabled,
    );
    _notifier.value = _snapshot;
  }

  // 設定は run 境界で再読込・適用する（バグ修正 #1: 常駐 FGS が起動時の
  // 古い maxPerSession 等を使い続けないため）。_settings は可変。
  AutoSummarySettings _settings;
  final AutoSummaryPorts _ports;
  final String _runId;
  final int Function() _clock;

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  final ValueNotifier<AutoSummarySnapshot> _notifier =
      ValueNotifier<AutoSummarySnapshot>(const AutoSummarySnapshot());
  AutoSummarySnapshotBatcher? _batcher;

  late AutoSummarySnapshot _snapshot;
  final List<AutoSummaryItem> _items = <AutoSummaryItem>[];

  bool _running = false;
  bool _stopRequested = false;
  bool _pauseRequested = false;

  Completer<void>? _done;

  /// 実行中のループ完了を待てるようにする（テスト用）。未起動なら即完了。
  @visibleForTesting
  Future<void> get finished => (_done?.future ?? Future<void>.value());

  AutoSummaryModelInfo? _model;

  @override
  AutoSummarySnapshot get current => _snapshot;

  @override
  ValueListenable<AutoSummarySnapshot> get state {
    return (_batcher ??= AutoSummarySnapshotBatcher(
      source: _notifier,
    )).listenable;
  }

  // ---------------------------------------------------------------------------
  // 実行命令（画面ボタン / 通知アクションが同一メソッドを呼ぶ）
  // ---------------------------------------------------------------------------

  @override
  Future<bool> runNow() async {
    if (_running) return false; // 二重起動防止（§3-B）。
    // 同期プロローグで _running/_done を確定させてから起動する（finished の
    // 同期可視性を保つ）。設定の再読込は _run() 冒頭で行う。
    _running = true;
    _stopRequested = false;
    _pauseRequested = false;
    _done = Completer<void>();
    unawaited(
      _run().whenComplete(() {
        if (!(_done?.isCompleted ?? true)) _done!.complete();
      }),
    );
    return true;
  }

  /// ports.reloadSettings で再読込し、次 run 用の設定として保持する。
  /// 再読込不可（null）は据え置き。安全側: 実行中は絶対に呼ばない（runNow 冒頭）。
  Future<void> applySettingsFromReload() async {
    final reload = _ports.reloadSettings;
    if (reload == null) return;
    final fresh = await reload();
    if (fresh != null) {
      _settings = fresh;
      debugPrint(
        '[AutoSummary] applied settings: '
        'maxPerSession=${fresh.maxPerSession} '
        'chargeOnly=${fresh.chargeOnly} wifiOnly=${fresh.wifiOnly} '
        'cooldown=${fresh.cooldownSeconds}s tags=${fresh.tags.length}',
      );
    } else {
      debugPrint('[AutoSummary] settings reload returned null (keep current)');
    }
  }

  @override
  void pause() {
    if (!_running) return;
    if (_snapshot.phase == AutoSummaryPhase.paused) return;
    if (_snapshot.phase.isTerminal) return;
    _pauseRequested = true;
  }

  @override
  void resume() {
    if (_snapshot.phase != AutoSummaryPhase.paused) return;
    _pauseRequested = false;
    _emit(
      _snapshot.copyWith(
        phase: AutoSummaryPhase.parsingBody,
        workStage: AutoSummaryWorkStage.bodyFetch,
      ),
    );
  }

  @override
  void stop() {
    if (!_running) return;
    if (_snapshot.phase.isTerminal) return;
    _stopRequested = true;
    _emit(
      _snapshot.copyWith(
        phase: AutoSummaryPhase.finishing,
        stopReason: '手動で終了しました',
      ),
    );
  }

  @override
  void dispose() {
    _batcher?.dispose();
    _notifier.dispose();
  }

  // ---------------------------------------------------------------------------
  // 本体ループ
  // ---------------------------------------------------------------------------

  Future<void> _run() async {
    try {
      _resetForNewRun();
      // run 開始前に設定を再読込して適用（次の run から反映・稼働中は干渉しない）。
      // _buildQueue / checkConditions が新しい _settings を参照するよう、
      // 候補構築より前に適用する（バグ修正 #1）。
      await applySettingsFromReload();

      // 1) 条件判定（§5）。待機理由があれば条件待ちで一旦停止（再開は B2-5）。
      final wait = await _ports.checkConditions();
      if (wait != null) {
        _emit(
          _snapshot.copyWith(
            phase: AutoSummaryPhase.waitingCondition,
            waitReason: wait,
          ),
        );
        await _persistNow();
        return;
      }

      // 2) タグ巡回 → ページ単位候補取得 → 重複/ミュート/キャッシュ除外。
      _emit(_snapshot.copyWith(phase: AutoSummaryPhase.fetchingCandidates));
      await _buildQueue();

      if (_items.isEmpty) {
        // 今回のキューが空 = 候補なし or 全件スキップ。総数未知は §2-C で表さない。
        _finish();
        return;
      }

      // 3) モデルを1度だけ準備（M5: 同時1モデル）。失敗は modelMissing 扱いで終了。
      _emit(
        _snapshot.copyWith(
          phase: AutoSummaryPhase.preparingModel,
          workStage: AutoSummaryWorkStage.modelPrepare,
        ),
      );
      try {
        _model = await _ports.prepareModel();
        _emit(
          _snapshot.copyWith(
            modelLabel: _model?.modelLabel,
            backendName: _model?.backendName,
          ),
        );
      } catch (_) {
        _emit(
          _snapshot.copyWith(
            phase: AutoSummaryPhase.error,
            stopReason: 'モデルを準備できませんでした',
          ),
        );
        await _persistNow();
        return;
      }

      // 4) キューを直列処理。
      for (var i = 0; i < _items.length; i++) {
        if (_stopRequested) {
          _finish();
          return;
        }
        await _waitForPauseIfNeeded();
        if (_stopRequested) {
          _finish();
          return;
        }
        await _applyCooldownGate();
        if (_stopRequested) {
          _finish();
          return;
        }
        final done = await _processItem(i);
        if (done == _ItemOutcome.aborted) {
          _finish();
          return;
        }
      }

      _finish();
    } catch (e) {
      _emit(
        _snapshot.copyWith(
          phase: AutoSummaryPhase.error,
          stopReason: _shortReason(e),
        ),
      );
      await _persistNow();
    } finally {
      _running = false;
    }
  }

  void _resetForNewRun() {
    final now = _clock();
    _items
      ..clear()
      ..addAll(<AutoSummaryItem>[]);
    _model = null;
    _snapshot = AutoSummarySnapshot(
      runId: _runId,
      startedAtMillis: now,
      updatedAtMillis: now,
      phase: AutoSummaryPhase.scheduled,
      items: const [],
      tagStats: const [],
    );
    _notifier.value = _snapshot;
  }

  /// タグ巡回・ページ取得・重複/ミュート除外でキューを構築する。
  /// 全体件数は workId ユニーク（§2-A）。maxPerSession 到達で以降は待機数に含めず
  /// 「追加候補あり」として示す（§2-C）。
  Future<void> _buildQueue() async {
    final tags = _settings.tags;
    final byId = <int, AutoSummaryItem>{};
    final offsets = <String, int>{for (final t in tags) t: 0};
    final pages = <String, int>{for (final t in tags) t: 0};
    final exhausted = <String>{};
    final stats = <String, AutoSummaryTagStat>{
      for (final t in tags) t: AutoSummaryTagStat(tag: t),
    };

    var hasMore = false;
    // 既に要約済みの workId を軽量に事前除外（バグ修正 #3）。date_desc の
    // 先頭が毎回キャッシュ済みだと上限枠が埋まって未処理に届かないため。
    final summarized = await _ports.getSummarizedWorkIds();
    var skippedCached = 0;
    // タグをラウンドロビンで1ページずつ拾い、maxPerSession 件集まったら停止。
    while (byId.length < _settings.maxPerSession) {
      var progressed = false;
      for (final t in tags) {
        if (exhausted.contains(t)) continue;
        if (byId.length >= _settings.maxPerSession) {
          hasMore = true;
          break;
        }
        progressed = true;
        final page = await _ports.fetchCandidates(t, offsets[t]!);
        offsets[t] = offsets[t]! + 1;
        pages[t] = pages[t]! + 1;
        var tagChecked = stats[t]!.candidatesChecked;
        var tagExisting = stats[t]!.existingValid;
        var tagHasMore = page.hasNext;
        for (final cand in page.items) {
          tagChecked++;
          if (_ports.isMuted(cand.workId, cand.tags)) continue;
          if (summarized.contains(cand.workId)) {
            // 生成済みは上限枠を消費させずスキップ（未処理を先に出す）。
            skippedCached++;
            continue;
          }
          if (byId.length >= _settings.maxPerSession) {
            hasMore = true; // 上限到達で以降は待機数に含めない（§2-C）。
            break;
          }
          final prev = byId[cand.workId];
          if (prev != null) {
            // 別タグで既に拾った → タグを統合（全体件数は workId ユニーク）。
            byId[cand.workId] = prev.copyWith(
              tags: <String>{...prev.tags, ...cand.tags, t}.toList(),
            );
            continue;
          }
          byId[cand.workId] = AutoSummaryItem(
            workId: cand.workId,
            tags: <String>{...cand.tags, t}.toList(),
            title: cand.title,
          );
        }
        // ページ上限 or 次無しで exhaustion 判定（無限ページング防止）。
        final notMore =
            !page.hasNext || pages[t]! >= kAutoSummaryMaxPagesPerTag;
        if (notMore) {
          exhausted.add(t);
          tagHasMore = false;
        } else {
          hasMore = true;
        }
        stats[t] = stats[t]!.copyWith(
          candidatesChecked: tagChecked,
          existingValid: tagExisting,
          hasMoreCandidates: tagHasMore,
        );
        await _sleep(_ports.requestGap);
      }
      if (!progressed) break; // 全タグ枯渇。
      if (exhausted.length >= tags.length) break;
    }

    if (skippedCached > 0) {
      debugPrint(
        '[AutoSummary] skipped $skippedCached cached items during queue build',
      );
    }

    _items
      ..clear()
      ..addAll(byId.values);
    _snapshot = _snapshot.copyWith(
      items: List<AutoSummaryItem>.from(_items),
      tagStats: stats.values.toList(),
      candidatesFetched: byId.length,
      hasMoreCandidates: hasMore,
    );
    _emit(_snapshot);
  }

  /// 1作品を処理して結果を返す。
  Future<_ItemOutcome> _processItem(int index) async {
    final item = _items[index];
    if (_stopRequested) return _ItemOutcome.aborted;

    _setItem(index, AutoSummaryItemStatus.processing);
    _emit(
      _snapshot.copyWith(
        currentWorkId: item.workId,
        currentWorkTitle: item.title,
        currentTag: item.tags.isNotEmpty
            ? item.tags.first
            : _snapshot.currentTag,
        phase: AutoSummaryPhase.fetchingBody,
        workStage: AutoSummaryWorkStage.bodyFetch,
        chunkCurrent: 0,
        chunkTotal: 0,
      ),
    );

    // 本文解決。
    final body = await _ports.resolveBody(item.workId);
    if (_stopRequested) return _ItemOutcome.aborted;
    if (body == null || body.trim().length < kAutoSummaryMinBodyChars) {
      _setItem(
        index,
        AutoSummaryItemStatus.failed,
        reason: '本文を取得できないためスキップしました',
      );
      await _persistNow();
      return _ItemOutcome.continueNext;
    }

    // 有効キャッシュ確認（手動と同一の有効性＝workId だけではない）。
    // maxPerSession は「今回キューに入れた作品数」の上限。キャッシュヒット
    // （existing→saved 計上）もキュー済み＝上限を消費する（実生成件数のみで
    // 数えない）。よって saved + skipped + failed の合計 ≦ maxPerSession。
    final fp = _ports.fingerprintOf(item.title, item.tags, body);
    if (await _ports.isCachedValid(item.workId, fp)) {
      _markExistingSaved(index);
      await _persistNow();
      return _ItemOutcome.continueNext;
    }

    // 生成。チャンク進捗は onStage で反映（本文解析段階）。
    _emit(
      _snapshot.copyWith(
        phase: AutoSummaryPhase.parsingBody,
        workStage: AutoSummaryWorkStage.bodyParse,
      ),
    );
    try {
      await _ports.generate(item.workId, item.title, item.tags, body, (
        current,
        total,
      ) {
        _emit(_snapshot.copyWith(chunkCurrent: current, chunkTotal: total));
      });
    } on _GenerateAborted {
      // 生成途中の停止要求（将来 cancel() 統合用）。
      return _ItemOutcome.aborted;
    } catch (e) {
      _setItem(index, AutoSummaryItemStatus.failed, reason: _shortReason(e));
      await _persistNow();
      return _ItemOutcome.continueNext;
    }
    if (_stopRequested) return _ItemOutcome.aborted;

    // 要点統合 → 最終保存（保存済みにするのはここだけ §2-A）。
    _emit(
      _snapshot.copyWith(
        phase: AutoSummaryPhase.integratingPoints,
        workStage: AutoSummaryWorkStage.pointMerge,
      ),
    );
    _emit(
      _snapshot.copyWith(
        phase: AutoSummaryPhase.saving,
        workStage: AutoSummaryWorkStage.save,
      ),
    );
    await _ports.saveSummary(item.workId);
    _setItem(index, AutoSummaryItemStatus.saved);
    _bumpTagGenerated(item);
    await _persistNow();

    // クールダウン設定。
    if (_settings.cooldownSeconds > 0) {
      final until = _clock() + _settings.cooldownSeconds * 1000;
      _emit(
        _snapshot.copyWith(
          phase: AutoSummaryPhase.coolingDown,
          workStage: AutoSummaryWorkStage.none,
          cooldownUntilMillis: until,
          chunkCurrent: 0,
          chunkTotal: 0,
        ),
      );
    }
    return _ItemOutcome.continueNext;
  }

  Future<void> _applyCooldownGate() async {
    if (_snapshot.cooldownUntilMillis <= 0) return;
    while (_clock() < _snapshot.cooldownUntilMillis) {
      if (_stopRequested) return;
      await _waitForPauseIfNeeded();
      await _sleep(const Duration(milliseconds: 250));
    }
    _emit(_snapshot.copyWith(cooldownUntilMillis: 0));
  }

  Future<void> _waitForPauseIfNeeded() async {
    if (!_pauseRequested) return;
    _emit(
      _snapshot.copyWith(
        phase: AutoSummaryPhase.paused,
        workStage: AutoSummaryWorkStage.none,
      ),
    );
    await _persistNow();
    while (_pauseRequested && !_stopRequested) {
      await _sleep(const Duration(milliseconds: 200));
    }
    if (_stopRequested) return;
    _emit(_snapshot.copyWith(phase: AutoSummaryPhase.fetchingBody));
  }

  void _finish() {
    final now = _clock();
    final resolved = _snapshot.resolvedFinished(nowMillis: now);
    _emit(
      resolved.copyWith(
        currentWorkId: null,
        currentWorkTitle: null,
        workStage: AutoSummaryWorkStage.none,
        chunkCurrent: 0,
        chunkTotal: 0,
        cooldownUntilMillis: 0,
      ),
    );
    unawaited(_persistNow());
  }

  // ---------------------------------------------------------------------------
  // items / tagStats 更新（件数は常に items から導出）
  // ---------------------------------------------------------------------------

  void _setItem(int index, AutoSummaryItemStatus status, {String? reason}) {
    _items[index] = _items[index].copyWith(
      status: status,
      errorReason: status == AutoSummaryItemStatus.saved
          ? null
          : (reason ?? _items[index].errorReason),
      updatedAtMillis: _clock(),
    );
    _snapshot = _snapshot.copyWith(items: List<AutoSummaryItem>.from(_items));
  }

  void _markExistingSaved(int index) {
    _setItem(index, AutoSummaryItemStatus.saved);
    final item = _items[index];
    _snapshot = _snapshot.copyWith(
      tagStats: [
        for (final t in _snapshot.tagStats)
          item.tags.contains(t.tag)
              ? t.copyWith(existingValid: t.existingValid + 1)
              : t,
      ],
    );
  }

  void _bumpTagGenerated(AutoSummaryItem item) {
    _snapshot = _snapshot.copyWith(
      tagStats: [
        for (final t in _snapshot.tagStats)
          item.tags.contains(t.tag)
              ? t.copyWith(generatedSaved: t.generatedSaved + 1)
              : t,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // emit / persist / sleep
  // ---------------------------------------------------------------------------

  void _emit(AutoSummarySnapshot next) {
    _snapshot = next.copyWith(updatedAtMillis: _clock());
    _notifier.value = _snapshot;
  }

  Future<void> _persistNow() async {
    final persist = _ports.persist;
    if (persist == null) return;
    try {
      await persist(_snapshot);
    } catch (_) {
      // 永続化失敗は実行を止めない（次回 reconcile で復元）。
    }
  }

  Future<void> _sleep(Duration d) =>
      d <= Duration.zero ? Future<void>.value() : Future<void>.delayed(d);

  static String _shortReason(Object e) {
    final s = e.toString().split('\n').first.trim();
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }
}

/// 生成途中中断のマーカー（将来の cancel() 統合用）。
class _GenerateAborted implements Exception {
  const _GenerateAborted();
}

enum _ItemOutcome { continueNext, aborted }
