import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'ruri_model_manager.dart';

/// B6: AI モデル DL のバックグラウンド継続 + 通知を担うアプリ全体単一サービス。
///
/// 責務:
/// - UI State から DL 処理を分離（画面 dispose 後も進行・完了する）
/// - modelId ごとの single-flight（同一モデルの二重 DL を防止）
/// - 状態機械（idle/queued/downloading/verifying/completed/failed/cancelled）
/// - 状態・進捗を SharedPreferences へ永続（1〜2% 単位、画面復帰時に再読込）
/// - Android: 開始時に Workmanager の ForegroundService(dataSync) として起動し、
///   Workmanager 自身の通知で進捗を案内。非 Android はフォアグラウンド縮退。
///
/// 注意:
/// - バックグラウンド isolate（callbackDispatcher）には BuildContext/State/ValueNotifier/
///   closure を渡さず、[runModelDownloadOnce] には sendable な [inputData](modelId) のみ渡す。
/// - 通知本文にモデル URL や個人情報は含めない。
class ModelDownloadCoordinator {
  ModelDownloadCoordinator._internal();

  static final ModelDownloadCoordinator _instance =
      ModelDownloadCoordinator._internal();
  factory ModelDownloadCoordinator() => _instance;

  /// バックグラウンドタスク名（callbackDispatcher の switch で使用）。
  static const String taskName = 'model_download';

  /// inputData のキー。
  static const String inputKeyModelId = 'modelId';

  /// 永続用 SharedPreferences キー prefix。
  static const String _prefsPrefix = 'mdc_';

  /// 進捗通知の最小更新間隔（UI/永続書込の節約）。
  static const int _minPersistPercentStep = 2;

  final Map<String, _ModelDownloadTask> _tasks = {};

  SharedPreferences? _prefsCache;

  // ---- Test injection points (@visibleForTesting) ----
  /// Android 判定を上書き（null なら実機 Platform.isAndroid）。
  @visibleForTesting
  static bool? isAndroidOverride;

  /// ダウンロード関数を上書き（null なら RuriModelManager().downloadModel）。
  @visibleForTesting
  static Future<void> Function(
    String modelId, {
    ValueNotifier<bool>? cancel,
    ModelDownloadProgress? onProgress,
  })?
  downloadModelOverride;

  /// 検証関数を上書き（null なら RuriModelManager().isModelReadyFor）。
  @visibleForTesting
  static Future<bool> Function(String modelId)? isModelReadyOverride;

  /// アクティブ設定関数を上書き（null なら RuriModelManager().setActiveModelId）。
  @visibleForTesting
  static Future<void> Function(String modelId)? setActiveModelIdOverride;

  /// Workmanager 登録を上書き（null なら実際に registerOneOffTask）。
  @visibleForTesting
  static Future<void> Function(String modelId)? registerBackgroundOverride;

  /// テスト用: 全オーバーライド・メモリ状態をリセット。
  @visibleForTesting
  void resetForTest() {
    _tasks.clear();
    _prefsCache = null;
    isAndroidOverride = null;
    downloadModelOverride = null;
    isModelReadyOverride = null;
    setActiveModelIdOverride = null;
    registerBackgroundOverride = null;
  }

  bool get _isAndroid => isAndroidOverride ?? Platform.isAndroid;

  Future<SharedPreferences> get _prefs async =>
      _prefsCache ??= await SharedPreferences.getInstance();

  /// 現在のタスク状態（UI 用・存在しなければ idle）。
  ModelDownloadState stateFor(String modelId) =>
      _tasks[modelId]?.state ?? ModelDownloadState.idle;

  /// UI 用の進捗スナップショット（存在しなければ null）。
  ModelDownloadSnapshot? snapshotFor(String modelId) =>
      _tasks[modelId]?.snapshot;

  /// 永続された状態を読み込み、メモリ上のタスクを再構築する（画面復帰時など）。
  /// 進行中だったものは「中断扱いの resumed（再開可能）」として復元する。
  Future<ModelDownloadSnapshot?> loadPersisted(String modelId) async {
    final prefs = await _prefs;
    final raw = prefs.getString('$_prefsPrefix$modelId');
    if (raw == null) return null;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final stateName = map['state'] as String?;
    final state = ModelDownloadState.values.firstWhere(
      (e) => e.name == stateName,
      orElse: () => ModelDownloadState.idle,
    );
    final snapshot = ModelDownloadSnapshot(
      modelId: modelId,
      state: state,
      receivedBytes: map['received'] as int? ?? 0,
      totalBytes: map['total'] as int? ?? 0,
      label: map['label'] as String? ?? '',
      error: map['error'] as String?,
    );
    // 進行中/キュー中だったものはメモリ上でも resumed として保持（再開は呼び出し側責務）。
    if (state == ModelDownloadState.downloading ||
        state == ModelDownloadState.queued) {
      _tasks[modelId] = _ModelDownloadTask(modelId, state, snapshot);
    }
    return snapshot;
  }

