// M5: モデル切替・推論プリセット・生成メトリクスのテスト。
//
// 対象:
// - LlmInferencePreset（既定値・カタログ解決）
// - LocalLlmService（プリセット反映・lastGenerationStats）
// - LlmModelPaths.resolveModelPath（消失済みモデル設定のクリア）
// - LlmSummaryService.generate（メタ情報付与）
// - LlmSummarySheet（メタ行・このモデルで再生成・別モデルで再生成）
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/models/llm_model_catalog_entry.dart';
import 'package:pixiv_viewer/services/llm_model_preset.dart';
import 'package:pixiv_viewer/services/llm_summary_service.dart';
import 'package:pixiv_viewer/services/local_llm_service.dart';
import 'package:pixiv_viewer/widgets/llm_summary_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// スクリプト済みストリームを返す fake エンジン（ネイティブ非依存）。
class _FakeEngine implements LlmInferenceEngine {
  _FakeEngine(this.chunks, {this.error});

  final List<String> chunks;
  final Object? error;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Stream<String> generate({
    required List<LlmChatMessage> messages,
    required LlmGenerationOptions options,
  }) async* {
    for (final c in chunks) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      yield c;
    }
    if (error != null) throw error!;
  }

  @override
  void dispose() {}
}

LlmModelCatalogEntry _catalogEntry({
  String fileName = 'model-x.gguf',
  int recommendedContext = 4096,
  int maxOutputTokens = 768,
  int preferredGpuLayers = -1,
}) {
  return LlmModelCatalogEntry(
    id: 'model-x',
    displayName: 'テストモデルX',
    family: 'test',
    parameterCount: '2B',
    quantization: 'Q4_K_M',
    repositoryId: 'owner/repo',
    revision: 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
    fileName: fileName,
    expectedSizeBytes: 1000,
    sha256: 'a' * 64,
    licenseId: 'apache-2.0',
    attribution: 'owner',
    description: 'テスト用カタログエントリ',
    recommendedContext: recommendedContext,
    maxOutputTokens: maxOutputTokens,
    estimatedRamBytes: 2000,
    preferredBackend: 'llama_cpp',
    preferredGpuLayers: preferredGpuLayers,
    capabilities: const ['text_generation'],
    reducedSafetyAlignment: false,
    platforms: const ['android'],
    isExperimental: false,
  );
}

const _summaryOutputA =
    '【あらすじ】\nモデルAのあらすじ一行目。\n二行目の要約。\n三行目の要約。\n'
    '【紹介】\nモデルAの紹介文です。\n'
    '【タグ】\nタグA1, タグA2, タグA3, タグA4, タグA5';

const _summaryOutputB =
    '【あらすじ】\nモデルBのあらすじ一行目。\n二行目の要約。\n三行目の要約。\n'
    '【紹介】\nモデルBの紹介文です。\n'
    '【タグ】\nタグB1, タグB2, タグB3, タグB4, タグB5';

final _userMsg = [
  LlmChatMessage.fromText(role: LlmChatRole.user, text: 'hello'),
];

