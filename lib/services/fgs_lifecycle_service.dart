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
      // 既にサービスが動いているか確認。
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (!isRunning) {
        // 新規起動。
        _generation++;
        debugPrint('[FgsLifecycle] starting service (gen=$_generation)');
        try {
await FlutterForegroundTask.startService(
            callback: autoSummaryTaskCallback,
            notificationTitle: 'PixEmber 自動要約',
            notificationText: '起動中…',
          );
        } catch (e) {
          debugPrint('[FgsLifecycle] startService rejected: $e');
          _readyCompleter!.complete(false);
          return false;
        }
      } else {
        debugPrint('[FgsLifecycle] service already running, waiting READY');
      }

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
