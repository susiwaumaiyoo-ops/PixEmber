import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'database_service.dart';

/// コサイン類似度で類似小説を検索
///
/// 注意: 以前は compute() で Isolate 実行を試みていましたが、
/// Database オブジェクトは Isolate 越境できないため、メインスレッドで実行します。
/// パフォーマンスが問題になる場合は、embedding だけを別 Isolate に渡す設計に変更してください。
Future<List<Map<String, dynamic>>> searchNovelsByEmbedding({
  required Database db,
  required Float32List userEmbedding,
  int limit = 20,
  double minSimilarity = 0.5,
}) async {
  final userNorm = _vectorNorm(userEmbedding);
  if (userNorm == 0) return [];

  // 全ベクトルを取得
  final rows = await db.query(
    'novel_embeddings',
    columns: ['work_id', 'embedding'],
  );

  // 類似度計算
  final similarities = <_SimilarityEntry>[];
  for (final row in rows) {
    final workId = row['work_id'] as int?;
    final embRaw = row['embedding'];
    if (workId == null || embRaw == null) continue;

    try {
      final decoded = jsonDecode(embRaw as String) as List<dynamic>;
      final embedding = Float32List.fromList(
        decoded.map((e) => (e as num).toDouble()).toList(),
      );
      final sim = _cosineSimilarity(userEmbedding, embedding, userNorm);
      if (sim >= minSimilarity) {
        similarities.add(_SimilarityEntry(workId, sim));
      }
    } catch (e) {
      debugPrint('embedding decode error for workId=$workId: $e');
    }
  }

  // 類似度降順ソート
  similarities.sort((a, b) => b.similarity.compareTo(a.similarity));

  // 上位 limit 件の小説情報を取得
  final topEntries = similarities.take(limit).toList();
  final results = <Map<String, dynamic>>[];

  for (final entry in topEntries) {
    final novelResult = await db.query(
      'novels',
      where: 'id = ?',
      whereArgs: [entry.workId],
    );
    if (novelResult.isNotEmpty) {
      results.add({...novelResult.first, 'similarity': entry.similarity});
    }
  }

  return results;
}

/// ベクトルのノルム（長さ）を計算
double _vectorNorm(Float32List vec) {
  double sum = 0;
  for (final v in vec) {
    sum += v * v;
  }
  return sqrt(sum);
}

/// コサイン類似度を計算（事前計算済みの aNorm を使用して高速化）
double _cosineSimilarity(Float32List a, Float32List b, double aNorm) {
  if (a.length != b.length || aNorm == 0) return 0.0;
  double dot = 0;
  double bSquareSum = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    bSquareSum += b[i] * b[i];
  }
  final bNorm = sqrt(bSquareSum);
  if (bNorm == 0) return 0.0;
  return dot / (aNorm * bNorm);
}

/// 全データを JSON からインポート（マージロジック付き）
Future<Map<String, int>> importAllData(Map<String, dynamic> jsonData) async {
  final db = await DatabaseService().database;
  final summary = <String, int>{};

  Future<int> importTable(String tableName, String idKey) async {
    if (jsonData[tableName] == null) return 0;
    final items = jsonData[tableName] as List<dynamic>;
    int count = 0;
    for (final itemJson in items) {
      final item = itemJson as Map<String, dynamic>;
      final id = item[idKey];
      try {
        await db.insert(
          tableName,
          item,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        count++;
      } catch (e) {
        debugPrint('Import error for $tableName $id: $e');
      }
    }
    return count;
  }

  summary['novels'] = await importTable('novels', 'id');
  summary['novel_text'] = await importTable('novel_text', 'work_id');
  summary['novel_embeddings'] = await importTable(
    'novel_embeddings',
    'work_id',
  );

  return summary;
}

/// 全データを JSON にエクスポート
Future<Map<String, dynamic>> exportAllData() async {
  final db = await DatabaseService().database;
  return {
    'novels': await db.query('novels'),
    'novel_text': await db.query('novel_text'),
    'novel_embeddings': await db.query('novel_embeddings'),
    'history': await db.query('history'),
    'downloaded_illust': await db.query('downloaded_illust'),
    'mutes': await db.query('mutes'),
    'folders': await db.query('folders'),
    'folder_items': await db.query('folder_items'),
    'exported_at': DateTime.now().toIso8601String(),
  };
}

/// 類似度エントリのデータクラス
class _SimilarityEntry {
  final int workId;
  final double similarity;
  _SimilarityEntry(this.workId, this.similarity);
}
