import 'dart:convert';
import 'package:sqflite/sqflite.dart';

/// 履歴をキーワード検索・タイプ絞り込みで取得
Future<List<Map<String, dynamic>>> searchHistory({
  required Database db,
  String? keyword,
  String? type,
  int limit = 100,
  int offset = 0,
}) async {
  final queryBuilder = StringBuffer('SELECT * FROM history WHERE 1=1');
  final params = <dynamic>[];

  if (keyword != null && keyword.isNotEmpty) {
    queryBuilder.write(' AND title LIKE ?');
    params.add('%$keyword%');
  }
  if (type != null && type.isNotEmpty) {
    queryBuilder.write(' AND type = ?');
    params.add(type);
  }
  queryBuilder.write(' ORDER BY created_at DESC LIMIT ? OFFSET ?');
  params.add(limit);
  params.add(offset);

  return await db.rawQuery(queryBuilder.toString(), params);
}

/// 履歴をキーワード検索・タイプ絞り込みで取得（全件相当）
Future<List<Map<String, dynamic>>> searchHistoryAll({
  required Database db,
  String? keyword,
  String? type,
}) async {
  return await searchHistory(
    db: db,
    keyword: keyword,
    type: type,
    limit: 1000,
    offset: 0,
  );
}

/// AIレコメンド用: work_id 単位で重複排除し、最新の履歴行のみを取得する。
///
/// 同一作品を複数回閲覧した場合でも1件にまとめ、最新の created_at 順で返す。
/// [type] で 'novel' / 'illust' を絞り込み可能。
/// AIレコメンドフィードの嗜好ベクトル構築に使用する。
Future<List<Map<String, dynamic>>> searchDistinctHistoryByWork({
  required Database db,
  String? type,
  int limit = 30,
}) async {
  final params = <dynamic>[];
  final typeCondition = (type != null && type.isNotEmpty)
      ? 'WHERE type = ?'
      : '';
  if (type != null && type.isNotEmpty) {
    params.add(type);
  }
  // SQLite は GROUP BY + MAX(created_at) で最新行を集約できる。
  // rowid が大きいほど新しいので MAX(id) で代表1行を特定し、再度結合して完全行を取得。
  final sql =
      '''
    SELECT h.* FROM history h
    INNER JOIN (
      SELECT work_id, MAX(id) AS max_id
      FROM history
      $typeCondition
      GROUP BY work_id
    ) latest ON h.id = latest.max_id
    ORDER BY h.created_at DESC
    LIMIT ?
  ''';
  params.add(limit);
  return await db.rawQuery(sql, params);
}

/// 履歴を追加
Future<int> insertHistory({
  required Database db,
  required String title,
  required String type,
  required int workId,
  String? url,
  Map<String, dynamic>? metadata,
}) async {
  return await db.insert('history', {
    'title': title,
    'type': type,
    'work_id': workId,
    'url': url ?? '',
    'metadata': metadata != null ? jsonEncode(metadata) : null,
    'created_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// 履歴を追加/更新（HomeSyncHandler などから呼ばれる）
Future<int> insertOrUpdateHistory({
  required Database db,
  required String title,
  required String type,
  required int workId,
  String? url,
  Map<String, dynamic>? metadata,
}) async {
  return insertHistory(
    db: db,
    title: title,
    type: type,
    workId: workId,
    url: url,
    metadata: metadata,
  );
}

/// 履歴を削除（ID指定）
Future<int> deleteHistory({
  required Database db,
  required int historyId,
}) async {
  return await db.delete('history', where: 'id = ?', whereArgs: [historyId]);
}

/// 履歴を削除（workId指定）
Future<int> deleteHistoryByWorkId({
  required Database db,
  required int workId,
}) async {
  return await db.delete('history', where: 'work_id = ?', whereArgs: [workId]);
}

/// 履歴をクリア
Future<int> clearHistory({required Database db}) async {
  return await db.delete('history');
}
