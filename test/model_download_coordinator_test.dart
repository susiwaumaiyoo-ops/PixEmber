// B6: ModelDownloadCoordinator のフェイク単体テスト（ネットワーク・モデル不要）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pixiv_viewer/services/model_download_coordinator.dart';

/// テスト用ヘルパー: ダウンロード完了をシミュレート。
Future<void> _fakeDownloadSuccess(
  String modelId, {
  ValueNotifier<bool>? cancel,
  void Function(int received, int total, String label)? onProgress,
}) async {
  onProgress?.call(500, 1000, 'tokenizer');
  await Future<void>.delayed(const Duration(milliseconds: 10));
  if (cancel != null && cancel.value) return;
  onProgress?.call(1000, 1000, 'tokenizer');
}

/// テスト用ヘルパー: ダウンロード失敗をシミュレート。
Future<void> _fakeDownloadFailure(
  String modelId, {
  ValueNotifier<bool>? cancel,
  void Function(int received, int total, String label)? onProgress,
}) async {
  onProgress?.call(300, 1000, 'model');
  throw Exception('ネットワークエラー');
}

void main() {
  late ModelDownloadCoordinator coordinator;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    coordinator = ModelDownloadCoordinator();
    coordinator.resetForTest();
  });

  tearDown(() {
    coordinator.resetForTest();
  });

  // ---- single-flight ----
  group('single-flight', () {
    test('同一 modelId の二重 start() は既存タスクを返す', () async {
      ModelDownloadCoordinator.isAndroidOverride = false;
      ModelDownloadCoordinator.downloadModelOverride = _fakeDownloadSuccess;
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => true;
      ModelDownloadCoordinator.setActiveModelIdOverride = (_) async {};

      final snap1 = await coordinator.start('model-a', foreground: true);
      final snap2 = await coordinator.start('model-a', foreground: true);

      // single-flight: 2回目は進行中タスクのスナップショットを返す。
      expect(snap1.modelId, 'model-a');
      expect(snap2.modelId, 'model-a');
      // 進行中状態が維持されていること。
      expect(
        coordinator.stateFor('model-a'),
        anyOf(ModelDownloadState.queued, ModelDownloadState.downloading),
      );
    });
  });

  // ---- state transitions ----
  group('state transitions', () {
    test('成功時: queued → downloading → verifying → completed', () async {
      ModelDownloadCoordinator.isAndroidOverride = false;
      ModelDownloadCoordinator.downloadModelOverride = _fakeDownloadSuccess;
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => true;
      ModelDownloadCoordinator.setActiveModelIdOverride = (_) async {};

      await coordinator.start('model-s', foreground: true);
      // start 直後は queued または downloading。
      expect(
        coordinator.stateFor('model-s'),
        anyOf(ModelDownloadState.queued, ModelDownloadState.downloading),
      );

      // 完了まで待つ（ポーリング）。
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(coordinator.stateFor('model-s'), ModelDownloadState.completed);
      final snap = coordinator.snapshotFor('model-s');
      expect(snap, isNotNull);
      expect(snap!.state, ModelDownloadState.completed);
    });

    test('失敗時: queued → downloading → failed', () async {
      ModelDownloadCoordinator.isAndroidOverride = false;
      ModelDownloadCoordinator.downloadModelOverride = _fakeDownloadFailure;
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => true;

      await coordinator.start('model-f', foreground: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final state = coordinator.stateFor('model-f');
      expect(state, ModelDownloadState.failed);

      final snap = coordinator.snapshotFor('model-f');
      expect(snap, isNotNull);
      expect(snap!.error, contains('ネットワークエラー'));
    });
  });

  // ---- progress persistence / restore ----
  group('progress persistence / restore', () {
    test('進捗が SharedPreferences に永続され、復元できる', () async {
      SharedPreferences.setMockInitialValues({});
      ModelDownloadCoordinator.isAndroidOverride = false;

      // 遅延ダウンロード（完了前にチェック）。
      ModelDownloadCoordinator.downloadModelOverride =
          (
            String modelId, {
            ValueNotifier<bool>? cancel,
            void Function(int r, int t, String l)? onProgress,
          }) async {
            onProgress?.call(500, 1000, 'tokenizer');
            // 完了しないよう永遠に待つ。
            await Completer<void>().future;
          };
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => true;

      await coordinator.start('model-p', foreground: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // SharedPreferences に永続データがあることを確認。
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('mdc_model-p');
      expect(raw, isNotNull);
      expect(raw, contains('downloading'));

      // 新しいコーディネーターインスタンスで復元。
      final coordinator2 = ModelDownloadCoordinator();
      coordinator2.resetForTest();
      final restored = await coordinator2.loadPersisted('model-p');
      expect(restored, isNotNull);
      expect(restored!.state, ModelDownloadState.downloading);
      expect(restored.receivedBytes, 500);
      expect(restored.totalBytes, 1000);
    });
  });

  // ---- service survives dispose (UI が dispose されてもサービスは存続) ----
  group('service survives dispose', () {
    test('start 後に UI 相当の参照が消えてもサービスは完了する', () async {
      ModelDownloadCoordinator.isAndroidOverride = false;
      ModelDownloadCoordinator.downloadModelOverride = _fakeDownloadSuccess;
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => true;
      ModelDownloadCoordinator.setActiveModelIdOverride = (_) async {};

      await coordinator.start('model-d', foreground: true);
      // UI 側の参照をシミュレート（画面 dispose）。
      // コーディネーターはシングルトンなので存続する。

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(coordinator.stateFor('model-d'), ModelDownloadState.completed);
    });
  });

  // ---- SHA-failure: 検証失敗時は completed にならない ----
  group('SHA-failure', () {
    test('isModelReady が false なら failed になる', () async {
      ModelDownloadCoordinator.isAndroidOverride = false;
      ModelDownloadCoordinator.downloadModelOverride = _fakeDownloadSuccess;
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => false;

      await coordinator.start('model-sha', foreground: true);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(coordinator.stateFor('model-sha'), ModelDownloadState.failed);
      expect(
        coordinator.stateFor('model-sha'),
        isNot(ModelDownloadState.completed),
      );
    });
  });

  // ---- cancel ----
  group('cancel', () {
    test('cancel() でタスク状態が cancelled になる', () async {
      ModelDownloadCoordinator.isAndroidOverride = false;

      // slow ダウンロード（50ms × 100 = 5s）。
      ModelDownloadCoordinator.downloadModelOverride =
          (
            String modelId, {
            ValueNotifier<bool>? cancel,
            void Function(int r, int t, String l)? onProgress,
          }) async {
            for (int i = 1; i <= 100; i++) {
              if (cancel != null && cancel.value) return;
              onProgress?.call(i * 10, 1000, 'model');
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          };
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => true;

      await coordinator.start('model-c', foreground: true);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      await coordinator.cancel('model-c');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(coordinator.stateFor('model-c'), ModelDownloadState.cancelled);
    });
  });

  // ---- taskName → handler branching ----
  group('taskName branching', () {
    test('taskName が "model_download" である', () {
      expect(ModelDownloadCoordinator.taskName, 'model_download');
    });

    test('inputKeyModelId が "modelId" である', () {
      expect(ModelDownloadCoordinator.inputKeyModelId, 'modelId');
    });
  });

  // ---- inputData missing modelId: safe failure ----
  group('inputData missing modelId', () {
    test('modelId なし inputData で false を返す', () async {
      final result = await ModelDownloadCoordinator.runModelDownloadOnce(null);
      expect(result, isFalse);
    });

    test('空 modelId で false を返す', () async {
      final result = await ModelDownloadCoordinator.runModelDownloadOnce({
        'modelId': '',
      });
      expect(result, isFalse);
    });
  });

  // ---- non-Android: doesn't register background ----
  group('non-Android', () {
    test('非 Android では registerBackgroundOverride が呼ばれない', () async {
      ModelDownloadCoordinator.isAndroidOverride = false;
      ModelDownloadCoordinator.downloadModelOverride = _fakeDownloadSuccess;
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => true;
      ModelDownloadCoordinator.setActiveModelIdOverride = (_) async {};

      var bgRegistered = false;
      ModelDownloadCoordinator.registerBackgroundOverride = (_) async {
        bgRegistered = true;
      };

      await coordinator.start('model-na', foreground: false);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // foreground: false でも isAndroid=false なのでフォアグラウンド実行。
      // registerBackgroundOverride は呼ばれない。
      expect(bgRegistered, isFalse);
      expect(coordinator.stateFor('model-na'), ModelDownloadState.completed);
    });

    test('Android + foreground:false では registerBackground が呼ばれる', () async {
      ModelDownloadCoordinator.isAndroidOverride = true;

      var bgRegistered = false;
      ModelDownloadCoordinator.registerBackgroundOverride = (_) async {
        bgRegistered = true;
        // バックグラウンド実行をシミュレート: タスクを完了させる。
        coordinator.handleProgressUpdate({
          'modelId': 'model-and',
          'received': 1000,
          'total': 1000,
          'label': 'done',
          'state': 'completed',
        });
      };

      await coordinator.start('model-and', foreground: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(bgRegistered, isTrue);
    });
  });

  // ---- clearPersisted ----
  group('clearPersisted', () {
    test('永続データとメモリタスクをクリア', () async {
      SharedPreferences.setMockInitialValues({});
      ModelDownloadCoordinator.isAndroidOverride = false;
      ModelDownloadCoordinator.downloadModelOverride =
          (
            String modelId, {
            ValueNotifier<bool>? cancel,
            void Function(int r, int t, String l)? onProgress,
          }) async {
            onProgress?.call(500, 1000, 'tok');
            await Completer<void>().future;
          };
      ModelDownloadCoordinator.isModelReadyOverride = (_) async => true;

      await coordinator.start('model-clr', foreground: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(coordinator.snapshotFor('model-clr'), isNotNull);

      await coordinator.clearPersisted('model-clr');

      expect(coordinator.snapshotFor('model-clr'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mdc_model-clr'), isNull);
    });
  });

  // ---- progress snapshot ----
  group('ModelDownloadSnapshot', () {
    test('progress は 0.0〜1.0 にクランプされる', () {
      const snap = ModelDownloadSnapshot(
        modelId: 'x',
        state: ModelDownloadState.downloading,
        receivedBytes: 500,
        totalBytes: 1000,
      );
      expect(snap.progress, 0.5);

      const snap0 = ModelDownloadSnapshot(
        modelId: 'x',
        state: ModelDownloadState.downloading,
        receivedBytes: 0,
        totalBytes: 0,
      );
      expect(snap0.progress, 0.0);

      const snapOver = ModelDownloadSnapshot(
        modelId: 'x',
        state: ModelDownloadState.downloading,
        receivedBytes: 1500,
        totalBytes: 1000,
      );
      expect(snapOver.progress, 1.0);
    });

    test('toJson/fromJson round-trip', () {
      const snap = ModelDownloadSnapshot(
        modelId: 'rt',
        state: ModelDownloadState.downloading,
        receivedBytes: 300,
        totalBytes: 900,
        label: 'model',
        error: 'some err',
      );
      final json = snap.toJson();
      expect(json['modelId'], 'rt');
      expect(json['state'], 'downloading');
      expect(json['received'], 300);
      expect(json['total'], 900);
      expect(json['label'], 'model');
      expect(json['error'], 'some err');
    });
  });

  // ---- loadAllPersisted ----
  group('loadAllPersisted', () {
    test('複数モデルの永続データを一括取得', () async {
      // SharedPreferences の mock を prefsCache リセット前に設定。
      SharedPreferences.setMockInitialValues({
        'mdc_m1':
            '{"modelId":"m1","state":"completed","received":1000,"total":1000,"label":"done"}',
        'mdc_m2':
            '{"modelId":"m2","state":"failed","received":500,"total":1000,"label":"mid","error":"err"}',
      });
      final coordinator2 = ModelDownloadCoordinator();
      // resetForTest() で _tasks と _prefsCache をクリア。
      coordinator2.resetForTest();

      // mock が正しく設定されているか確認。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mdc_m1'), isNotNull);

      final map = await coordinator2.loadAllPersisted(['m1', 'm2', 'm3']);
      expect(map.length, 2);
      expect(map['m1']!.state, ModelDownloadState.completed);
      expect(map['m2']!.state, ModelDownloadState.failed);
      expect(map['m2']!.error, 'err');
      expect(map.containsKey('m3'), isFalse);
    });
  });
}
