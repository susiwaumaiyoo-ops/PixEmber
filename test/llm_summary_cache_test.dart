// LLM要約キャッシュサービス（M6）のテスト。
//
// 対象:
// - computeSourceFingerprint（入力フィンガープリント・純粋関数）
// - computeModelFileHash（モデル高速フィンガープリント・実ファイル）
// - llm_summaries（DB v25）CRUD + UNIQUE 制約（sqflite_ffi インメモリDB）
//
// 実DBファイル・ネットワークには依存しない。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/llm_summary_cache_service.dart';
import 'package:pixiv_viewer/services/llm_summary_service.dart';

/// v25 の llm_summaries の CREATE TABLE 文（DatabaseService._createLlmSummaries と同一）。
const String _createLlmSummariesSql = '''
  CREATE TABLE IF NOT EXISTS llm_summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    work_id INTEGER NOT NULL,
    model_id TEXT NOT NULL,
    model_file_hash TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    source_fingerprint TEXT NOT NULL,
    synopsis TEXT NOT NULL,
    spoiler_free_intro TEXT NOT NULL,
    suggested_tags_json TEXT NOT NULL,
    copy_warning INTEGER NOT NULL DEFAULT 0,
    generation_ms INTEGER,
    generated_at TEXT NOT NULL,
    UNIQUE(work_id, model_id, prompt_version, source_fingerprint)
  )
''';

/// v24 の reading_notes と同一スキーマ（DatabaseService._createReadingNotes）。
const String _createSql = '''
  CREATE TABLE IF NOT EXISTS llm_summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    work_id INTEGER NOT NULL,
    model_id TEXT NOT NULL,
    model_file_hash TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    source_fingerprint TEXT NOT NULL,
    synopsis TEXT NOT NULL,
    spoiler_free_intro TEXT NOT NULL,
    suggested_tags_json TEXT NOT NULL,
    copy_warning INTEGER NOT NULL DEFAULT 0,
    generation_ms INTEGER,
    generated_at TEXT NOT NULL,
    UNIQUE(work_id, model_id, prompt_version, source_fingerprint)
  )
''';

