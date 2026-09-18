part of 'database_service.dart';

/// ユーザーコレクション: 購読（subscribed_tags / subscription_new_items）
/// Phase 5d: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceSubscriptions extends DatabaseServiceFolders {
// ---- subscribed_tags (lines 628-717) ----
  /// 購読タグを追加（重複登録を防止）
  ///
  /// 同じ (tag, type) の組み合わせが既に存在する場合は登録せず、
  /// 既存レコードの id を返す。存在しない場合は新規 insert する。
  /// created_at は登録時刻（UTC ISO8601）で自動付与する。
  Future<int> addSubscribedTag(String tag, String type) async {
    final db = await database;

    final existing = await db.query(
      'subscribed_tags',
      columns: ['id'],
      where: 'tag = ? AND type = ?',
      whereArgs: [tag, type],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      // 重複: 既存レコードの id を返す（登録済み）
      return existing.first['id'] as int;
    }

    return await db.insert('subscribed_tags', {
      'tag': tag,
      'type': type,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// 登録済み購読タグを全件取得（created_at 昇順）
  Future<List<Map<String, dynamic>>> getSubscribedTags() async {
    final db = await database;
    // read-only リストを可変コピーにして返す（呼び出し側で _tags[idx]=... 等の
    // 要素代入が行われるため必須）。
    final rows = await db.query(
      'subscribed_tags',
      orderBy: 'created_at ASC, id ASC',
    );
    return List<Map<String, dynamic>>.from(rows);
  }

  /// 指定した購読タグが存在するか（重複チェック用）
  Future<bool> isSubscribedTag(String tag, String type) async {
    final db = await database;
    final rows = await db.query(
      'subscribed_tags',
      columns: ['id'],
      where: 'tag = ? AND type = ?',
      whereArgs: [tag, type],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// id 指定で購読タグを削除
  Future<int> removeSubscribedTag(int id) async {
    final db = await database;
    return await db.delete('subscribed_tags', where: 'id = ?', whereArgs: [id]);
  }

  /// 購読タグの新着チェック結果を保存する。
  ///
  /// [lastNewestDate] は前回チェック時の最新作品 create_date（UTC ISO8601）、
  /// [lastNewCount] は新着件数（初回は 0）。[lastCheckedAt] はチェック実行時刻。
  Future<int> updateSubscribedTagCheck(
    int id, {
    required String lastCheckedAt,
    String? lastNewestDate,
    int lastNewCount = 0,
  }) async {
    final db = await database;
    return await db.update(
      'subscribed_tags',
      {
        'last_checked_at': lastCheckedAt,
        'last_newest_date': lastNewestDate,
        'last_new_count': lastNewCount,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// (tag, type) 指定で購読タグを削除
  Future<int> removeSubscribedTagByValue(String tag, String type) async {
    final db = await database;
    return await db.delete(
      'subscribed_tags',
      where: 'tag = ? AND type = ?',
      whereArgs: [tag, type],
    );
  }

// ---- subscription_new_items (lines 97-212) ----
  // ==========================================================================
  // 購読タグの新着作品キャッシュ（subscription_new_items）
  // ==========================================================================

  /// タグごとの保存上限件数。超えた分は古い順に削除する。
  static const int subscriptionNewItemsLimitPerTag = 100;

  /// 新着作品を保存する（UNIQUE(subscribed_tag_id, work_id) で重複無視）。
  /// 戻り値は実際に新規挿入された件数。
  Future<int> insertSubscriptionNewItems(
    int subscribedTagId,
    List<Map<String, dynamic>> items,
  ) async {
    if (items.isEmpty) return 0;
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    var inserted = 0;
    for (final item in items) {
      final id = await db.insert('subscription_new_items', {
        'subscribed_tag_id': subscribedTagId,
        'work_id': item['work_id'],
        'type': item['type'],
        'title': item['title'],
        'author_name': item['author_name'],
        'preview_url': item['preview_url'],
        'create_date': item['create_date'],
        'x_restrict': item['x_restrict'] ?? 0,
        'found_at': now,
        'is_read': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (id != 0) inserted++;
    }
    await cleanupSubscriptionNewItems(subscribedTagId);
    return inserted;
  }

  /// タグの新着作品を新しい順に取得する。
  Future<List<Map<String, dynamic>>> getSubscriptionNewItems(
    int subscribedTagId,
  ) async {
    final db = await database;
    // read-only リストを可変コピーにして返す（呼び出し側の安全のため）。
    final rows = await db.query(
      'subscription_new_items',
      where: 'subscribed_tag_id = ?',
      whereArgs: [subscribedTagId],
      orderBy: 'create_date DESC, id DESC',
    );
    return List<Map<String, dynamic>>.from(rows);
  }

  /// 全タグの未読件数。Drawer バッジ用。
  Future<int> getSubscriptionUnreadCount() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM subscription_new_items WHERE is_read = 0',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// タグ単位の未読件数をまとめて取得する（tag_id -> count）。
  Future<Map<int, int>> getSubscriptionUnreadCountByTag() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT subscribed_tag_id AS tid, COUNT(*) AS c '
      'FROM subscription_new_items WHERE is_read = 0 '
      'GROUP BY subscribed_tag_id',
    );
    final result = <int, int>{};
    for (final r in rows) {
      final tid = r['tid'] as int?;
      if (tid != null) result[tid] = (r['c'] as int?) ?? 0;
    }
    return result;
  }

  /// 1 件を既読にする。
  Future<int> markSubscriptionNewItemRead(int id) async {
    final db = await database;
    return await db.update(
      'subscription_new_items',
      {'is_read': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// タグ内のすべてを既読にする。
  Future<int> markAllSubscriptionNewItemsRead(int subscribedTagId) async {
    final db = await database;
    return await db.update(
      'subscription_new_items',
      {'is_read': 1},
      where: 'subscribed_tag_id = ?',
      whereArgs: [subscribedTagId],
    );
  }

  /// 肥大化防止: タグごとに上限件数を超えた古いレコードを削除する。
  Future<int> cleanupSubscriptionNewItems(int subscribedTagId) async {
    final db = await database;
    return await db.rawDelete(
      'DELETE FROM subscription_new_items WHERE subscribed_tag_id = ? '
      'AND id NOT IN ('
      '  SELECT id FROM subscription_new_items WHERE subscribed_tag_id = ? '
      '  ORDER BY create_date DESC, id DESC LIMIT ?'
      ')',
      [subscribedTagId, subscribedTagId, subscriptionNewItemsLimitPerTag],
    );
  }

  /// 新着キャッシュを全削除する（バックアップ復元時の参照切れ防止）。
  Future<int> clearSubscriptionNewItems() async {
    final db = await database;
    return await db.delete('subscription_new_items');
  }

}
