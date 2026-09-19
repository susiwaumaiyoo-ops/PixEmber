// Phase 9-B2/B2-4+5: UI isolate 側のブリッジコントローラ。
//
// FGS TaskHandler との通信は sendDataToTask / addTaskDataCallback のみ。
// UI はこのコントローラを AutoSummaryController として扱い、内部実装を知らない。
// 手動要約の要求・応答もこのブリッジ経由で行う。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'auto_summary_controller.dart';
import 'auto_summary_repository.dart';
import 'auto_summary_snapshot.dart';
import 'auto_summary_task_handler.dart';
import 'fgs_lifecycle_service.dart';
import 'llm_run_arbiter.dart';
import 'llm_summary_service.dart';

/// UI isolate 側の自動要約ブリッジコントローラ。
///
/// 正本は FGS TaskHandler 側にあり、このクラスは表示用のミラーを保持する。
class AutoSummaryBridgeController implements AutoSummaryController {
  /// [ensureReady] / [sendToTask] はテスト用の注入点。
  /// 既定では実 FGS ライフサイクルと sendDataToTask を使う。
  AutoSummaryBridgeController({
    Future<bool> Function()? ensureReady,
    void Function(Object data)? sendToTask,
  })  : _ensureReady = ensureReady ?? FgsLifecycleService().ensureServiceReady,
        _sendToTask = sendToTask ?? FlutterForegroundTask.sendDataToTask {
    if (ensureReady == null) {
      // 注入時（テスト）はシングルトンのデータ購読を登録しない。
      _loadPersisted();
      FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    }
  }

  final Future<bool> Function() _ensureReady;
  final void Function(Object data) _sendToTask;

  final ValueNotifier<AutoSummarySnapshot> _notifier =
      ValueNotifier<AutoSummarySnapshot>(const AutoSummarySnapshot());
  AutoSummarySnapshotBatcher? _batcher;
  bool _disposed = false;

  /// 手動要約イベントのコールバック（UI シートが登録）。
  void Function(String requestId, ManualRequestStatus status,
      {String? token, LlmSummaryResult? result, String? error})? onManualEvent;

  /// 起動時に永続化された最新 run を復元（再接続 §6-C）。
  Future<void> _loadPersisted() async {
    try {
      final repo = AutoSummaryRepository();
      final latest = await repo.loadLatest();
      if (latest != null && !_disposed) {
        _notifier.value = latest;
      }
    } catch (_) {}
  }

  void _onTaskData(Object data) {
    if (data is! Map) return;
    final snapshotMap = data[kKeySnapshot];
    if (snapshotMap is Map) {
      try {
        final s = AutoSummarySnapshot.fromMap(snapshotMap);
        if (!_disposed) _notifier.value = s;
      } catch (_) {}
    }
    // 手動要約イベント。
    if (data[kKeyManualEvent] == true) {
      _handleManualEvent(data);
    }
  }

  void _handleManualEvent(Map data) {
    final requestId = data['requestId'] as String? ?? '';
    final statusStr = data['status'] as String? ?? '';
    final status = ManualRequestStatus.values.firstWhere(
      (s) => s.name == statusStr,
      orElse: () => ManualRequestStatus.error,
    );
    final token = data['token'] as String?;
    final error = data['error'] as String?;
    LlmSummaryResult? result;
    final resultMap = data['result'];
    if (resultMap is Map) {
      try {
        result = LlmSummaryResult.fromMap(resultMap);
      } catch (_) {}
    }
    onManualEvent?.call(requestId, status,
        token: token, result: result, error: error);
  }

  @override
  AutoSummarySnapshot get current => _notifier.value;

  @override
  ValueListenable<AutoSummarySnapshot> get state {
    return (_batcher ??= AutoSummarySnapshotBatcher(
      source: _notifier,
    )).listenable;
  }

  @override
  Future<bool> runNow() async {
    // FGS が未起動なら先に起動＋READY を確認（ensureServiceReady は再入安全）。
    final ready = await _ensureReady();
    if (!ready) return false;
    _sendToTask(kCmdRun);
    return true;
  }

  @override
  void pause() {
    FlutterForegroundTask.sendDataToTask(kCmdPause);
  }

  @override
  void resume() {
    FlutterForegroundTask.sendDataToTask(kCmdResume);
  }

  @override
  void stop() {
    FlutterForegroundTask.sendDataToTask(kCmdStopAuto);
  }

  /// サービス全体を停止（FGS 自体を停止）。
  void stopService() {
    FlutterForegroundTask.sendDataToTask(kCmdStopService);
  }

  /// 手動要約を FGS 側に要求する。
  void submitManualSummary({
    required String requestId,
    required int workId,
    required String title,
    required List<String> tags,
    required String body,
    String description = '',
    String modelLabel = '',
  }) {
    FlutterForegroundTask.sendDataToTask(<String, dynamic>{
      'type': kCmdManualGenerate,
      'requestId': requestId,
      'workId': workId,
      'title': title,
      'tags': tags,
      'body': body,
      'description': description,
      'modelLabel': modelLabel,
    });
  }

  /// 手動要約をキャンセルする。
  void cancelManualSummary(String requestId) {
    FlutterForegroundTask.sendDataToTask(<String, dynamic>{
      'type': kCmdManualCancel,
      'requestId': requestId,
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _batcher?.dispose();
    _notifier.dispose();
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
  }
}
