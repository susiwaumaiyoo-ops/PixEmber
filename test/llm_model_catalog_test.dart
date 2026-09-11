// LLM モデルカタログ（M2）のテスト。
//
// - JSON パース / 検証ルールの純粋関数テスト
// - バンドル assets/llm_models.json の pin 値（revision/size/SHA-256）検証
// ネットワーク接続は行わない（バンドル asset 読み込みのみ）。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/models/llm_model_catalog_entry.dart';
import 'package:pixiv_viewer/services/llm_model_catalog_service.dart';

Map<String, dynamic> _entry(Map<String, dynamic> overrides) => {
  'id': 'test-model',
  'displayName': 'Test Model',
  'family': 'Test',
  'parameterCount': '1B',
  'quantization': 'Q4_K_M',
  'repositoryId': 'org/repo',
  'revision': 'a' * 40,
  'fileName': 'test.Q4_K_M.gguf',
  'expectedSizeBytes': 100000,
  'sha256': 'b' * 64,
  'licenseId': 'apache-2.0',
  'attribution': 'test',
  'description': 'test model',
  'recommendedContext': 4096,
  'maxOutputTokens': 512,
  'estimatedRamBytes': 2048,
  'preferredBackend': 'llama_cpp',
  'preferredGpuLayers': 0,
  'capabilities': ['text_generation'],
  'reducedSafetyAlignment': false,
  'platforms': ['android'],
  'isExperimental': true,
  'isRecommended': false,
  'highRamWarning': false,
  ...overrides,
};

