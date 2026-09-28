// Phase 18a: getReadLaterList の optional query 引数の契約テスト。
//
// sqflite_common_ffi のインメモリ DB で read_later にサンプル行を挿入し、
// - query が null / 空文字 / 空白のみのとき 既存の挙動と同一であること
// - query が非空のとき title / author_name / tags_json の部分一致で絞り込まれること
// - status フィルタと正しく AND 結合されること
// - LIKE の既定挙動（ASCII 大文字小文字無視 / ワイルドカードはエスケープしない）
// を検証する。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';

/// read_later スキーマ（database_schema.part.dart の _createReadLater と同一構造）。
const String _createReadLater = '''
  CREATE TABLE IF NOT EXISTS read_later (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    work_id INTEGER NOT NULL UNIQUE,
    title TEXT,
    author_name TEXT,
    author_id INTEGER,
    cover_url TEXT,
    text_length INTEGER,
    tags_json TEXT,
    x_restrict INTEGER DEFAULT 0,
    status INTEGER DEFAULT 0,
    added_at TEXT,
    last_opened_at TEXT,
    finished_at TEXT,
    progress REAL DEFAULT 0.0,
    last_page INTEGER DEFAULT 0,
    last_offset INTEGER DEFAULT 0
  )
''';

Future<void> insertRow(
  Database db, {
  required int workId,
  required String title,
  required String author,
  required String tagsJson,
  required int status,
  required String addedAt,
}) async {
  await db.insert('read_later', {
    'work_id': workId,
    'title': title,
    'author_name': author,
    'tags_json': tagsJson,
    'status': status,
    'added_at': addedAt,
  });
}

List<int> workIds(List<Map<String, dynamic>> rows) =>
    rows.map((r) => r['work_id'] as int).toList();

void main() {
  late DatabaseService db;
  late Database testDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = DatabaseService();
    testDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (d, _) => d.execute(_createReadLater),
      ),
    );
    db.setTestDatabase(testDb);
    await insertRow(
      testDb,
      workId: 101,
      title: '紅茶の探偵譚',
      author: '田中ヨコ',
      tagsJson: '["romance","mystery"]',
      status: 0,
      addedAt: '2026-01-01T00:00:00Z',
    );
    await insertRow(
      testDb,
      workId: 102,
      title: '剣の章',
      author: '佐藤ハルキ',
      tagsJson: '["fantasy","action"]',
      status: 1,
      addedAt: '2026-01-02T00:00:00Z',
    );
    await insertRow(
      testDb,
      workId: 103,
      title: '赤い空の観測所',
      author: '佐藤ハルキ',
      tagsJson: '["romance","daily life"]',
      status: 2,
      addedAt: '2026-01-03T00:00:00Z',
    );
  });

  tearDown(() async {
    await testDb.close();
    await db.restartDatabase();
  });

  group('query が空の場合（既存の挙動と同一）', () {
    test('query: null は引数なしと同一（全3件・added_at DESC）', () async {
      final all = await db.getReadLaterList();
      final noQuery = await db.getReadLaterList(query: null);
      expect(workIds(noQuery), workIds(all));
      expect(workIds(noQuery), [103, 102, 101]);
    });

    test("query: '' は全件", () async {
      expect(workIds(await db.getReadLaterList(query: '')), [103, 102, 101]);
    });

    test('空白のみの query は絞り込まず全件', () async {
      expect(workIds(await db.getReadLaterList(query: '   ')), [103, 102, 101]);
    });
  });

  group('カラム毎の部分一致', () {
    test('title の部分一致で絞り込む', () async {
      expect(workIds(await db.getReadLaterList(query: '探偵譚')), [101]);
      expect(workIds(await db.getReadLaterList(query: '剣の')), [102]);
      // 2行にマッチしても降順を維持する。
      expect(workIds(await db.getReadLaterList(query: '赤い')), [103]);
      expect(workIds(await db.getReadLaterList(query: '空')), [103]);
    });

    test('author_name の部分一致で絞り込む', () async {
      expect(workIds(await db.getReadLaterList(query: '田中')), [101]);
      expect(workIds(await db.getReadLaterList(query: '佐藤')), [103, 102]);
    });

    test('tags_json の部分一致で絞り込む', () async {
      expect(workIds(await db.getReadLaterList(query: 'romance')), [103, 101]);
      expect(workIds(await db.getReadLaterList(query: 'action')), [102]);
    });

    test('どのカラムにも該当しない場合は空', () async {
      expect(await db.getReadLaterList(query: '存在しないタイトル'), isEmpty);
    });
  });

  group('status との組み合わせ', () {
    test('status と query の両方を満たす行のみを返す', () async {
      // status 1（読書中）∩ '佐藤' → 102 のみ（103 は読了=2）。
      expect(workIds(await db.getReadLaterList(status: 1, query: '佐藤')), [102]);
      expect(workIds(await db.getReadLaterList(status: 2, query: '佐藤')), [103]);
      // 条件の不一致なら空。
      expect(await db.getReadLaterList(status: 1, query: '田中'), isEmpty);
    });

    test('status のみ指定は従来どおり', () async {
      expect(workIds(await db.getReadLaterList(status: 0)), [101]);
    });
  });

  group('LIKE の挙動', () {
    test('ASCII は大文字小文字を区別しない（SQLite LIKE 既定）', () async {
      expect(workIds(await db.getReadLaterList(query: 'ROMANCE')), [103, 101]);
    });

    test('query 内のワイルドカードは LIKE のワイルドカードとして効く（エスケープしない）', () async {
      // '%' は LIKE で任意文字列を意味するため全行にマッチする。
      // 実装はエスケープを行わない。このテストはその挙動を固定する。
      // （検索 UI では % / _ の入力は稀であり、過剰実装を避けた）
      expect(workIds(await db.getReadLaterList(query: '%')), [103, 102, 101]);
    });
  });
}
