part of 'database_service.dart';

/// TTS 読み上げ位置（tts_reading_positions）CRUD
/// Phase 6b: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceTts extends DatabaseServiceReadingNotes {
  // ==========================================================================
  // TTS読み上げ位置（tts_reading_positions）CRUD - Phase 3 (v18)
  // ==========================================================================

  /// TTS読み上げの再開位置を保存（UPSERT）。
  Future<int> saveTtsPosition({
    required int workId,
    required int chunkIndex,
    required int pageIndex,
  }) async {
    final db = await database;
    return await db.insert('tts_reading_positions', {
      'work_id': workId,
      'chunk_index': chunkIndex,
      'page_index': pageIndex,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// TTS読み上げの再開位置を取得（なければ null）。
  Future<Map<String, dynamic>?> getTtsPosition(int workId) async {
    final db = await database;
    final result = await db.query(
      'tts_reading_positions',
      where: 'work_id = ?',
      whereArgs: [workId],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  /// TTS読み上げ位置を削除（読了時等）。
  Future<int> deleteTtsPosition(int workId) async {
    final db = await database;
    return await db.delete(
      'tts_reading_positions',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }
}
