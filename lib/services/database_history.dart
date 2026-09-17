import 'package:sqflite/sqflite.dart';

/// AIレコメンド用: work_id 単位で重複排除し、最新の履歴行のみを取得する。
///
/// 同一作品を複数回閲覧した場合でも1件にまとめ、最新の created_at 順で返す。
/// [type] で 'novel' / 'illust' を絞り込み可能。
/// AIレコメンドフィードの嗜好ベクトル構築に使用する。
///
/// Phase 4d: 呼び出し元が本関数のみ残ったため、他の履歴ヘルパー
/// （searchHistory / searchHistoryAll / insertHistory / insertOrUpdateHistory /
/// deleteHistory / deleteHistoryByWorkId / clearHistory）はデッドコード削除済み。
/// 履歴の CRUD は DatabaseService（database_history.part.dart）を参照のこと。
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
