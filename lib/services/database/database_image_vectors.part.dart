part of 'database_service.dart';

/// 視覚類似検索（image_embeddings / image_fingerprints）CRUD
/// Phase 6d: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceImageVectors
    extends DatabaseServiceUsageSessions {
  // ==========================================================================
  // 視覚類似検索（image_embeddings）CRUD — Phase 5
  // ==========================================================================

  /// 視覚エンベディングを保存（UPSERT）。embedding は Float32List の BLOB。
  Future<int> saveImageEmbedding({
    required int illustId,
    required Uint8List embedding,
    required int dim,
  }) async {
    final db = await database;
    return await db.insert('image_embeddings', {
      'illust_id': illustId,
      'embedding': embedding,
      'dim': dim,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全視覚エンベディングを取得（類似検索のスキャン用）。
  Future<List<Map<String, dynamic>>> getAllImageEmbeddings() async {
    final db = await database;
    return await db.query('image_embeddings');
  }

  /// 指定イラストの視覚エンベディングを削除（画像削除時の整合性維持）。
  Future<int> deleteImageEmbedding(int illustId) async {
    final db = await database;
    return await db.delete(
      'image_embeddings',
      where: 'illust_id = ?',
      whereArgs: [illustId],
    );
  }

  // ==========================================================================
  // 画像指紋（image_fingerprints）CRUD — Phase 6
  // ==========================================================================

  /// 画像指紋を保存（UPSERT）。
  Future<int> saveImageFingerprint({
    required int illustId,
    required String sha256,
    required int dhash,
  }) async {
    final db = await database;
    return await db.insert('image_fingerprints', {
      'illust_id': illustId,
      'sha256': sha256,
      'dhash': dhash,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全画像指紋を取得（重複検出のスキャン用）。
  Future<List<Map<String, dynamic>>> getAllImageFingerprints() async {
    final db = await database;
    return await db.query('image_fingerprints');
  }

  /// 指定イラストの指紋を削除（画像削除時の整合性維持）。
  Future<int> deleteImageFingerprint(int illustId) async {
    final db = await database;
    return await db.delete(
      'image_fingerprints',
      where: 'illust_id = ?',
      whereArgs: [illustId],
    );
  }
}
