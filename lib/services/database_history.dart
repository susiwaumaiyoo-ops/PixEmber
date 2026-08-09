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
