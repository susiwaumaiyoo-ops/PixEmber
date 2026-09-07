// ローカルLLM 実行設定（LlmRuntimeSettings）の回帰テスト。
//
// 重要な保証: 実行設定（スレッド数・バックエンド）を変更した後に
// loadModel した場合、設定不一致により旧エンジンが**再利用されない**
// （旧エンジン解放 → 新設定で再ロード）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pixiv_viewer/services/local_llm_service.dart';

class _CountingEngine implements LlmInferenceEngine {
  _CountingEngine(this._loads);

  final List<String> _loads;
  bool disposed = false;

  @override
  Future<void> loadModel(String modelPath) async {
    _loads.add(modelPath);
  }

  @override
  Stream<LlamaCompletionChunk> generate({
    required List<LlamaChatMessage> messages,
    required GenerationParams options,
  }) async* {}

  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('LlmRuntimeSettings', () {
    test('デフォルトは 現状維持（自動スレッド・CPU）', () {
      const s = LlmRuntimeSettings();
      expect(s.cpuThreads, 0);
      expect(s.useVulkan, false);
    });

    test('load() は保存済み値を読み、不正値は既定に戻す', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        LlmRuntimeSettings.prefKeyCpuThreads: 2,
        LlmRuntimeSettings.prefKeyUseVulkan: true,
      });
      final s = await LlmRuntimeSettings.load();
      expect(s.cpuThreads, 2);
      expect(s.useVulkan, true);

      SharedPreferences.setMockInitialValues(<String, Object>{
        LlmRuntimeSettings.prefKeyCpuThreads: 999,
      });
      final s2 = await LlmRuntimeSettings.load();
      expect(s2.cpuThreads, 0);
      expect(s2.useVulkan, false);
    });

    test('等価性: 設定変更を再利用判定に使える', () {
      const a = LlmRuntimeSettings(cpuThreads: 2, useVulkan: false);
      const b = LlmRuntimeSettings(cpuThreads: 2, useVulkan: false);
      const c = LlmRuntimeSettings(cpuThreads: 2, useVulkan: true);
      const d = LlmRuntimeSettings(cpuThreads: 4, useVulkan: false);
      expect(a, equals(b));
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });
  });

  group('設定変更時のモデル再ロード', () {
    late Directory tmpDir;
    late String modelPath;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('llm_runtime_test');
      modelPath = '${tmpDir.path}${Platform.pathSeparator}model.gguf';
      File(modelPath).writeAsStringSync('dummy-gguf');
    });

    tearDown(() async {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    });

    test('同一モデルでも設定変更で再ロードされ、旧エンジンは解放される', () async {
      final loads = <String>[];
      final engines = <_CountingEngine>[];
      final service = LocalLlmService(
        engineFactory: (path) {
          final e = _CountingEngine(loads);
          engines.add(e);
          return e;
        },
      );

      // 1回目: デフォルト設定でロード。
      expect(await service.loadModel(modelPath), isTrue);
      expect(loads.length, 1);
      expect(engines.first.disposed, isFalse);

      // 同一設定 → 再利用（ロード skip）。
      expect(await service.loadModel(modelPath), isTrue);
      expect(loads.length, 1);

      // 設定変更（スレッド数 2）→ 再ロード（旧エンジンは解放）。
      service.runtimeSettings = const LlmRuntimeSettings(cpuThreads: 2);
      expect(await service.loadModel(modelPath), isTrue);
      expect(loads.length, 2);
      expect(engines.first.disposed, isTrue);
      expect(engines[1].disposed, isFalse);

      // 設定変更（Vulkan ON）→ 再ロード。
      service.runtimeSettings = const LlmRuntimeSettings(
        cpuThreads: 2,
        useVulkan: true,
      );
      expect(await service.loadModel(modelPath), isTrue);
      expect(loads.length, 3);
      expect(engines[1].disposed, isTrue);
      expect(engines[2].disposed, isFalse);

      await service.dispose();
    });

    test('ロード失敗したエンジンは解放され、サービスは error になる', () async {
      final disposed = <bool>[];
      var failNext = true;
      final service = LocalLlmService(
        engineFactory: (path) {
          if (failNext) {
            failNext = false;
            return _FailingEngine(disposed);
          }
          return _CountingEngine(<String>[]);
        },
      );

      expect(await service.loadModel(modelPath), isFalse);
      expect(service.state, LlmState.error);
      expect(disposed.single, isTrue);

      failNext = false;
      expect(await service.loadModel(modelPath), isTrue);
      await service.dispose();
    });

    test('Vulkan ロード失敗時は CPU へ1回だけフォールバックする', () async {
      final disposed = <bool>[];
      // engineFactory は試行ごとに新しいインスタンスを返すため、
      // 「失敗は全体で1回だけ」を共有カウンタで表現する。
      final failOnce = <int>[0];
      final service = LocalLlmService(
        runtimeSettings: const LlmRuntimeSettings(useVulkan: true),
        engineFactory: (path) =>
            _VulkanFailEngine(disposed, failCounter: failOnce),
      );

      expect(await service.loadModel(modelPath), isTrue);
      // Vulkan が失敗 → CPU で成功（フォールバック記録）。
      expect(service.lastLoadUsedCpuFallback, isTrue);
      expect(service.state, LlmState.idle);
      // 失敗した Vulkan エンジンは解放されている。
      expect(disposed.where((d) => d).length, greaterThanOrEqualTo(1));
      await service.dispose();
    });

    test('CPU フォールバック後も設定は CPU として記録される（再ロード回避）', () async {
      final loads = <int>[];
      final failOnce = <int>[0];
      final service = LocalLlmService(
        runtimeSettings: const LlmRuntimeSettings(useVulkan: true),
        engineFactory: (path) => _VulkanFailEngine(
          <bool>[],
          failCounter: failOnce,
          onLoaded: () {
            loads.add(loads.length + 1);
          },
        ),
      );

      expect(await service.loadModel(modelPath), isTrue);
      // フォールバック済み CPU 設定で同一モデルを再ロードしても
      // 古い（CPU）エンジンがそのまま使える。
      expect(await service.loadModel(modelPath), isTrue);
      expect(loads.length, 1);
      await service.dispose();
    });
  });

  group('tok/s 計算（C修正）', () {
    test('分母は elapsed - TTFT（デコード時間の近似）', () {
      const stats = LlmGenerationStats(
        generatedTokens: 10,
        elapsed: Duration(milliseconds: 2000),
        timeToFirstTokenMs: 1000,
      );
      // デコード 1000ms で 10 トークン → 10 tok/s
      // （修正前は elapsed 全体で 5 tok/s と過小評価された）。
      expect(stats.tokensPerSecond, closeTo(10.0, 0.001));
    });

    test('TTFT が取得不能・異常値の場合は elapsed を使う', () {
      const noTtft = LlmGenerationStats(
        generatedTokens: 10,
        elapsed: Duration(milliseconds: 2000),
      );
      expect(noTtft.tokensPerSecond, closeTo(5.0, 0.001));

      const ttftAfterEnd = LlmGenerationStats(
        generatedTokens: 10,
        elapsed: Duration(milliseconds: 2000),
        timeToFirstTokenMs: 3000,
      );
      expect(ttftAfterEnd.tokensPerSecond, closeTo(5.0, 0.001));
    });

    test('ネイティブ計測速度は eval 時間のみを分母にする', () {
      const stats = LlmGenerationStats(
        generatedTokens: 5,
        elapsed: Duration(milliseconds: 5000),
        nativeEvalMs: 1000,
        nativeEvalTokens: 40,
      );
      expect(stats.nativeTokensPerSecond, closeTo(40.0, 0.001));
      // eval 未取得（0ms）なら null（推定しない）。
      const missing = LlmGenerationStats(
        generatedTokens: 5,
        elapsed: Duration(milliseconds: 5000),
      );
      expect(missing.nativeTokensPerSecond, isNull);
    });
  });
}

class _FailingEngine extends _CountingEngine {
  _FailingEngine(this.disposedList) : super(const <String>[]);
  final List<bool> disposedList;

  @override
  Future<void> loadModel(String modelPath) async {
    throw StateError('simulated load failure');
  }

  @override
  void dispose() {
    disposedList.add(true);
  }
}

class _VulkanFailEngine extends _CountingEngine {
  _VulkanFailEngine(
    this.disposedList, {
    this.onLoaded,
    required this.failCounter,
  }) : super(const []);

  final List<bool> disposedList;
  final void Function()? onLoaded;

  /// 共有カウンタ: 空でなくなるまで、どのインスタンスのロードも失敗する
  /// （engineFactory は試行ごとに新しいインスタンスを返すため）。
  final List<int> failCounter;

  @override
  Future<void> loadModel(String modelPath) async {
    if (failCounter.isNotEmpty) {
      failCounter.removeLast();
      throw StateError('simulated vulkan init failure');
    }
    onLoaded?.call();
  }

  @override
  void dispose() {
    disposedList.add(true);
  }
}
