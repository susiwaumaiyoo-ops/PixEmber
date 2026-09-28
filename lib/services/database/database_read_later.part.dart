part of 'database_service.dart';

/// ユーザーコレクション: あとで読む（read_later）CRUD
/// Phase 5a: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceReadLater extends DatabaseServiceDownloadQueue {
  // ==========================================================================
  // あとで読む（小説）（read_later）CRUD
  // ==========================================================================

  /// あとで読むに登録する（重複登録は無視）。
  /// [novel] から必要なメタデータをスナップショット保存する。
  /// 既に登録済みの場合は何もせず既存レコードを維持する。
  Future<void> addReadLater(Novel novel) async {
    final db = await database;
    await db.insert('read_later', {
      'work_id': novel.id,
      'title': novel.title,
      'author_name': novel.author.name,
      'author_id': novel.author.id,
      'cover_url': novel.coverUrl,
      'text_length': novel.textLength,
      'tags_json': jsonEncode(novel.tags),
      'x_restrict': novel.xRestrict,
      'status': 0,
      'added_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// あとで読むから削除する。
  Future<int> removeReadLater(int workId) async {
    final db = await database;
    return await db.delete(
      'read_later',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }

  /// 登録済みか判定する。
  Future<bool> isReadLater(int workId) async {
    final db = await database;
    final rows = await db.query(
      'read_later',
      columns: ['work_id'],
      where: 'work_id = ?',
      whereArgs: [workId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 一覧を取得する。[status] が null なら全件、指定ならフィルタ。
  /// [query] が非空（trim 後）なら、title / author_name / tags_json の
  /// いずれかに部分一致（LIKE %query%）する行のみを返す。
  /// [query] が null・空・空白のみなら従来（フィルタなし）と完全に同一の SQL。
  /// 追加日時の新しい順でソート。
  Future<List<Map<String, dynamic>>> getReadLaterList({
    int? status,
    String? query,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (status != null) {
      where.add('status = ?');
      args.add(status);
    }
    // LIKE は searchNovelsLexical（database_search.dart）と同一のパターン。
    // ワイルドカード（% / _）のエスケープは行わない（検索 UI では稀であり、
    // 過剰実装を避ける）。既定の LIKE 挙動（ASCII は大文字小文字無視）を
    // test/read_later_search_test.dart で固定する。
    final trimmedQuery = query?.trim() ?? '';
    if (trimmedQuery.isNotEmpty) {
      final like = '%$trimmedQuery%';
      where.add('(title LIKE ? OR author_name LIKE ? OR tags_json LIKE ?)');
      args.addAll([like, like, like]);
    }
    // sqflite の db.query() は read-only（Unmodifiable）リストを返すため、
    // 呼び出し側で書き換え・破壊的操作される前提で可変コピーを返す。
    final rows = await db.query(
      'read_later',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: where.isEmpty ? null : args,
      orderBy: 'added_at DESC, id DESC',
    );
    return List<Map<String, dynamic>>.from(rows);
  }

  /// ステータスを更新する。
  /// [status] が 1(読書中) なら last_opened_at を更新。
  /// [status] が 2(読了) なら finished_at を更新。
  Future<int> updateReadLaterStatus(int workId, int status) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final values = <String, dynamic>{'status': status};
    if (status == 1) values['last_opened_at'] = now;
    if (status == 2) values['finished_at'] = now;
    return await db.update(
      'read_later',
      values,
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }

  /// ステータス別件数を取得する（タブバッジ用）。
  /// key: 0=未読 / 1=読書中 / 2=読了。
  Future<Map<int, int>> getReadLaterCounts() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS c FROM read_later GROUP BY status',
    );
    final Map<int, int> result = {0: 0, 1: 0, 2: 0};
    for (final row in rows) {
      final s = (row['status'] as int?) ?? 0;
      final c = (row['c'] as int?) ?? 0;
      result[s] = c;
    }
    return result;
  }

  /// 読書進捗（0.0〜1.0）を保存する。頻繁な呼び出しを想定し、呼び出し側で
  /// 「1%以上変化したときのみ」等の頻度制御を行うこと。
  Future<int> updateReadLaterProgress(int workId, double progress) async {
    final db = await database;
    return await db.update(
      'read_later',
      {'progress': progress.clamp(0.0, 1.0)},
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }

  /// 最後に読んでいたページ・文字オフセットを保存する（再開用）。
  Future<int> updateReadLaterPosition(int workId, int page, int offset) async {
    final db = await database;
    return await db.update(
      'read_later',
      {'last_page': page, 'last_offset': offset},
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }

  /// 未読件数のみを取得する（Drawer バッジ用）。
  Future<int> getReadLaterUnreadCount() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM read_later WHERE status = 0',
    );
    if (rows.isEmpty) return 0;
    return (rows.first['c'] as int?) ?? 0;
  }
}
