// Phase 9-B2/B2-4+5: FGS TaskHandler — 自動要約の実行主体。
//
// このハンドラは flutter_foreground_task が生成する専用 FlutterEngine 内で動く。
// 推論・DB・ネットワークの全操作はこのエンジン内でのみ行う（所有者統一）。
// UI isolate との通信は sendDataToMain / onReceiveData のみ（Map スナップショット）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'auto_summary_controller.dart';
import 'auto_summary_real_ports.dart';
import 'auto_summary_repository.dart';
import 'auto_summary_service.dart';
import 'auto_summary_settings.dart';
import 'auto_summary_snapshot.dart';
import 'fgs_lifecycle_service.dart';
import 'llm_run_arbiter.dart';
import 'llm_summary_service.dart';

/// 通知ボタン ID。
const String kBtnPauseResume = 'auto_summary_pause_resume';
const String kBtnStop = 'auto_summary_stop';

/// UI→Task へのコマンドキー（文字列コマンド）。
const String kCmdRun = 'run';
const String kCmdPause = 'pause';
const String kCmdResume = 'resume';
const String kCmdStopAuto = 'stop_auto';
const String kCmdStopService = 'stop_service';

/// UI→Task へのコマンドキー（Map コマンドの type 値）。
const String kCmdManualGenerate = 'manual_generate';
const String kCmdManualCancel = 'manual_cancel';

/// Task→UI へのデータキー。
const String kKeySnapshot = 'snapshot';
const String kKeyManualEvent = 'manual_event';
const String kKeyShutdown = 'shutdown';

/// Task 内部でアイドル解放を発火させる自己コマンド（onReceiveData 経由でテスト可能）。
const String kCmdIdleRelease = 'idle_release';

/// run 完走後のアイドル解放までの待機時間（バグ修正 #2）。
/// デバッグビルドでは検証しやすいよう短縮する。kReleaseMode で切替。
final Duration kAutoSummaryIdleRelease = kDebugMode
    ? const Duration(seconds: 60)
    : const Duration(minutes: 5);

/// 通知更新の最小間隔（§3-D: ≥1s）。
const Duration kNotificationThrottle = Duration(seconds: 1);

/// 自動要約の FGS TaskHandler。
class AutoSummaryTaskHandler extends TaskHandler {
  AutoSummaryService? _service;
  LlmRunArbiter? _arbiter;
  AutoSummarySettings _settings = const AutoSummarySettings();
  Timer? _notifyTimer;
  Timer? _idleTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _paused = false;
  int _generation = 0;
  bool _stopping = false;

  /// テスト用: true のときアイドル解放で実際に stopService を呼ばない
  /// （FakeAsync では Dart タイマーのみ進み、プラットフォームチャネルは
  /// 解決しないため待てない）。本番（kDebugMode）では false。
  @visibleForTesting
  bool idleReleaseStopForTest = false;

  // ---------------------------------------------------------------------------
  // lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[AutoSummaryTask] onStart(starter: ${starter.name})');
    _generation++;
    _settings = await AutoSummarySettings.load();
    final repo = AutoSummaryRepository();
    // 前回セッションの stale 復旧。
    await repo.reconcileStaleRunning();

    // 推論仲裁者（LocalLlmService の唯一の所有者）。
    _arbiter = LlmRunArbiter();
    _arbiter!.onManualEvent = _onManualEvent;

    final ports = createRealPorts(
      settings: _settings,
      repository: repo,
      arbiter: _arbiter!,
    );
    _service = AutoSummaryService(
      settings: _settings,
      ports: ports,
      runId: 'auto-${DateTime.now().millisecondsSinceEpoch}',
    );
    _stopping = false;

    // 状態変化を通知 + UI に送信。
    _service!.state.addListener(_onStateChanged);

