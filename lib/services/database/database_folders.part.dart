part of 'database_service.dart';

/// ユーザーコレクション: お気に入りフォルダ（folders / folder_items）CRUD
/// Phase 5c: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceFolders extends DatabaseServiceMutes {

  // ==========================================
  // FOLDERS (お気に入りフォルダ) CRUD
  // ==========================================

  Future<int> createFolder(String name) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return await db.insert('folders', {'name': name, 'created_at': now});
  }

  Future<List<Map<String, dynamic>>> getFoldersList() async {
    final db = await database;
    return await db.query('folders', orderBy: 'created_at DESC');
  }

  Future<int> deleteFolder(int id) async {
    final db = await database;
    await db.delete('folder_items', where: 'folder_id = ?', whereArgs: [id]);
    return await db.delete('folders', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> renameFolder(int id, String newName) async {
    final db = await database;
    return await db.update(
      'folders',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ==========================================
  // FOLDER ITEMS (お気に入りアイテム) CRUD
  // ==========================================

  Future<int> addFolderItem({
    required int folderId,
    required int workId,
    required String title,
    required String authorName,
    required String previewUrl,
    required String type,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return await db.insert('folder_items', {
      'folder_id': folderId,
      'work_id': workId,
      'title': title,
      'author_name': authorName,
      'preview_url': previewUrl,
      'type': type,
      'added_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getFolderItems({
    required int folderId,
    String? type,
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await database;
    if (type != null) {
      return await db.query(
        'folder_items',
        where: 'folder_id = ? AND type = ?',
        whereArgs: [folderId, type],
        orderBy: 'added_at DESC',
        limit: limit,
        offset: offset,
      );
    } else {
      return await db.query(
        'folder_items',
        where: 'folder_id = ?',
        whereArgs: [folderId],
        orderBy: 'added_at DESC',
        limit: limit,
        offset: offset,
      );
    }
  }

  Future<int> removeFolderItem({
    required int folderId,
    required int workId,
    required String type,
  }) async {
    final db = await database;
    return await db.delete(
      'folder_items',
      where: 'folder_id = ? AND work_id = ? AND type = ?',
      whereArgs: [folderId, workId, type],
    );
  }

  Future<bool> isWorkInFolder(int workId, String type) async {
    final db = await database;
    final result = await db.query(
      'folder_items',
      where: 'work_id = ? AND type = ?',
      whereArgs: [workId, type],
      limit: 1,
    );
    return result.isNotEmpty;
  }
}