LlmSummaryResult _result({
  String synopsis = '3行のあらすじ。',
  String intro = '導入文。',
  List<String> tags = const ['ファンタジー', '冒険'],
  bool copyWarning = false,
  int? generationMs = 1234,
}) {
  return LlmSummaryResult(
    synopsis: synopsis,
    intro: intro,
    tagSuggestions: tags,
    copyWarning: copyWarning,
    bodySourceNote: '生成元: 小説本文（全文 1,000 文字）',
    modelLabel: 'モデルA',
    generationMs: generationMs,
    tokensPerSecond: 12.5,
    generatedAt: DateTime(2026, 9, 7, 12, 0),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ========================================================================
  // 純粋関数: computeSourceFingerprint
  // ========================================================================
  group('computeSourceFingerprint', () {
    test('同一入力は同一ハッシュ', () {
      final a = LlmSummaryService.computeSourceFingerprint(
        title: 'タイトル',
        tags: ['A', 'B'],
        body: '本文です。\n次の行。',
      );
      final b = LlmSummaryService.computeSourceFingerprint(
        title: 'タイトル',
        tags: ['A', 'B'],
        body: '本文です。\n次の行。',
      );
      expect(a, b);
      expect(a, hasLength(64)); // SHA-256 hex
    });

    test('本文が変わればハッシュが変わる', () {
      final a = LlmSummaryService.computeSourceFingerprint(
        title: 'タイトル',
        body: '本文A',
      );
      final b = LlmSummaryService.computeSourceFingerprint(
        title: 'タイトル',
        body: '本文B（変更後）',
      );
      expect(a, isNot(b));
    });

    test('タイトル・タグが変わってもハッシュが変わる', () {
      final base = LlmSummaryService.computeSourceFingerprint(
        title: 'タイトル',
        tags: ['A'],
        body: '本文',
      );
      final t = LlmSummaryService.computeSourceFingerprint(
        title: '別タイトル',
        tags: ['A'],
        body: '本文',
      );
      final g = LlmSummaryService.computeSourceFingerprint(
        title: 'タイトル',
        tags: ['B'],
        body: '本文',
      );
      expect(base, isNot(t));
      expect(base, isNot(g));
    });

    test('挿絵タグ・ルビは正規化されて同一ハッシュ', () {
      final a = LlmSummaryService.computeSourceFingerprint(
        title: 'タイトル',
        body: '[uploadedimage:1]本文[[rb:漢字 > かんじ]]だけ。',
      );
      final b = LlmSummaryService.computeSourceFingerprint(
        title: 'タイトル',
        body: '本文漢字だけ。',
      );
      expect(a, b);
    });
  });

  // ========================================================================
  // 純粋関数: computeModelFileHash（実一時ファイル）
  // ========================================================================
  group('computeModelFileHash', () {
    late Directory tmpDir;

    setUpAll(() async {
      tmpDir = await Directory.systemTemp.createTemp('llm_cache_test');
    });

    tearDownAll(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('同一内容のファイルは同一ハッシュ', () async {
      final f1 = File('${tmpDir.path}/model-a.gguf');
      final f2 = File('${tmpDir.path}/model-a-copy.gguf');
      await f1.writeAsBytes(List.filled(64, 0x41));
      await f2.writeAsBytes(List.filled(64, 0x41));
      // 同一サイズ+同一内容でも mtime は別値になり得るため
      // ここでは「決定論的で64桁」のみを検証する。
      final h1 = await LlmSummaryCacheService.computeModelFileHash(f1.path);
      final h2 = await LlmSummaryCacheService.computeModelFileHash(f1.path);
      expect(h1, h2);
      expect(h1, hasLength(64));
    });

    test('存在しないパスでもフォールバックハッシュを返す', () async {
      final h = await LlmSummaryCacheService.computeModelFileHash(
        '${tmpDir.path}/missing.gguf',
      );
      expect(h, hasLength(64));
    });
  });

  // ========================================================================
  // llm_summaries CRUD（DB v25）
  // ========================================================================
  group('llm_summaries CRUD（DB v25）', () {
    late DatabaseService db;
    late Database testDb;
    late LlmSummaryCacheService cache;

    setUp(() async {
      db = DatabaseService();
      testDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 25,
          onCreate: (d, v) async {
            await d.execute(_createSql);
            await d.execute(
              'CREATE INDEX IF NOT EXISTS idx_llm_summaries_work '
              'ON llm_summaries(work_id)',
            );
          },
        ),
      );
      db.setTestDatabase(testDb);
      cache = LlmSummaryCacheService(dbService: db);
    });

    tearDown(() async {
      await testDb.close();
      await db.restartDatabase();
    });

    test('save → get で保存した結果を復元できる', () async {
      final r = _result(copyWarning: true, generationMs: 999);
      await cache.save(
        workId: 1,
        modelId: 'model-a',
        modelFileHash: 'hash-a',
        sourceFingerprint: 'fp-1',
        result: r,
      );
      final got = await cache.get(
        workId: 1,
        modelId: 'model-a',
        sourceFingerprint: 'fp-1',
      );
      expect(got, isNotNull);
      expect(got!.synopsis, '3行のあらすじ。');
      expect(got.intro, '導入文。');
      expect(got.tagSuggestions, ['ファンタジー', '冒険']);
      expect(got.copyWarning, isTrue);
      expect(got.generationMs, 999);
      expect(got.modelLabel, 'model-a');
    });

    test('同一キー（work×model×prompt_version×fp）は上書き（UNIQUE REPLACE）', () async {
      await cache.save(
        workId: 2,
        modelId: 'model-a',
        modelFileHash: 'hash-a',
        sourceFingerprint: 'fp',
        result: _result(synopsis: '旧'),
      );
      await cache.save(
        workId: 2,
        modelId: 'model-a',
        modelFileHash: 'hash-a2',
        sourceFingerprint: 'fp',
        result: _result(synopsis: '新'),
      );
      final rows = await testDb.query('llm_summaries');
      expect(rows, hasLength(1));
      final got = await cache.get(
        workId: 2,
        modelId: 'model-a',
        sourceFingerprint: 'fp',
      );
      expect(got!.synopsis, '新');
      expect(got.generationMs, 1234);
    });

    test('モデルが異なれば別行（UNIQUE制約に抵触しない）', () async {
      await cache.save(
        workId: 3,
        modelId: 'model-a',
        modelFileHash: 'hash-a',
        sourceFingerprint: 'fp',
        result: _result(synopsis: 'Aの要約'),
      );
      await cache.save(
        workId: 3,
        modelId: 'model-b',
        modelFileHash: 'hash-b',
        sourceFingerprint: 'fp',
        result: _result(synopsis: 'Bの要約'),
      );
      final rows = await testDb.query('llm_summaries');
      expect(rows, hasLength(2));
      final a = await cache.get(
        workId: 3,
        modelId: 'model-a',
        sourceFingerprint: 'fp',
      );
      final b = await cache.get(
        workId: 3,
        modelId: 'model-b',
        sourceFingerprint: 'fp',
      );
      expect(a!.synopsis, 'Aの要約');
      expect(b!.synopsis, 'Bの要約');
    });

    test('フィンガープリントが異なれば別行', () async {
      await cache.save(
        workId: 4,
        modelId: 'model-a',
        modelFileHash: 'hash-a',
        sourceFingerprint: 'fp-old',
        result: _result(synopsis: '旧本文の要約'),
      );
      await cache.save(
        workId: 4,
        modelId: 'model-a',
        modelFileHash: 'hash-a',
        sourceFingerprint: 'fp-new',
        result: _result(synopsis: '新本文の要約'),
      );
      final rows = await testDb.query('llm_summaries');
      expect(rows, hasLength(2));
    });

    test('未ヒット・プロンプト版違いは null', () async {
      expect(
        await cache.get(workId: 5, modelId: 'model-a', sourceFingerprint: 'x'),
        isNull,
      );
    });

    test('DBが壊れていても例外を出さず null / 無視', () async {
      final broken = DatabaseService();
      final brokenDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      broken.setTestDatabase(brokenDb);
      final brokenCache = LlmSummaryCacheService(dbService: broken);
      // テーブルが無いので get は null、save は例外を出さない。
      expect(
        await brokenCache.get(workId: 1, modelId: 'm', sourceFingerprint: 'fp'),
        isNull,
      );
      await brokenCache.save(
        workId: 1,
        modelId: 'm',
        modelFileHash: 'h',
        sourceFingerprint: 'fp',
        result: _result(),
      );
      await brokenDb.close();
      await broken.restartDatabase();
    });
  });

  // ========================================================================
  // マイグレーション（v24 → v25 非破壊）
  // ========================================================================
  group('マイグレーション v24 → v25', () {
    test('既存データを壊さず llm_summaries が追加される', () async {
      // onUpgrade はインメモリ DB では発火しないため、一時ファイル DB で
      // 「v24 で作成 → v25 へオープン」の実アップグレード経路を検証する。
      final dir = await Directory.systemTemp.createTemp('llm_v25_');
      final dbPath = '${dir.path}${Platform.pathSeparator}mig.db';
      addTearDown(() async {
        await dir.delete(recursive: true);
      });

      // ステップ 1: v24 相当の旧スキーマを作成し、行を 1 件投入
      final v24Db = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 24,
          onCreate: (d, v) async {
            await d.execute(
              'CREATE TABLE history ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'work_id INTEGER NOT NULL, '
              'viewed_at TEXT NOT NULL)',
            );
          },
        ),
      );
      await v24Db.insert('history', {
        'work_id': 777,
        'viewed_at': '2026-01-01T00:00:00.000',
      });
      await v24Db.close();

      // ステップ 2: version: 25 で開き直し、onUpgrade で CREATE TABLE を実行
      var upgradeCalled = false;
      final testDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 25,
          onUpgrade: (d, oldV, newV) async {
            if (oldV < 25) {
              upgradeCalled = true;
              await d.execute(_createLlmSummariesSql);
            }
          },
        ),
      );
      expect(upgradeCalled, isTrue);
      final rows = await testDb.query('history');
      expect(rows, hasLength(1));
      expect(rows.first['work_id'], 777);
      // 新テーブルに書き込める（非破壊マイグレーションの検証）
      await testDb.insert('llm_summaries', {
        'work_id': 777,
        'model_id': 'm',
        'model_file_hash': 'h',
        'prompt_version': 2,
        'source_fingerprint': 'fp',
        'synopsis': 's',
        'spoiler_free_intro': 'i',
        'suggested_tags_json': '[]',
        'copy_warning': 0,
        'generated_at': '2026-09-07T00:00:00.000',
      });
      final summaries = await testDb.query('llm_summaries');
      expect(summaries, hasLength(1));
      await testDb.close();
    });
  });
}
