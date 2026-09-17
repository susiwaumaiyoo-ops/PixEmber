part of 'database_service.dart';

/// ダウンロードキュー（download_queue_groups / download_queues）ドメイン。
/// Phase 4b: DatabaseService から移動（本体は 1 文字も変更せずそのまま）。
abstract class DatabaseServiceDownloadQueue extends DatabaseServiceHistory {
  // ==========================================================================
  // ダウンロードキュー（download_queue_groups / download_queues）CRUD
  // ==========================================================================

  /// ダウンロードキューグループ（親ジョブ）を登録する（UPSERT）。
  /// work_id + work_type の組み合わせで UNIQUE 制約により重複を弾く。
  /// 既存の場合は conflictAlgorithm.ignore で既存レコードを維持する。
  Future<int> insertDownloadQueueGroup({
    required int workId,
    required String workType,
    required String title,
    required String authorName,
    required int pageTotal,
    int priority = 5,
    int maxRetry = 3,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    return await db.insert('download_queue_groups', {
      'work_id': workId,
      'work_type': workType,
      'title': title,
      'author_name': authorName,
      'page_total': pageTotal,
      'page_completed': 0,
      'status': 'pending',
      'priority': priority,
      'retry_count': 0,
      'max_retry': maxRetry,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// ダウンロードキューアイテム（子ジョブ）を一括登録する。
  /// 同一グループ内の page_index は UNIQUE でなければならない。
  Future<void> insertDownloadQueueItems(
    int groupId,
    List<Map<String, dynamic>> items,
  ) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().toUtc().toIso8601String();
    for (final item in items) {
      batch.insert('download_queues', {
        'group_id': groupId,
        'work_id': item['work_id'] as int,
        'work_type': item['work_type'] as String,
        'page_index': item['page_index'] as int,
        'url': item['url'] as String? ?? '',
        'local_path': '',
        'file_size': item['file_size'] as int? ?? 0,
        'downloaded_bytes': 0,
        'status': 'pending',
        'retry_count': 0,
        'max_retry': item['max_retry'] as int? ?? 3,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// 全ダウンロードキューグループを取得する（status で絞り込み可能）。
  /// priority 降順、created_at 昇順でソートする。
  Future<List<Map<String, dynamic>>> getDownloadQueueGroups({
    String? status,
  }) async {
    final db = await database;
    if (status != null) {
      return await db.query(
        'download_queue_groups',
        where: 'status = ?',
        whereArgs: [status],
        orderBy: 'priority DESC, created_at ASC',
      );
    }
    return await db.query(
      'download_queue_groups',
      orderBy: 'priority DESC, created_at ASC',
    );
  }

  /// 指定グループのダウンロードキューアイテムを全件取得する。
  Future<List<Map<String, dynamic>>> getDownloadQueueItems(int groupId) async {
    final db = await database;
    return await db.query(
      'download_queues',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'page_index ASC',
    );
  }

  /// ダウンロードキューアイテムのステータス・進捗を更新する。
  Future<int> updateDownloadQueueItem({
    required int itemId,
    String? status,
    int? downloadedBytes,
    String? localPath,
    int? fileSize,
    String? errorCode,
    String? errorMessage,
    int? retryCount,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final values = <String, dynamic>{'updated_at': now};
    if (status != null) {
      values['status'] = status;
      if (status == 'completed' || status == 'failed') {
        values['completed_at'] = now;
      }
    }
    if (downloadedBytes != null) values['downloaded_bytes'] = downloadedBytes;
    if (localPath != null) values['local_path'] = localPath;
    if (fileSize != null) values['file_size'] = fileSize;
    if (errorCode != null) values['error_code'] = errorCode;
    if (errorMessage != null) values['error_message'] = errorMessage;
    if (retryCount != null) values['retry_count'] = retryCount;
    return await db.update(
      'download_queues',
      values,
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

  /// ダウンロードキューグループのステータス・進捗を更新する。
  /// page_completed は子アイテム完了時に外部からカウントして渡す。
  Future<int> updateDownloadQueueGroup({
    required int groupId,
    String? status,
    int? pageCompleted,
    String? errorCode,
    String? errorMessage,
    int? retryCount,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final values = <String, dynamic>{'updated_at': now};
    if (status != null) {
      values['status'] = status;
      if (status == 'completed' || status == 'failed') {
        values['completed_at'] = now;
      }
      // 再開(pending)に戻す際はエラー情報をクリアする
      if (status == 'pending') {
        values['error_code'] = null;
        values['error_message'] = null;
      }
    }
    if (pageCompleted != null) values['page_completed'] = pageCompleted;
    if (errorCode != null) values['error_code'] = errorCode;
    if (errorMessage != null) values['error_message'] = errorMessage;
    if (retryCount != null) values['retry_count'] = retryCount;
    return await db.update(
      'download_queue_groups',
      values,
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  /// 起動時復旧: status='running' のグループ・アイテムを全て 'pending' に戻す。
  /// 前回アプリ異常終了時に実行中だったジョブを再開可能にする。
  Future<int> recoverInterruptedDownloads() async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final count = await db.update(
      'download_queue_groups',
      {'status': 'pending', 'updated_at': now},
      where: 'status = ?',
      whereArgs: ['running'],
    );
    if (count > 0) {
      await db.update(
        'download_queues',
        {'status': 'pending', 'updated_at': now},
        where: 'status = ?',
        whereArgs: ['running'],
      );
      debugPrint('[DownloadQueue] 復旧: running→pending ($count 件)');
    }
    return count;
  }

  /// 指定グループを削除する（FK CASCADE で子アイテムも自動削除）。
  /// ファイル実体の削除は DownloadService 側で行ってから呼ぶこと。
  Future<int> deleteDownloadQueueGroup(int groupId) async {
    final db = await database;
    return await db.delete(
      'download_queue_groups',
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  /// 指定ステータスのグループを一括削除する（完了/失敗済みのクリア用）。
  Future<int> deleteDownloadQueueGroupsByStatus(String status) async {
    final db = await database;
    return await db.delete(
      'download_queue_groups',
      where: 'status = ?',
      whereArgs: [status],
    );
  }

  /// work_id + work_type でグループを検索する（重複登録チェック用）。
  Future<Map<String, dynamic>?> findDownloadQueueGroup(
    int workId,
    String workType,
  ) async {
    final db = await database;
    final rows = await db.query(
      'download_queue_groups',
      where: 'work_id = ? AND work_type = ?',
      whereArgs: [workId, workType],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }
}
