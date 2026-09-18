part of 'database_service.dart';

/// 検索履歴（search_history）CRUD
/// Phase 5e: DatabaseService から分離（ロジック変更なし）。
/// ※ lib/services/database_search.dart（AI 検索・embedding 系）とは別物。
abstract class DatabaseServiceSearchHistory extends DatabaseServiceSubscriptions {
  // ==========================================================================
  // 検索履歴（search_history）CRUD
  // ==========================================================================

  /// 検索実行時にキーワードを保存・更新する。
  /// 既存キーワードなら last_searched_at を更新し use_count を +1、
  /// 新規なら insert（use_count=1）。[keyword] が空なら何もしない。
  Future<void> addSearchHistory(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final existing = await db.query(
      'search_history',
      columns: ['id', 'use_count'],
      where: 'keyword = ?',
      whereArgs: [k],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final prevCount = (existing.first['use_count'] as int?) ?? 0;
      await db.update(
        'search_history',
        {'last_searched_at': now, 'use_count': prevCount + 1},
        where: 'keyword = ?',
        whereArgs: [k],
      );
    } else {
      await db.insert('search_history', {
        'keyword': k,
        'last_searched_at': now,
        'use_count': 1,
      });
    }
  }

  /// 検索候補（部分一致）を取得する。
  /// [query] が空なら全件（[orderBy]=use_count なら使用回数順、
  /// それ以外は最新日時順）を返す。
  Future<List<Map<String, dynamic>>> searchSearchHistory({
    String query = '',
    String orderBy = 'recent',
  }) async {
    final db = await database;
    final where = query.trim().isEmpty ? null : 'keyword LIKE ?';
    final whereArgs = query.trim().isEmpty ? null : ['%${query.trim()}%'];
    final order = orderBy == 'use_count'
        ? 'use_count DESC, last_searched_at DESC'
        : 'last_searched_at IS NULL, last_searched_at DESC';
    return await db.query(
      'search_history',
      where: where,
      whereArgs: whereArgs,
      orderBy: order,
      limit: 30,
    );
  }

  /// 検索履歴を個別削除する。
  Future<int> deleteSearchHistory(String keyword) async {
    final db = await database;
    return await db.delete(
      'search_history',
      where: 'keyword = ?',
      whereArgs: [keyword],
    );
  }

  /// 検索履歴を全件削除する。
  Future<int> clearSearchHistory() async {
    final db = await database;
    return await db.delete('search_history');
  }
}
