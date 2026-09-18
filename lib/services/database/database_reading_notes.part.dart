part of 'database_service.dart';

/// 読書メモ（reading_notes）CRUD
/// Phase 6a: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceReadingNotes extends DatabaseServiceSearchHistory {
  // ==========================================
  // READING NOTES (読書メモ・引用メモ、Phase N6 / DB v24)
  // ==========================================

  /// 読書メモを追加する。空白のみの [noteText] は拒否して -1 を返す。
  /// [anchorText] はメモ位置のページ先頭テキスト（引用表示用・任意）。
  Future<int> addReadingNote({
    required int workId,
    required int pageIndex,
    required String noteText,
    String workType = 'novel',
    String? anchorText,
  }) async {
    final text = noteText.trim();
    if (text.isEmpty) return -1;
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final anchor = (anchorText ?? '').trim();
    return await db.insert('reading_notes', {
      'work_id': workId,
      'work_type': workType,
      'page_index': pageIndex,
      'anchor_text': anchor.isEmpty ? null : anchor,
      'note_text': text,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 読書メモの本文を更新する。空白のみは拒否して -1 を返す。
  /// [anchorText] が指定された場合のみアンカーも更新する。
  Future<int> updateReadingNote(
    int id,
    String noteText, {
    String? anchorText,
  }) async {
    final text = noteText.trim();
    if (text.isEmpty) return -1;
    final db = await database;
    final values = <String, dynamic>{
      'note_text': text,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (anchorText != null) values['anchor_text'] = anchorText;
    return await db.update(
      'reading_notes',
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 読書メモを1件削除する。
  Future<int> deleteReadingNote(int id) async {
    final db = await database;
    return await db.delete('reading_notes', where: 'id = ?', whereArgs: [id]);
  }

  /// 読書メモの一覧を取得する（新しい順: created_at DESC, id DESC）。
  /// [workId] が指定された場合はその作品のみのメモを返す。
  Future<List<Map<String, dynamic>>> getReadingNotes({int? workId}) async {
    final db = await database;
    final rows = workId == null
        ? await db.query('reading_notes', orderBy: 'created_at DESC, id DESC')
        : await db.query(
            'reading_notes',
            where: 'work_id = ?',
            whereArgs: [workId],
            orderBy: 'created_at DESC, id DESC',
          );
    return List<Map<String, dynamic>>.from(rows);
  }
}
