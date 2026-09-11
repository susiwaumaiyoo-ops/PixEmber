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

/// 通知更新の最小間隔（§3-D: ≥1s）。
const Duration kNotificationThrottle = Duration(seconds: 1);

/// 自動要約の FGS TaskHandler。
class AutoSummaryTaskHandler extends TaskHandler {
  AutoSummaryService? _service;
  LlmRunArbiter? _arbiter;
  AutoSummarySettings _settings = const AutoSummarySettings();
  Timer? _notifyTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _paused = false;
  int _generation = 0;

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
          _service?.runNow();
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
    _service?.stop();
    await _arbiter?.waitForIdle();
    await FlutterForegroundTask.stopService();
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
  FlutterForegroundTask.setTaskHandler(AutoSummaryTaskHandler());
}