void main() {
  group('LlmInferencePreset', () {
    test('既定値: context 8192 / 出力 512 / GPU 0', () {
      const d = LlmInferencePreset.defaults;
      expect(d.contextSize, 8192);
      expect(d.maxOutputTokens, 512);
      expect(d.gpuLayers, 0);
    });

    test('fromEntry: カタログ値を反映', () {
      final preset = LlmInferencePreset.fromEntry(
        _catalogEntry(
          recommendedContext: 8192,
          maxOutputTokens: 1024,
          preferredGpuLayers: -1,
        ),
      );
      expect(preset.contextSize, 8192);
      expect(preset.maxOutputTokens, 1024);
      expect(preset.gpuLayers, -1);
    });

    test('resolveForFileName: 絶対パスのベース名で一致（大小無視）', () {
      final preset = LlmInferencePreset.resolveForFileName(
        '/data/user/0/app/cache/models/llm/managed/sub-0/model-x.gguf',
        [_catalogEntry(fileName: 'Model-X.GGUF')],
      );
      expect(preset.contextSize, 4096);
      expect(preset.maxOutputTokens, 768);
      expect(preset.gpuLayers, -1);
    });

    test('resolveForFileName: 未一致 -> 既定値', () {
      final preset = LlmInferencePreset.resolveForFileName(
        'custom-model.gguf',
        [_catalogEntry()],
      );
      expect(preset.contextSize, LlmInferencePreset.defaults.contextSize);
      expect(
        preset.maxOutputTokens,
        LlmInferencePreset.defaults.maxOutputTokens,
      );
      expect(preset.gpuLayers, LlmInferencePreset.defaults.gpuLayers);
    });

    test('resolveForFileName: 空入力 -> 既定値', () {
      final preset = LlmInferencePreset.resolveForFileName('  ', [
        _catalogEntry(),
      ]);
      expect(preset.contextSize, LlmInferencePreset.defaults.contextSize);
      expect(
        preset.maxOutputTokens,
        LlmInferencePreset.defaults.maxOutputTokens,
      );
    });
  });

  group('LocalLlmService プリセットとメトリクス（M5）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('llm_m5_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String writeModel() {
      final f = File('${tmp.path}/model.gguf')..writeAsStringSync('gguf');
      return f.path;
    }

    test('preset: コンストラクタ値を保持', () {
      const preset = LlmInferencePreset(maxOutputTokens: 999);
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine([]),
        preset: preset,
      );
      expect(service.preset.maxOutputTokens, 999);
    });

    test('generationOptions: プリセットの maxOutputTokens を使用', () {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine([]),
        preset: LlmInferencePreset.fromEntry(
          _catalogEntry(maxOutputTokens: 768, preferredGpuLayers: -1),
        ),
      );
      expect(service.generationOptions.maxTokens, 768);
      expect(service.generationOptions.temp, 0.2);
      expect(service.generationOptions.topP, 0.9);
    });

    test('generate 成功: lastGenerationStats にトークン数と経過時間', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine(['あ', 'い', 'う']),
      );
      expect(service.lastGenerationStats, isNull);
      await service.loadModel(writeModel());
      await service.generate(_userMsg);
      final stats = service.lastGenerationStats;
      expect(stats, isNotNull);
      expect(stats!.generatedTokens, 3);
      expect(stats.elapsed.inMilliseconds, greaterThan(0));
      expect(stats.tokensPerSecond, greaterThan(0));
    });

    test('generate 失敗: lastGenerationStats は null のまま', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine(['x'], error: StateError('boom')),
      );
      await service.loadModel(writeModel());
      await expectLater(service.generate(_userMsg), throwsStateError);
      expect(service.lastGenerationStats, isNull);
    });
  });

  group('resolveModelPath: 消失済み選択モデル（M5）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('llm_m5p_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      debugDefaultTargetPlatformOverride = null;
    });

    test('prefs のファイルが不在: 設定をクリアして null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({
        LlmModelPaths.prefsKey: '${tmp.path}/gone.gguf',
      });
      expect(await LlmModelPaths.resolveModelPath(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(LlmModelPaths.prefsKey),
        isNull,
        reason: '消失済みモデルの設定はクリアされる',
      );
    });

    test('prefs のファイルが実在: そのパスを返し設定も維持', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final f = File('${tmp.path}/model.gguf')..writeAsStringSync('gguf');
      SharedPreferences.setMockInitialValues({LlmModelPaths.prefsKey: f.path});
      expect(await LlmModelPaths.resolveModelPath(), f.path);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LlmModelPaths.prefsKey), f.path);
    });
  });

  group('LlmSummaryService.generate: メタ情報（M5）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('llm_m5g_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String writeModel() {
      final f = File('${tmp.path}/m.gguf')..writeAsStringSync('gguf');
      return f.path;
    }

    test('modelLabel・時間・速度・日時が付与される', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine([_summaryOutputA]),
      );
      await service.loadModel(writeModel());
      final result = await LlmSummaryService.generate(
        service: service,
        title: 'T',
        body: '本文。',
        modelLabel: 'テストモデルA',
      );
      expect(result.modelLabel, 'テストモデルA');
      expect(result.generationMs, isNotNull);
      expect(result.generationMs, greaterThanOrEqualTo(0));
      expect(result.tokensPerSecond, isNotNull);
      expect(result.generatedAt, isNotNull);
    });

    test('modelLabel 未指定: null のまま', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine([_summaryOutputA]),
      );
      await service.loadModel(writeModel());
      final result = await LlmSummaryService.generate(
        service: service,
        title: 'T',
        body: '本文。',
      );
      expect(result.modelLabel, isNull);
    });
  });

  group('LlmSummarySheet: モデル切替とメタ表示（M5）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('llm_m5ui_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File writeModel(String name) =>
        File('${tmp.path}/$name')..writeAsStringSync('gguf');

    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('done: メタ行（モデル/生成日時/処理時間/速度）と再生成ボタン', (tester) async {
      final a = writeModel('model-a.gguf');
      await tester.pumpWidget(
        wrap(
          LlmSummarySheet(
            modelPath: a.path,
            title: 'T',
            description: 'D',
            resolveBody: () async => '本文。',
            availableModels: [LlmModelChoice(path: a.path, label: 'モデルA')],
            serviceFactory: () => LocalLlmService(
              engineFactory: (p) => _FakeEngine([_summaryOutputA]),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('このモデルで再生成'), findsOneWidget);
      expect(find.text('モデルA'), findsOneWidget, reason: 'メタ行のモデル名');
      expect(find.text('生成日時'), findsOneWidget);
      expect(find.text('処理時間'), findsOneWidget);
      expect(find.text('速度'), findsOneWidget);
      // 候補が1つだけなら切替ボタンは出さない
      expect(find.text('別モデルで再生成'), findsNothing);
    });

    testWidgets('別モデルで再生成: ピッカーで選んだモデルの結果に入れ替わる', (tester) async {
      final a = writeModel('model-a.gguf');
      final b = writeModel('model-b.gguf');
      LocalLlmService mkService() => LocalLlmService(
        engineFactory: (path) => _FakeEngine([
          path.endsWith('model-b.gguf') ? _summaryOutputB : _summaryOutputA,
        ]),
      );
      await tester.pumpWidget(
        wrap(
          LlmSummarySheet(
            modelPath: a.path,
            title: 'T',
            description: 'D',
            resolveBody: () async => '本文。',
            availableModels: [
              LlmModelChoice(path: a.path, label: 'モデルA'),
              LlmModelChoice(path: b.path, label: 'モデルB'),
            ],
            serviceFactory: mkService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('モデルAの紹介文です。'), findsOneWidget);
      expect(find.text('別モデルで再生成'), findsOneWidget);

      await tester.tap(find.text('別モデルで再生成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('別のモデルで再生成'), findsOneWidget);

      await tester.tap(find.text('モデルB'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('このモデルで再生成'), findsOneWidget);
      expect(find.text('モデルBの紹介文です。'), findsOneWidget);
      expect(find.text('モデルAの紹介文です。'), findsNothing);
      expect(find.text('モデルB'), findsOneWidget, reason: 'メタ行が切替後モデルに更新される');
    });

    testWidgets('このモデルで再生成: 同じモデルを再ロードして再生成', (tester) async {
      final a = writeModel('model-a.gguf');
      final b = writeModel('model-b.gguf');
      var engineLoads = 0;
      LocalLlmService mkService() => LocalLlmService(
        engineFactory: (path) {
          engineLoads++;
          return _FakeEngine([_summaryOutputA]);
        },
      );
      await tester.pumpWidget(
        wrap(
          LlmSummarySheet(
            modelPath: a.path,
            title: 'T',
            description: 'D',
            resolveBody: () async => '本文。',
            availableModels: [
              LlmModelChoice(path: a.path, label: 'モデルA'),
              LlmModelChoice(path: b.path, label: 'モデルB'),
            ],
            serviceFactory: mkService,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(engineLoads, 1);

      await tester.tap(find.text('このモデルで再生成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('このモデルで再生成'), findsOneWidget);
      expect(find.text('モデルAの紹介文です。'), findsOneWidget);
      expect(engineLoads, 2, reason: '同じモデルを再ロードして再生成');
    });
  });
}