void main() {
  group('LlmModelCatalogEntry.fromJson', () {
    test('完全なエントリは isVerified', () {
      final e = LlmModelCatalogEntry.fromJson(_entry({}));
      expect(e.id, 'test-model');
      expect(e.isVerified, isTrue);
      expect(e.supportsMultimodal, isFalse);
      expect(e.supportsPlatform('android'), isTrue);
      expect(e.supportsPlatform('ios'), isFalse);
    });

    test('SHA-256 不正（短すぎる）は未検証', () {
      final e = LlmModelCatalogEntry.fromJson(_entry({'sha256': 'abc123'}));
      expect(e.isVerified, isFalse);
    });

    test('revision 不正（main ブランチ指定）は未検証', () {
      final e = LlmModelCatalogEntry.fromJson(_entry({'revision': 'main'}));
      expect(e.isVerified, isFalse);
    });

    test('サイズ 0 は未検証', () {
      final e = LlmModelCatalogEntry.fromJson(_entry({'expectedSizeBytes': 0}));
      expect(e.isVerified, isFalse);
    });

    test('GGUF 以外（非 gguf 拡張子）は未検証', () {
      final e = LlmModelCatalogEntry.fromJson(
        _entry({'fileName': 'test.model.safetensors'}),
      );
      expect(e.isVerified, isFalse);
    });

    test('repositoryId 不正は未検証', () {
      final e = LlmModelCatalogEntry.fromJson(_entry({'repositoryId': 'x'}));
      expect(e.isVerified, isFalse);
    });

    test('downloadUrl は revision で不変 pin', () {
      final e = LlmModelCatalogEntry.fromJson(_entry({}));
      expect(
        e.downloadUrl,
        'https://huggingface.co/org/repo/resolve/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/test.Q4_K_M.gguf',
      );
    });
  });

  group('LlmModelCatalog.parse / Service', () {
    test('推奨モデルは isRecommended && isVerified のみ', () {
      final raw = jsonEncode({
        'catalog_version': 7,
        'models': [
          _entry({'id': 'bad', 'isRecommended': true, 'sha256': 'nope'}),
          _entry({'id': 'good', 'isRecommended': true}),
        ],
      });
      final catalog = LlmModelCatalogService.parse(raw);
      expect(catalog.catalogVersion, 7);
      expect(catalog.downloadable.length, 1);
      expect(catalog.recommended?.id, 'good');
    });

    test('未検証エントリは downloadable から除外', () {
      final raw = jsonEncode({
        'catalog_version': 1,
        'models': [
          _entry({'id': 'ok'}),
          _entry({'id': 'noshape', 'sha256': ''}),
          _entry({'id': 'noSize', 'expectedSizeBytes': 0}),
        ],
      });
      final catalog = LlmModelCatalogService.parse(raw);
      expect(catalog.entries.length, 3);
      expect(catalog.downloadable.map((e) => e.id), ['ok']);
    });

    test('models キー欠落 → 空カタログ（例外なし）', () {
      final catalog = LlmModelCatalogService.parse('{"catalog_version": 1}');
      expect(catalog.entries, isEmpty);
      expect(catalog.recommended, isNull);
    });

    test('トップレベルがオブジェクト以外 → FormatException', () {
      expect(() => LlmModelCatalogService.parse('[]'), throwsFormatException);
    });

    test('jsonReader 注入でオフラインロード', () async {
      final raw = jsonEncode({
        'catalog_version': 2,
        'models': [_entry({})],
      });
      final service = LlmModelCatalogService(jsonReader: () async => raw);
      final catalog = await service.load();
      expect(catalog.catalogVersion, 2);
      expect(catalog.entries.first.isVerified, isTrue);
    });
  });

  group('バンドル assets/llm_models.json', () {
    test('Qwen 3.5 3 点 + Gemma 4 2 点が pin 済みで検証通過', () async {
      // rootBundle にはテストバインディング初期化が必要。
      TestWidgetsFlutterBinding.ensureInitialized();
      final catalog = await LlmModelCatalogService().load();

      expect(catalog.catalogVersion, 2);
      expect(catalog.entries.length, 5);
      // C-1: 全 5 点が i1-Q4_0（NPU 対応）で統一されていること。
      for (final e in catalog.entries) {
        expect(e.quantization, 'i1-Q4_0', reason: '${e.id} は Q4_0 化');
        expect(e.npuCompatible, isTrue, reason: '${e.id} は HTP 対応');
        expect(e.recommendedContext, 8192);
      }
      expect(catalog.downloadable.length, 5, reason: '全 5 点が検証済みのはず');
      final gemma = catalog.entries
          .where((e) => e.family.startsWith('Gemma'))
          .toList(growable: false);
      expect(gemma.map((e) => e.id), [
        'gemma4-e2b-it-abliterated-q4km',
        'gemma4-e4b-it-abliterated-q4km',
      ]);
      // Gemma 4 の GGUF architecture が llama.cpp 対応である前提の確認:
      // chat template は Qwen 用 ChatML を強制しない（カタログはプリセットのみ持つ）。
      for (final e in gemma) {
        expect(e.isVerified, isTrue, reason: '${e.id} は pin 済み');
        expect(e.isRecommended, isFalse, reason: '${e.id} は実験・実機未検証');
        expect(e.supportsMultimodal, isFalse, reason: 'mmproj 非対応（テキスト要約専用）');
        expect(e.preferredBackend, 'llama_cpp');
      }
      // E4B は高 RAM 向けの実験候補（高RAM警告を表示する）。
      expect(
        catalog.entries
            .firstWhere((e) => e.id == 'gemma4-e4b-it-abliterated-q4km')
            .highRamWarning,
        isTrue,
      );

      // 2B = 推奨モデル（i1-Q4_0・NPU 対応）
      final rec = catalog.recommended;
      expect(rec, isNotNull);
      expect(rec!.parameterCount, '2B');
      expect(rec.id, 'qwen35-2b-abliterated-q4km');
      expect(rec.quantization, 'i1-Q4_0');
      expect(rec.npuCompatible, isTrue, reason: 'Q4_0 は HTP 対応');
      expect(rec.recommendedContext, 8192, reason: '長文対応で 8192');
      expect(
        rec.repositoryId,
        'mradermacher/Huihui-Qwen3.5-2B-abliterated-i1-GGUF',
      );
      expect(rec.revision, '47af544aea4a32d3bb4b3f73218598df425bbdc2');
      expect(rec.fileName, 'Huihui-Qwen3.5-2B-abliterated.i1-Q4_0.gguf');
      expect(rec.expectedSizeBytes, 1204847328);
      expect(
        rec.sha256,
        'b044ec56852762ecc820d98cd6f142f0461e177a813df45115c81e681328a865',
      );
      expect(rec.licenseId, 'apache-2.0');

      // 0.8B（CPU 優先）
      final e08 = catalog.entries.firstWhere((e) => e.parameterCount == '0.8B');
      expect(e08.quantization, 'i1-Q4_0');
      expect(e08.revision, '4fade25176da43736bf43f5f81433f1aff0e741f');
      expect(
        e08.sha256,
        '6e2064158251b99f41cb90312b1d4a187a9e296b6bf9fc89a7953acac0a12a52',
      );
      expect(e08.expectedSizeBytes, 502141696);
      expect(e08.preferredGpuLayers, 0, reason: '0.8B は CPU 優先');
      expect(e08.maxOutputTokens, 512);

      // 4B（高 RAM 警告）
      final e4 = catalog.entries.firstWhere((e) => e.parameterCount == '4B');
      expect(e4.quantization, 'i1-Q4_0');
      expect(e4.revision, 'd9b9a9650c8c52635ab327bb8ceea77bc705e6d7');
      expect(
        e4.sha256,
        '5816c76daaa47ae1e94e7b4178472ae4d2a5eddb2d702b3f76271c3f46aa1a5f',
      );
      expect(e4.expectedSizeBytes, 2549798464);
      expect(e4.highRamWarning, isTrue);
      expect(e4.maxOutputTokens, 1024);

      // 共通: abliterated 警告 / mmproj なし / revision pin URL
      for (final e in catalog.entries) {
        expect(
          e.reducedSafetyAlignment,
          isTrue,
          reason: 'abliterated モデルは初回同意ダイアログが必要',
        );
        expect(e.supportsMultimodal, isFalse, reason: 'mmproj は含めない');
        expect(e.downloadUrl, contains('/resolve/${e.revision}/'));
        expect(e.platforms, contains('android'));
      }
    });
  });

  group('formatBytes', () {
    test('1000 進表記で MB/GB を整形', () {
      expect(LlmModelCatalogService.formatBytes(512), '512 B');
      expect(LlmModelCatalogService.formatBytes(2048), '2.0 KB');
      expect(LlmModelCatalogService.formatBytes(527503840), '527.5 MB');
      expect(LlmModelCatalogService.formatBytes(1270809024), '1.27 GB');
      expect(LlmModelCatalogService.formatBytes(2557007168), '2.56 GB');
    });
  });
}
