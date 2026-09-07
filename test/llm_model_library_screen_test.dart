// モデルライブラリ画面（M3）のテスト。
//
// - 初回 abliterated 同意ダイアログの表示と永続化
// - 3 グループ（推奨 / ダウンロード済み / カスタム）の分類
// - カスタムモデルの選択が prefs に永続されること
// ネットワーク接続・実モデルは使用しない（バンドル asset 読み込みのみ）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/screens/llm_model_library_screen.dart';
import 'package:pixiv_viewer/services/llm_model_catalog_service.dart';
import 'package:pixiv_viewer/services/local_llm_service.dart';
import 'package:pixiv_viewer/widgets/llm_model_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

// testWidgets は FakeAsync ゾーンで rootBundle の実 I/O を pump できないため、
// カタログ JSON は DI 注入する（pin 値は実 assets/llm_models.json と同一）。
const String fakeCatalogJson = r'''
{
  "catalog_version": 1,
  "models": [
    {
      "id": "qwen35-0-8b-abliterated-q4km",
      "displayName": "Qwen 3.5 0.8B Abliterated (Q4_K_M)",
      "family": "Qwen 3.5",
      "parameterCount": "0.8B",
      "quantization": "Q4_K_M",
      "repositoryId": "mradermacher/Huihui-Qwen3.5-0.8B-abliterated-GGUF",
      "revision": "2fabc82874616f44cdc494ec8ddc0e8ee10654b3",
      "fileName": "Huihui-Qwen3.5-0.8B-abliterated.Q4_K_M.gguf",
      "expectedSizeBytes": 527503840,
      "sha256": "411e0f945a5d57c63f33bcb5bfa4d5c2711d1ce28cb7635201ac0c311a7dfdf0",
      "licenseId": "apache-2.0",
      "description": "軽量モデル（fake）",
      "attribution": "Huihui / mradermacher",
      "reducedSafetyAlignment": true,
      "platforms": ["android"],
      "isRecommended": false,
      "highRamWarning": false
    },
    {
      "id": "qwen35-2b-abliterated-q4km",
      "displayName": "Qwen 3.5 2B Abliterated (Q4_K_M)",
      "family": "Qwen 3.5",
      "parameterCount": "2B",
      "quantization": "Q4_K_M",
      "repositoryId": "mradermacher/Huihui-Qwen3.5-2B-abliterated-GGUF",
      "revision": "f36848fead3fdda244cf60195c46993d23183d4c",
      "fileName": "Huihui-Qwen3.5-2B-abliterated.Q4_K_M.gguf",
      "expectedSizeBytes": 1270809024,
      "sha256": "aa25eea787afe56a097268f7ed3460cb623e1901d2e89cd2b654cabb42f80636",
      "licenseId": "apache-2.0",
      "description": "標準推奨（fake）",
      "attribution": "Huihui / mradermacher",
      "reducedSafetyAlignment": true,
      "platforms": ["android"],
      "isRecommended": true,
      "highRamWarning": false
    },
    {
      "id": "qwen35-4b-abliterated-q4ks",
      "displayName": "Qwen 3.5 4B Abliterated (Q4_K_S)",
      "family": "Qwen 3.5",
      "parameterCount": "4B",
      "quantization": "Q4_K_S",
      "repositoryId": "mradermacher/Huihui-Qwen3.5-4B-abliterated-GGUF",
      "revision": "4a5daa6fbefca5fe822dc65fcb95cc4576fa9720",
      "fileName": "Huihui-Qwen3.5-4B-abliterated.Q4_K_S.gguf",
      "expectedSizeBytes": 2557007168,
      "sha256": "3215d8dc35d2e190a7e0a592cb03be6c46c2a14a258ae35a9e738365084eba27",
      "licenseId": "apache-2.0",
      "description": "高品質・高RAM（fake）",
      "attribution": "Huihui / mradermacher",
      "reducedSafetyAlignment": true,
      "platforms": ["android"],
      "isRecommended": false,
      "highRamWarning": true
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory modelDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('llm_lib_test_');
    modelDir = Directory('${tmp.path}/models/llm');
    await modelDir.create(recursive: true);
    // カタログの 2B ファイル（ダウンロード済みの判定）。
    await File(
      '${modelDir.path}/Huihui-Qwen3.5-2B-abliterated.Q4_K_M.gguf',
    ).writeAsString('fake');
    // カスタム GGUF。
    await File('${modelDir.path}/my-custom.gguf').writeAsString('fake');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    // in-memory ストアを空に戻す（shared_preferences 2.5.x には
    // resetMockInitialValues は無いため、空の mock で再設定する）。
    SharedPreferences.setMockInitialValues({});
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  Widget app() {
    // 注意: SharedPreferences mock は各テストが pumpWidget 前に
    // setMockInitialValues で確定させること（FakeAsync ゾーンでは
    // 未 mock の実チャネル I/O は pump されず待機し続けるため）。
    return MaterialApp(
      home: LlmModelLibraryScreen(
        catalogService: LlmModelCatalogService(
          jsonReader: () async => fakeCatalogJson,
        ),
        modelDirProvider: () async => modelDir,
      ),
    );
  }

  /// ListView の全カードを可視範囲に収め、オフスクリーンのタップを回避する
  /// （settings_screen_test と同様のviewport拡大）。
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  testWidgets('初回: abliterated 同意ダイアログ→同意で3グループ表示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpApp(tester);

    expect(find.text('abliterated モデルについて'), findsOneWidget);
    await tester.tap(find.text('了解しました'));
    await tester.pumpAndSettle();

    // 同意が永続化されたこと。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kLlmAbliteratedConsentKey), isTrue);

    // 3 グループのヘッダ。
    expect(find.text('推奨モデル'), findsOneWidget);
    // 「ダウンロード済み」バッジと同名のテキストがあるため、
    // セクションヘッダは先頭1件として確認する。
    expect(
      find.text('ダウンロード済み').first,
      findsOneWidget,
      reason: 'セクションヘッダ（2Bバッジと同名のため先頭1件）',
    );
    expect(find.text('インポート済みカスタムモデル'), findsOneWidget);

    // 0.8B / 4B は未ダウンロード → 推奨モデル。
    expect(find.text('Qwen 3.5 0.8B Abliterated (Q4_K_M)'), findsOneWidget);
    expect(find.text('Qwen 3.5 4B Abliterated (Q4_K_S)'), findsOneWidget);
    // 2B はファイル名がローカルに存在 → ダウンロード済み。
    expect(find.text('Qwen 3.5 2B Abliterated (Q4_K_M)'), findsOneWidget);
    expect(find.text('ダウンロード済み'), findsWidgets);
    // カスタム。
    expect(find.text('my-custom.gguf'), findsOneWidget);

    // 未ダウンロードカードにはダウンロードボタン、ダウンロード済みには選択ボタン。
    final pending2b = find.ancestor(
      of: find.text('Qwen 3.5 4B Abliterated (Q4_K_S)'),
      matching: find.byType(LlmModelCard),
    );
    expect(
      find.descendant(of: pending2b, matching: find.text('ダウンロード')),
      findsOneWidget,
    );
    final downloaded2b = find.ancestor(
      of: find.text('Qwen 3.5 2B Abliterated (Q4_K_M)'),
      matching: find.byType(LlmModelCard),
    );
    expect(
      find.descendant(of: downloaded2b, matching: find.text('モデルとして選択')),
      findsOneWidget,
    );
  });

  testWidgets('同意済み2回目: ダイアログは表示されない', (tester) async {
    SharedPreferences.setMockInitialValues({kLlmAbliteratedConsentKey: true});
    await pumpApp(tester);

    expect(find.text('abliterated モデルについて'), findsNothing);
    expect(find.text('推奨モデル'), findsOneWidget);
    expect(find.text('my-custom.gguf'), findsOneWidget);
  });

  testWidgets('カスタムモデル選択: prefs にパスが永続される', (tester) async {
    SharedPreferences.setMockInitialValues({kLlmAbliteratedConsentKey: true});
    await pumpApp(tester);

    final card = find.ancestor(
      of: find.text('my-custom.gguf'),
      matching: find.byType(LlmModelCard),
    );
    await tester.tap(
      find.descendant(of: card, matching: find.text('モデルとして選択')),
    );
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(LlmModelPaths.prefsKey);
    expect(saved, isNotNull);
    expect(saved!.endsWith('my-custom.gguf'), isTrue);

    // カードが「現在のモデル」に変わる。
    expect(
      find.descendant(of: card, matching: find.text('現在のモデル')),
      findsOneWidget,
    );
  });

  testWidgets('詳細ダイアログ: pin 情報（revision/SHA-256）を表示', (tester) async {
    SharedPreferences.setMockInitialValues({kLlmAbliteratedConsentKey: true});
    await pumpApp(tester);

    final card = find.ancestor(
      of: find.text('Qwen 3.5 2B Abliterated (Q4_K_M)'),
      matching: find.byType(LlmModelCard),
    );
    await tester.tap(find.descendant(of: card, matching: find.text('詳細')));
    await tester.pumpAndSettle();

    // ダイアログの本文は1つの Text として描画されるため部分一致で検証。
    expect(
      find.textContaining('Revision: f36848fead3fdda244cf60195c46993d23183d4c'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'SHA-256: aa25eea787afe56a097268f7ed3460cb623e1901d2e89cd2b654cabb42f80636',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('ライセンス: apache-2.0'), findsOneWidget);
  });
}
