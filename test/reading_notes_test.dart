// 読書メモ・引用メモ（非AI機能パック Phase N6）のユニットテスト。
//
// 対象:
// - 純粋関数: extractAnchorText（ページ本文からの引用アンカー抽出）
// - reading_notes（DB v24）CRUD（sqflite_ffi インメモリDB）
//
// 実DBファイル・ネットワーク・ファイルシステムには依存しない。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/reading_notes_service.dart';

/// v24 の reading_notes と同一スキーマ（DatabaseService._createReadingNotes）。
const String _createSql = '''
  CREATE TABLE IF NOT EXISTS reading_notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    work_id INTEGER NOT NULL,
    work_type TEXT NOT NULL DEFAULT 'novel',
    page_index INTEGER NOT NULL DEFAULT 0,
    anchor_text TEXT,
    note_text TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
''';

void main() {
  // ========================================================================
  // 純粋関数: extractAnchorText
  // ========================================================================
  group('extractAnchorText', () {
    test('null / 空文字 / 空白のみは null', () {
      expect(extractAnchorText(null), isNull);
      expect(extractAnchorText(''), isNull);
      expect(extractAnchorText('   \n  \t\n '), isNull);
    });

    test('先頭非空行（trim後）を返す', () {
      expect(extractAnchorText('  \nこんにちは世界\n'), 'こんにちは世界');
    });

    test('長文は maxLength で切り詰め末尾に省略記号', () {
      final long = 'あ' * 80;
      final result = extractAnchorText(long, maxLength: 20);
      expect(result, hasLength(21));
      expect(result!.endsWith('…'), isTrue);
    });

    test('境界値: maxLength ちょうどは切らない / 1字超過は切る', () {
      expect(extractAnchorText('abcd', maxLength: 4), 'abcd');
      expect(extractAnchorText('abcdefgh', maxLength: 3), 'abc…');
    });
  });

  // ========================================================================
  // reading_notes CRUD（DB v24）
  // ========================================================================
  group('reading_notes CRUD（DB v24）', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    late DatabaseService db;
    late Database testDb;

    setUp(() async {
      db = DatabaseService();
      testDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 24,
          onCreate: (d, v) async {
            await d.execute(_createSql);
            await d.execute(
              'CREATE INDEX IF NOT EXISTS idx_reading_notes_work '
              'ON reading_notes(work_id)',
            );
          },
        ),
      );
      db.setTestDatabase(testDb);
    });

    tearDown(() async {
      await testDb.close();
      await db.restartDatabase();
    });

    test('追加は id を返し、フィールドを保存（work_type デフォルト novel）', () async {
      final id = await db.addReadingNote(
        workId: 5,
        pageIndex: 3,
        noteText: 'メモ本文',
        anchorText: '  行頭テキスト  ',
      );
      expect(id, greaterThan(0));
      final rows = await db.getReadingNotes(workId: 5);
      expect(rows, hasLength(1));
      expect(rows.first['id'], id);
      expect(rows.first['work_id'], 5);
      expect(rows.first['work_type'], 'novel');
      expect(rows.first['page_index'], 3);
      expect(rows.first['anchor_text'], '行頭テキスト');
      expect(rows.first['note_text'], 'メモ本文');
    });

    test('アンカー未指定は null、本文は trim される', () async {
      final id = await db.addReadingNote(
        workId: 6,
        pageIndex: 0,
        noteText: '  メモ  ',
      );
      expect(id, greaterThan(0));
      final rows = await db.getReadingNotes();
      expect(rows.first['note_text'], 'メモ');
      expect(rows.first['anchor_text'], isNull);
    });

    test('空白のみのメモは拒否（-1）され保存されない', () async {
      final id = await db.addReadingNote(
        workId: 7,
        pageIndex: 1,
        noteText: '   ',
      );
      expect(id, -1);
      expect(await db.getReadingNotes(), isEmpty);
    });

    test('getReadingNotes は workId でフィルタする', () async {
      await db.addReadingNote(workId: 11, pageIndex: 0, noteText: 'a');
      await db.addReadingNote(workId: 22, pageIndex: 0, noteText: 'b');
      final rows = await db.getReadingNotes(workId: 11);
      expect(rows, hasLength(1));
      expect(rows.first['work_id'], 11);
      expect(await db.getReadingNotes(), hasLength(2));
    });

    test('一覧は新しい順（created_at DESC, id DESC）', () async {
      await db.addReadingNote(workId: 33, pageIndex: 0, noteText: 'first');
      await db.addReadingNote(workId: 33, pageIndex: 1, noteText: 'second');
      final rows = await db.getReadingNotes(workId: 33);
      expect(rows, hasLength(2));
      expect(rows.first['note_text'], 'second');
      expect(rows.last['note_text'], 'first');
    });

    test('更新は本文を書き換え、空白のみは拒否', () async {
      final id = await db.addReadingNote(
        workId: 44,
        pageIndex: 2,
        noteText: 'original',
      );
      expect(await db.updateReadingNote(id, '   '), -1);
      expect((await db.getReadingNotes()).first['note_text'], 'original');
      expect(await db.updateReadingNote(id, 'edited'), 1);
      expect((await db.getReadingNotes()).first['note_text'], 'edited');
    });

    test('削除は該当行を消す（存在しない id は 0）', () async {
      final id = await db.addReadingNote(
        workId: 55,
        pageIndex: 0,
        noteText: 'del-me',
      );
      expect(await db.deleteReadingNote(id), 1);
      expect(await db.getReadingNotes(), isEmpty);
      expect(await db.deleteReadingNote(id), 0);
    });
  });
}
