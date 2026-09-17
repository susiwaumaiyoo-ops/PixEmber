part of 'database_service.dart';

/// 履歴（history）・ダウンロード済みイラスト（downloaded_illust）ドメイン。
/// Phase 4a: DatabaseService から移動（本体は 1 文字も変更せずそのまま）。
abstract class DatabaseServiceHistory extends DatabaseServiceNovelMeta {
  // ==========================================
  // HISTORY (履歴) - 便利メソッド
  // ==========================================

  Future<List<Map<String, dynamic>>> getHistoryList() async {
    final db = await database;
    return await db.query('history', orderBy: 'created_at DESC');
  }

  /// 閲覧履歴を追加/更新
  Future<int> insertOrUpdateHistory({
    required int workId,
    required String title,
    required String authorName,
    required String previewUrl,
    required String type,
    String? url,
    String? metadata,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return await db.insert('history', {
      'work_id': workId,
      'title': title,
      'author_name': authorName,
      'url': url,
      'metadata': metadata,
      'type': type,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 旧履歴レコードの欠損メタデータ（サムネイル・作者名）を非破壊で補完する。
  /// 既存行は削除せず、指定された列のみ更新する。
  Future<int> updateHistoryMeta({
    required int workId,
    String? title,
    String? authorName,
    String? url,
  }) async {
    final db = await database;
    final values = <String, dynamic>{};
    if (title != null && title.isNotEmpty) values['title'] = title;
    if (authorName != null && authorName.isNotEmpty) {
      values['author_name'] = authorName;
    }
    if (url != null && url.isNotEmpty) values['url'] = url;
    if (values.isEmpty) return 0;
    return await db.update(
      'history',
      values,
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }

  /// ダウンロード済みイラストを登録
  Future<int> insertDownloadedIllust({
    required int workId,
    required String title,
    required String authorName,
    required String type,
    String? localPath,
    String? thumbnailPath,
  }) async {
    final db = await database;
    return await db.insert('downloaded_illust', {
      'illust_id': workId,
      'local_path': localPath ?? '',
      'thumbnail_path': thumbnailPath,
      'download_date': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// ダウンロード済みイラスト一覧を取得
  /// Phase 4c: lib/services/database_novel.dart から移植
  /// （DB 取得方法を DatabaseService().database → database getter へ変更したのみ）。
  Future<List<Map<String, dynamic>>> getDownloadedIllustsList() async {
    final db = await database;
    return await db.query('downloaded_illust', orderBy: 'download_date DESC');
  }

  /// ダウンロード済みイラストを削除
  /// Phase 4c: lib/services/database_novel.dart から移植
  /// （DB 取得方法を DatabaseService().database → database getter へ変更したのみ）。
  Future<int> deleteDownloadedIllust(int workId) async {
    final db = await database;
    return await db.delete(
      'downloaded_illust',
      where: 'illust_id = ?',
      whereArgs: [workId],
    );
  }
}
