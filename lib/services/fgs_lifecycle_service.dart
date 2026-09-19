// Phase 9-B2/B2-4+5: FGS の開始・READY確認・停止を管理する UI 側サービス。
//
// 規則（ユーザー承認 2026-09-11）:
// - 同時に複数要求が来ても開始処理を重複実行しない。
// - 稼働中なら restartService で再起動せず、既存サービスに接続する。
// - startService 成功だけで TaskHandler の準備完了とは判断しない。
// - TaskHandler 側から READY 応答を返し、準備完了後に生成要求を送る。
// - READY 待ちには期限を設け、失敗を UI へ返す。
// - FGS 起動を OS に拒否された場合はエラーを明示する。
//   無断で UI 側の別エンジンへ切り替えない。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'auto_summary_task_handler.dart';

/// Task→UI の READY キー。
const String kKeyReady = 'type';
const String kValueReady = 'ready';
const String kKeyGeneration = 'generation';

/// FGS のライフサイクル管理（UI isolate・シングルトン）。
class FgsLifecycleService {
  static final FgsLifecycleService _instance = FgsLifecycleService._();
  factory FgsLifecycleService() => _instance;
  FgsLifecycleService._() {
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  // ---- 状態 ----
  bool _ready = false;
  int _generation = 0;
  bool _starting = false;
  Completer<bool>? _readyCompleter;

  /// READY 待ちのタイムアウト。
  static const Duration _readyTimeout = Duration(seconds: 15);

  // ---- 公開状態 ----
  bool get isReady => _ready;
  int get generation => _generation;

  // ===========================================================================
  // ensureServiceReady
  // ===========================================================================

  /// FGS を起動し、TaskHandler の READY を確認する。
  ///
  /// - 既に READY なら即座に true を返す。
  /// - 既に開始処理中ならその完了を待つ（重複開始しない）。
  /// - 稼働中だが READY 未受信なら READY 待ちのみ行う。
  /// - 未稼働なら startService → READY 待ち。
  /// - タイムアウト・OS 拒否は false を返す。
  Future<bool> ensureServiceReady() async {
    if (_ready) return true;

    // 既に開始処理中 → その完了を待つ。
    if (_starting && _readyCompleter != null) {
      return _readyCompleter!.future;
    }

    _starting = true;
    _readyCompleter = Completer<bool>();

    try {
      // 既にサービスが動いているか確認（init() 忘れは ServiceNotInitializedException で検知）。
      final runningBefore = await FlutterForegroundTask.isRunningService;
      debugPrint('[FgsLifecycle] isRunningService(before)=$runningBefore');
      if (!runningBefore) {
        // 新規起動（切り分け中は実サービス不在確認のため startService を明示）。
        _generation++;
        debugPrint('[FgsLifecycle] starting service (gen=$_generation)');
        final result = await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.dataSync],
          callback: autoSummaryTaskCallback,
          notificationTitle: 'PixEmber 自動要約',
          notificationText: '起動中…',
        );
        switch (result) {
          case ServiceRequestSuccess():
            debugPrint(
              '[FgsLifecycle] startService result=success '
              'running=${await FlutterForegroundTask.isRunningService}',
            );
          case ServiceRequestFailure(:final error):
            debugPrint(
              '[FgsLifecycle] startService result=failure '
              'type=${error.runtimeType} error=$error',
            );
            if (error is ServiceNotInitializedException) {
              debugPrint('[FgsLifecycle] 原因: init() が呼ばれていません');
            }
            _readyCompleter!.complete(false);
            return false;
        }
      } else {
        debugPrint('[FgsLifecycle] service already running, waiting READY');
      }

      // +1s 後に再度 isRunningService を記録（起動確認）。
      unawaited(
        Future<void>.delayed(const Duration(seconds: 1), () async {
          debugPrint(
            '[FgsLifecycle] isRunningService(+1s)='
            '${await FlutterForegroundTask.isRunningService}',
          );
        }),
      );

      // READY を待つ（タイムアウト付き）。
      final result = await _readyCompleter!.future.timeout(
        _readyTimeout,
        onTimeout: () => false,
      );
      if (result) {
        _ready = true;
        debugPrint('[FgsLifecycle] READY confirmed (gen=$_generation)');
      } else {
        debugPrint('[FgsLifecycle] READY timeout or failure');
      }
      return result;
    } catch (e) {
      debugPrint('[FgsLifecycle] ensureServiceReady error: $e');
      if (!_readyCompleter!.isCompleted) {
        _readyCompleter!.complete(false);
      }
      return false;
    } finally {
      _starting = false;
    }
  }

  // ===========================================================================
  // TaskHandler からのイベント受信
  // ===========================================================================

  void _onTaskData(Object data) {
    if (data is! Map) return;
    // Task 側が自律停止（アイドル解放/手動停止）→ UI の _ready を解除し、
    // 次の「今すぐ実行」で ensureServiceReady が正しく startService し直す。
    if (data[kKeyShutdown] == true) {
      _ready = false;
      _starting = false;
      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.complete(false);
      }
      debugPrint('[FgsLifecycle] shutdown received -> reset ready');
      return;
    }
    final type = data[kKeyReady];
    if (type == kValueReady) {
      final gen = data[kKeyGeneration] as int? ?? 0;
      debugPrint('[FgsLifecycle] READY received (gen=$gen)');
      if (!_ready) {
        _ready = true;
        if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
          _readyCompleter!.complete(true);
        }
      }
    }
  }

  // ===========================================================================
  // 停止
  // ===========================================================================

  /// サービス全体を停止する（安全なシーケンスは TaskHandler 側で実行）。
  Future<void> stopService() async {
    _ready = false;
    try {
      await FlutterForegroundTask.stopService();
      debugPrint('[FgsLifecycle] service stopped');
    } catch (e) {
      debugPrint('[FgsLifecycle] stopService error: $e');
    }
  }

  /// READY 状態をリセット（サービス消滅検知時）。
  void markNotReady() {
    _ready = false;
  }

  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
  }
}
