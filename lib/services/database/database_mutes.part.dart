part of 'database_service.dart';

/// ユーザーコレクション: ミュート設定（mutes）CRUD
/// Phase 5b: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceMutes extends DatabaseServiceReadLater {
  // ==========================================
  // MUTES (ミュート設定) CRUD
  // ==========================================

  Future<List<Map<String, dynamic>>> getMutesList() async {
    final db = await database;
    return await db.query('mutes', orderBy: 'id ASC');
  }

  Future<int> addMute({
    required String muteType,
    required String value,
    String? label,
  }) async {
    final db = await database;
    return await db.insert('mutes', {
      'mute_type': muteType,
      'value': value,
      'label': label,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// ミュート設定を追加/更新（HomeSyncHandler などから呼ばれる）
  Future<int> insertOrUpdateMute({
    required String muteType,
    required String value,
    String? label,
  }) async {
    return addMute(muteType: muteType, value: value, label: label);
  }

  Future<int> deleteMute(int muteId) async {
    final db = await database;
    return await db.delete('mutes', where: 'id = ?', whereArgs: [muteId]);
  }

  Future<int> clearMutes() async {
    final db = await database;
    return await db.delete('mutes');
  }
}