  /// 全モデルの永続状態をマップで取得（設定画面等で一覧表示用）。
  Future<Map<String, ModelDownloadSnapshot>> loadAllPersisted(
    List<String> modelIds,
  ) async {
    final out = <String, ModelDownloadSnapshot>{};
    for (final id in modelIds) {
      final s = await loadPersisted(id);
      if (s != null) out[id] = s;
    }
    return out;
  }

  /// ダウンロードを開始（または進行中なら既存タスクを返す = single-flight）。
  ///
  /// [foreground] は非 Android などでフォアグラウンド実行を強制する場合に true。
  /// 戻り値は [ModelDownloadSnapshot] の状態変化を監視するためのスナップショット。
  Future<ModelDownloadSnapshot> start(
    String modelId, {
    bool? foreground,
    bool activate = true,
  }) async {
    final fg = foreground ?? !_isAndroid;
    // single-flight: 同じ modelId のタスクが進行中ならそれを返す。
    final existing = _tasks[modelId];
    if (existing != null &&
        (existing.state == ModelDownloadState.downloading ||
            existing.state == ModelDownloadState.queued ||
            existing.state == ModelDownloadState.verifying)) {
      return existing.snapshot;
    }

    final task = _ModelDownloadTask(
      modelId,
      ModelDownloadState.queued,
      ModelDownloadSnapshot(modelId: modelId, state: ModelDownloadState.queued),
    );
    _tasks[modelId] = task;
    await _persist(task);

    if (!fg && _isAndroid) {
      // Android: Workmanager FGS でバックグラウンド継続。
      if (registerBackgroundOverride != null) {
        await registerBackgroundOverride!(modelId);
      } else {
        await _registerBackgroundIfAndroid(modelId);
      }
    } else {
      // 非 Android / フォアグラウンド強制: この isolate で直接実行。
      unawaited(_runInForeground(task, activate: activate));
    }
    return task.snapshot;
  }

  /// Android でのバックグラウンドタスク登録（FGS 付き）。
  Future<void> _registerBackgroundIfAndroid(String modelId) async {
    try {
      await Workmanager().registerOneOffTask(
        '${taskName}_$modelId',
        taskName,
        inputData: <String, dynamic>{inputKeyModelId: modelId},
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.keep,
        outOfQuotaPolicy: OutOfQuotaPolicy.runAsNonExpeditedWorkRequest,
        foregroundServiceConfig: ForegroundServiceConfig(
          notificationTitle: 'AI モデルをダウンロード中',
          notificationText: 'PixEmber がモデルをバックグラウンドで取得しています',
          foregroundServiceType: ForegroundServiceType.dataSync,
        ),
      );
    } catch (e) {
      debugPrint('[ModelDownloadCoordinator] workmanager 登録失敗: $e');
      // フォールバック: フォアグラウンドで直接実行
      final task = _tasks[modelId];
      if (task != null) unawaited(_runInForeground(task));
    }
  }

  /// バックグラウンド isolate から呼ばれるエントリ。BuildContext 等は一切受け取らない。
  static Future<bool> runModelDownloadOnce(
    Map<String, dynamic>? inputData,
  ) async {
    final modelId = inputData?[inputKeyModelId] as String?;
    if (modelId == null || modelId.isEmpty) {
      debugPrint('[ModelDownloadCoordinator] inputData に modelId なし: 安全に失敗');
      return false;
    }
    final coordinator = ModelDownloadCoordinator();
    final task = _ModelDownloadTask(
      modelId,
      ModelDownloadState.downloading,
      ModelDownloadSnapshot(
        modelId: modelId,
        state: ModelDownloadState.downloading,
      ),
    );
    coordinator._tasks[modelId] = task;
    await coordinator._runCore(task, fromBackground: true);
    return true;
  }

  /// この isolate（フォアグラウンド）で実行。
  Future<void> _runInForeground(
    _ModelDownloadTask task, {
    bool activate = true,
  }) async {
    await _runCore(task, fromBackground: false, activate: activate);
  }

  /// 進捗コールバックの共通処理（snapshot 更新・永続・背景報告）。
  void _onProgress(
    _ModelDownloadTask task,
    bool fromBackground,
    int received,
    int total,
    String label,
  ) {
    final modelId = task.modelId;
    task.snapshot = ModelDownloadSnapshot(
      modelId: modelId,
      state: ModelDownloadState.downloading,
      receivedBytes: received,
      totalBytes: total,
      label: label,
    );
    final percent = total > 0 ? (received * 100 ~/ total) : 0;
    if (percent - task.lastPersistPercent >= _minPersistPercentStep ||
        percent >= 100) {
      task.lastPersistPercent = percent;
      unawaited(_persist(task));
    }
    if (fromBackground) {
      unawaited(
        Workmanager().reportProgress(<String, dynamic>{
          'modelId': modelId,
          'received': received,
          'total': total,
          'label': label,
          'state': ModelDownloadState.downloading.name,
        }),
      );
    }
  }

