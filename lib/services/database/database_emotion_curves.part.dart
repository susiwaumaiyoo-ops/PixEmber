part of 'database_service.dart';

/// 小説の感情曲線（emotion_curves）CRUD
/// Phase 6e: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceEmotionCurves extends DatabaseServiceImageVectors {
  // ==========================================================================
  // 小説の感情曲線（emotion_curves）CRUD — Phase C (v23)
  // ==========================================================================

  /// 小説の感情曲線キャッシュを保存（UPSERT）。
  /// 本文から再生成可能なため Google Drive バックアップ対象外。
  Future<int> saveEmotionCurve({
    required int workId,
    required String modelId,
    required String chunksJson,
  }) async {
    final db = await database;
    return await db.insert('emotion_curves', {
      'work_id': workId,
      'model_id': modelId,
      'chunks_json': chunksJson,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 指定小説の感情曲線キャッシュを取得（無い場合は null）。
  Future<Map<String, dynamic>?> getEmotionCurve(int workId) async {
    final db = await database;
    final rows = await db.query(
      'emotion_curves',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  /// 指定小説の感情曲線キャッシュを削除。
  Future<int> deleteEmotionCurve(int workId) async {
    final db = await database;
    return await db.delete(
      'emotion_curves',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }
}
