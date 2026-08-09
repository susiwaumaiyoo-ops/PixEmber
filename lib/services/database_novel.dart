import 'dart:convert';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'database_service.dart';

/// 小説本文をキャッシュ（UPSERT）
Future<int> saveNovelText({
  required Database db,
  required int workId,
  required String pagesJson,
  required String text,
}) async {
  return await db.insert('novel_text', {
    'work_id': workId,
    'pages_json': pagesJson,
    'text': text,
    'updated_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// キャッシュされた小説本文を取得
Future<Map<String, dynamic>?> getNovelText(int workId) async {
  final db = await DatabaseService().database;
  final result = await db.query(
    'novel_text',
    where: 'work_id = ?',
    whereArgs: [workId],
  );
  if (result.isEmpty) return null;
  return result.first;
}

/// 小説のベクトルを保存（UPSERT）
/// SQLite の TEXT カラムに JSON 文字列として保存する
Future<int> saveNovelEmbedding({
  required Database db,
  required int workId,
  required Float32List embedding,
}) async {
  return await db.insert('novel_embeddings', {
    'work_id': workId,
    'embedding': jsonEncode(embedding.toList()),
    'updated_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// 保存された小説ベクトルを取得
Future<Float32List?> getNovelEmbedding(int workId) async {
  final db = await DatabaseService().database;
  final result = await db.query(
    'novel_embeddings',
    where: 'work_id = ?',
    whereArgs: [workId],
  );
  if (result.isEmpty) return null;

  final raw = result.first['embedding'];
  if (raw == null) return null;

  final decoded = jsonDecode(raw as String) as List<dynamic>;
  return Float32List.fromList(
    decoded.map((e) => (e as num).toDouble()).toList(),
  );
}

/// ダウンロード済みイラストを保存（UPSERT）
Future<int> insertDownloadedIllust({
  required Database db,
  required int illustId,
  required String localPath,
  String? thumbnailPath,
  DateTime? downloadDate,
}) async {
  return await db.insert('downloaded_illust', {
    'illust_id': illustId,
    'local_path': localPath,
    'thumbnail_path': thumbnailPath ?? '',
    'download_date':
        downloadDate?.toIso8601String() ?? DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// ダウンロード済みイラスト一覧を取得
Future<List<Map<String, dynamic>>> getDownloadedIllustsList() async {
  final db = await DatabaseService().database;
  return await db.query('downloaded_illust', orderBy: 'download_date DESC');
}

/// ダウンロード済みイラストを削除
Future<int> deleteDownloadedIllust(int workId) async {
  final db = await DatabaseService().database;
  return await db.delete(
    'downloaded_illust',
    where: 'illust_id = ?',
    whereArgs: [workId],
  );
}