  /// 実際の DL 処理。両 isolate 共通。
  Future<void> _runCore(
    _ModelDownloadTask task, {
    required bool fromBackground,
    bool activate = true,
  }) async {
    final modelId = task.modelId;
    try {
      task.state = ModelDownloadState.downloading;
      await _persist(task);
      if (downloadModelOverride != null) {
        await downloadModelOverride!(
          modelId,
          cancel: task.cancel,
          onProgress: (r, t, l) {
            _onProgress(task, fromBackground, r, t, l);
          },
        );
      } else {
        await RuriModelManager().downloadModel(
          modelId,
          cancel: task.cancel,
          onProgress: (received, total, label) {
            _onProgress(task, fromBackground, received, total, label);
          },
        );
      }
      if (task.cancel.value) {
        task.state = ModelDownloadState.cancelled;
        await _persist(task);
        return;
      }
      // 検証フェーズ
      task.state = ModelDownloadState.verifying;
      await _persist(task);
      final ready = isModelReadyOverride != null
          ? await isModelReadyOverride!(modelId)
          : await RuriModelManager().isModelReadyFor(modelId);
      if (!ready) {
        throw StateError('モデル検証失敗（SHA-256 不一致または破損）');
      }
      if (activate) {
        if (setActiveModelIdOverride != null) {
          await setActiveModelIdOverride!(modelId);
        } else {
          await RuriModelManager().setActiveModelId(modelId);
        }
      }
      task.state = ModelDownloadState.completed;
      task.snapshot = ModelDownloadSnapshot(
        modelId: modelId,
        state: ModelDownloadState.completed,
        receivedBytes: task.snapshot.totalBytes,
        totalBytes: task.snapshot.totalBytes,
        label: task.snapshot.label,
      );
      await _persist(task);
      if (fromBackground) {
        unawaited(
          Workmanager().reportProgress(<String, dynamic>{
            'modelId': modelId,
            'received': task.snapshot.totalBytes,
            'total': task.snapshot.totalBytes,
            'label': task.snapshot.label,
            'state': ModelDownloadState.completed.name,
          }),
        );
      }
    } catch (e) {
      if (task.cancel.value) {
        task.state = ModelDownloadState.cancelled;
      } else {
        task.state = ModelDownloadState.failed;
        task.snapshot = ModelDownloadSnapshot(
          modelId: modelId,
          state: ModelDownloadState.failed,
          receivedBytes: task.snapshot.receivedBytes,
          totalBytes: task.snapshot.totalBytes,
          label: task.snapshot.label,
          error: e.toString(),
        );
      }
      await _persist(task);
    }
  }

  /// バックグラウンド isolate からの進捗通知を反映（アプリ起動中のリスナーから呼ぶ）。
  Future<void> handleProgressUpdate(Map<String, dynamic> progress) async {
    final modelId = progress['modelId'] as String?;
    if (modelId == null) return;
    final task = _tasks[modelId];
    if (task != null) {
      task.snapshot = ModelDownloadSnapshot(
        modelId: modelId,
        state: ModelDownloadState.values.firstWhere(
          (e) => e.name == (progress['state'] as String? ?? 'downloading'),
          orElse: () => ModelDownloadState.downloading,
        ),
        receivedBytes: progress['received'] as int? ?? 0,
        totalBytes: progress['total'] as int? ?? 0,
        label: progress['label'] as String? ?? '',
      );
      await _persist(task);
    }
  }

  /// キャンセル（進行中タスクに通知）。
  Future<void> cancel(String modelId) async {
    _tasks[modelId]?.cancel.value = true;
  }

  /// 永続状態の削除（完了後クリーンアップ等）。
  Future<void> clearPersisted(String modelId) async {
    final prefs = await _prefs;
    await prefs.remove('$_prefsPrefix$modelId');
    _tasks.remove(modelId);
  }

  Future<void> _persist(_ModelDownloadTask task) async {
    final prefs = await _prefs;
    await prefs.setString(
      '$_prefsPrefix${task.modelId}',
      jsonEncode(task.snapshot.toJson()),
    );
  }
}

/// ダウンロード状態機械。
enum ModelDownloadState {
  idle,
  queued,
  downloading,
  verifying,
  completed,
  failed,
  cancelled,
}

/// UI / 永続用スナップショット。
class ModelDownloadSnapshot {
  const ModelDownloadSnapshot({
    required this.modelId,
    required this.state,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.label = '',
    this.error,
  });

  final String modelId;
  final ModelDownloadState state;
  final int receivedBytes;
  final int totalBytes;
  final String label;
  final String? error;

  double get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'modelId': modelId,
    'state': state.name,
    'received': receivedBytes,
    'total': totalBytes,
    'label': label,
    if (error != null) 'error': error,
  };
}

/// 単一モデルの DL タスク（メモリ上状態）。
class _ModelDownloadTask {
  _ModelDownloadTask(this.modelId, this.state, this.snapshot);

  final String modelId;
  final ValueNotifier<bool> cancel = ValueNotifier<bool>(false);
  ModelDownloadState state;
  ModelDownloadSnapshot snapshot;
  int lastPersistPercent = -100;
}