    // READY を UI に通知（自動開始は kCmdRun を受けてから）。
    FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      kKeyReady: kValueReady,
      kKeyGeneration: _generation,
    });
    debugPrint('[AutoSummaryTask] READY sent (gen=$_generation)');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // ForegroundTaskEventAction.nothing() を使うので呼ばれない。
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[AutoSummaryTask] onDestroy(isTimeout: $isTimeout)');
    _notifyTimer?.cancel();
    _idleTimer?.cancel();
    _service?.dispose();
    _service = null;
    await _arbiter?.disposeModel();
    _arbiter = null;
  }

  // ---------------------------------------------------------------------------
  // communication: UI → Task
  // ---------------------------------------------------------------------------

  @override
  void onReceiveData(Object data) {
    if (data is String) {
      switch (data) {
        case kCmdRun:
          // 新しい要求 → アイドル解放タイマーを中止（モデル再利用）。
          _cancelIdleTimer();
          unawaited(_service?.runNow() ?? Future<bool>.value(false));
          break;
        case kCmdPause:
          _service?.pause();
          _paused = true;
          break;
        case kCmdResume:
          _service?.resume();
          _paused = false;
          break;
        case kCmdStopAuto:
          _service?.stop();
          break;
        case kCmdStopService:
          _stopServiceSafe();
          break;
        case kCmdIdleRelease:
          _onIdleTimerFired();
          break;
      }
      return;
    }
    if (data is Map) {
      final type = data['type'] as String?;
      switch (type) {
        case kCmdManualGenerate:
          _handleManualGenerate(data);
          break;
        case kCmdManualCancel:
          final requestId = data['requestId'] as String? ?? '';
          _arbiter?.cancelManual(requestId);
          break;
      }
    }
  }

  void _handleManualGenerate(Map data) {
    // 手動要求も活動とみなしアイドル解放を中止（モデル再利用）。
    _cancelIdleTimer();
    final requestId = data['requestId'] as String? ?? '';
    final workId = data['workId'] as int? ?? 0;
    final title = data['title'] as String? ?? '';
    final tags = (data['tags'] as List?)?.cast<String>() ?? [];
    final body = data['body'] as String? ?? '';
    final description = data['description'] as String? ?? '';
    final modelLabel = data['modelLabel'] as String? ?? '';

    final req = ManualSummaryRequest(
      requestId: requestId,
      workId: workId,
      title: title,
      tags: tags,
      body: body,
      description: description,
      modelLabel: modelLabel,
    );
    _arbiter?.submitManual(req);
  }

  Future<void> _stopServiceSafe() async {
    // 二重停止防止（terminal 直後に手動停止と競合した場合）。
    if (_stopping) return;
    _stopping = true;
    _idleTimer?.cancel();
    _service?.stop();
    await _arbiter?.waitForIdle();
    // UI 側に「シャットダウン」を通知し _ready をリセットして再起動可能にする。
    FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      kKeyShutdown: true,
      kKeyGeneration: _generation,
    });
    await FlutterForegroundTask.stopService();
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// run が terminal に入ったらアイドル解放タイマーを開始（既に停止中なら何もしない）。
  void _scheduleIdleRelease() {
    if (_stopping) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(kAutoSummaryIdleRelease, () {
      // 発火は onReceiveData 経由に一本化（テストでも同じ経路を通す）。
      onReceiveData(kCmdIdleRelease);
    });
    debugPrint(
      '[AutoSummaryTask] idle release scheduled in '
      '${kAutoSummaryIdleRelease.inSeconds}s',
    );
  }

  void _onIdleTimerFired() {
    _idleTimer = null;
    debugPrint('[AutoSummaryTask] idle release fired -> stopping service');
    if (idleReleaseStopForTest) return;
    unawaited(_stopServiceSafe());
  }

  void _onManualEvent(
    String requestId,
    ManualRequestStatus status, {
    String? token,
    LlmSummaryResult? result,
    String? error,
  }) {
FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      kKeyManualEvent: true,
      'requestId': requestId,
      'status': status.name,
'token': ?token,
      'result': ?result?.toMap(),
      'error': ?error,
    });
  }

  // ---------------------------------------------------------------------------
  // notification buttons
  // ---------------------------------------------------------------------------

  @override
  void onNotificationButtonPressed(String id) {
    switch (id) {
      case kBtnPauseResume:
        if (_paused) {
          _service?.resume();
          _paused = false;
        } else {
          _service?.pause();
          _paused = true;
        }
        break;
      case kBtnStop:
        _service?.stop();
        break;
    }
  }

  @override
  void onNotificationPressed() {
    // タップ→進捗画面へ遷移（notificationInitialRoute で設定済み）。
  }

  // ---------------------------------------------------------------------------
  // state → notification + UI
  // ---------------------------------------------------------------------------

  void _onStateChanged() {
    final s = _service?.current;
    if (s == null) return;

    // UI に送信（シリアライズ可能な Map のみ）。
    FlutterForegroundTask.sendDataToMain(<String, dynamic>{
      kKeySnapshot: s.toMap(),
    });

    // run 完走（terminal）→ アイドル解放タイマーを開始。
    if (s.phase.isTerminal) {
      _scheduleIdleRelease();
    }

    // 通知更新（スロットル付き）。
    final now = DateTime.now();
    if (now.difference(_lastNotify) < kNotificationThrottle &&
        !s.phase.isTerminal) {
      _notifyTimer?.cancel();
      _notifyTimer = Timer(kNotificationThrottle, () => _updateNotification(s));
      return;
    }
    _updateNotification(s);
  }

  void _updateNotification(AutoSummarySnapshot s) {
    _lastNotify = DateTime.now();
    _notifyTimer?.cancel();
    _notifyTimer = null;

    final label = autoSummaryStatusLabel(s);
    final counts =
        '${s.savedCount}保存 / ${s.processingCount}処理中 / ${s.waitingCount}待ち / ${s.failedCount}失敗';
    final body = '$label\n$counts';

    final pauseResumeText = _paused ? '再開' : '一時停止';
    FlutterForegroundTask.updateService(
      notificationTitle: 'PixEmber 自動要約',
      notificationText: body,
      notificationButtons: [
        NotificationButton(id: kBtnPauseResume, text: pauseResumeText),
        const NotificationButton(id: kBtnStop, text: '終了'),
      ],
    );
  }
}

/// トップレベルコールバック（FGS エンジン起動時に呼ばれる）。
@pragma('vm:entry-point')
void autoSummaryTaskCallback() {
  debugPrint('[AutoSummaryTask] callback reached (engine bootstrapping)');
  FlutterForegroundTask.setTaskHandler(AutoSummaryTaskHandler());
}
