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

      expect(catalog.catalogVersion, 1);
      expect(catalog.entries.length, 5);
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

      // 2B = 推奨モデル
      final rec = catalog.recommended;
      expect(rec, isNotNull);
      expect(rec!.parameterCount, '2B');
      expect(rec.id, 'qwen35-2b-abliterated-q4km');
      expect(
        rec.repositoryId,
        'mradermacher/Huihui-Qwen3.5-2B-abliterated-GGUF',
      );
      expect(rec.revision, 'f36848fead3fdda244cf60195c46993d23183d4c');
      expect(rec.fileName, 'Huihui-Qwen3.5-2B-abliterated.Q4_K_M.gguf');
      expect(rec.expectedSizeBytes, 1270809024);
      expect(
        rec.sha256,
        'aa25eea787afe56a097268f7ed3460cb623e1901d2e89cd2b654cabb42f80636',
      );
      expect(rec.licenseId, 'apache-2.0');

      // 0.8B（CPU 優先）
      final e08 = catalog.entries.firstWhere((e) => e.parameterCount == '0.8B');
      expect(e08.revision, '2fabc82874616f44cdc494ec8ddc0e8ee10654b3');
      expect(
        e08.sha256,
        '411e0f945a5d57c63f33bcb5bfa4d5c2711d1ce28cb7635201ac0c311a7dfdf0',
      );
      expect(e08.expectedSizeBytes, 527503840);
      expect(e08.preferredGpuLayers, 0, reason: '0.8B は CPU 優先');
      expect(e08.maxOutputTokens, 512);

      // 4B（高 RAM 警告）
      final e4 = catalog.entries.firstWhere((e) => e.parameterCount == '4B');
      expect(e4.revision, '4a5daa6fbefca5fe822dc65fcb95cc4576fa9720');
      expect(
        e4.sha256,
        '3215d8dc35d2e190a7e0a592cb03be6c46c2a14a258ae35a9e738365084eba27',
      );
      expect(e4.expectedSizeBytes, 2557007168);
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
