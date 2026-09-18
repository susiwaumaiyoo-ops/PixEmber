import 'dart:convert';
import 'dart:math';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'feeling_search_query.dart';
import 'ruri_model_manager.dart';

/// コサイン類似度で類似小説を検索。
///
/// ※ バックアップ系（importAllData / exportAllData）は `DatabaseService`
/// （`database_backup.part.dart`）を参照のこと。
///
/// デバッグ(JIT)ビルドで数百〜数千件の embedding を処理しても ANR にならない
/// よう、以下の方針をとる。
///
/// 1. SQLite の全件 `List<Map<String, dynamic>>` を丸ごと [Isolate.run] に渡さ
///    ない。そのまま渡すと StandardMessageCodec による直列化が「呼び出し側の
///    メインスレッド」で発生し、巨大な embedding(JSON文字列) を含む全件を
///    コピーするコストが主因で UI スレッドが 5s 以上ブロックされる（デバッグ
///    ビルドで顕在化）。
/// 2. 代わりに `LIMIT`/`OFFSET` で少量ずつ (バッチ) DB から取得し、各バッチの
///    計算を [Isolate.run] に投げる。バッチ間には `Future.delayed(Duration.zero)`
///    でイベントループを空け UI を返す。
/// 3. 各バッチの計算結果は「上位 N 件の bounded heap」として保持し、最後に
///    全体ソートして top-K を返す。Isolate には Float32List 等の軽量データだけ
///    を渡す。
/// 4. sqflite の Database は Isolate 越境不可のため、SQLite アクセスはメイン
///    スレッドで行う（既存の filter*Isolated パターンを踏襲）。
Future<List<Map<String, dynamic>>> searchNovelsByEmbedding({
  required Database db,
  required Float32List userEmbedding,
  int limit = 20,
  double minSimilarity = 0.5,
}) async {
  final sw = Stopwatch()..start();
  if (kDebugMode) debugPrint('[AISearch][T+0ms] search_embedding_start');
  final userNorm = _vectorNorm(userEmbedding);
  if (userNorm == 0) return [];

  // 類似度降順の上位を保持する bounded heap（メモリと計算量を抑える）。
  final topHeap = _BoundedTopHeap(limit * 4);

  const batchSize = 100;
  int offset = 0;
  int totalRows = 0;
  int bytesApprox = 0;

  while (true) {
    if (kDebugMode) {
      debugPrint(
        '[AISearch][T+${sw.elapsedMilliseconds}ms] before_db_query_embeddings '
        'offset=$offset',
      );
    }
    final rows = await db.query(
      'novel_embeddings',
      columns: [
        'work_id',
        'embedding',
        'model_id',
        'model_version',
        'prefix_scheme_version',
      ],
      limit: batchSize,
      offset: offset,
    );
    if (kDebugMode) {
      debugPrint(
        '[AISearch][T+${sw.elapsedMilliseconds}ms] after_db_query_embeddings '
        'rows=${rows.length} bytesApprox=$bytesApprox',
      );
    }

    if (rows.isEmpty) break;
    totalRows += rows.length;

    // このバッチの生データ（文字列 embedding を含む）を送る直前の概算サイズ。
    for (final r in rows) {
      final emb = r['embedding'];
      if (emb is String) bytesApprox += emb.length;
    }

    if (kDebugMode) {
      debugPrint(
        '[AISearch][T+${sw.elapsedMilliseconds}ms] before_isolate_start',
      );
    }
    final batchTop = await Isolate.run(
      () => _computeBatchSimilarities(
        rows,
        userEmbedding,
        userNorm,
        minSimilarity,
        topHeap.capacity,
      ),
    );
    if (kDebugMode) {
      debugPrint(
        '[AISearch][T+${sw.elapsedMilliseconds}ms] after_isolate_end '
        'candidates=${batchTop.length}',
      );
    }

    // バッチ結果を全体の bounded heap にマージ。
    for (final e in batchTop) {
      topHeap.add(e['work_id'] as int, e['similarity'] as double);
    }

    offset += batchSize;
    // バッチ間でイベントループを空け、UI スレッドをブロックしない。
    await Future<void>.delayed(Duration.zero);
  }

  if (kDebugMode) {
    debugPrint(
      '[AISearch][T+${sw.elapsedMilliseconds}ms] all_batches_done '
      'totalRows=$totalRows heapSize=${topHeap.size}',
    );
  }

  // 全体ソートして上位 limit 件を確定。
  final topEntries = topHeap.sortedDescending().take(limit).toList();

  // 上位 limit 件の小説情報をメインスレッドで取得（sqflite は Isolate 不可）。
  // Isolate からの並び（類似度降順）を維持して結果を組み立てる。
  if (kDebugMode) {
    debugPrint('[AISearch][T+${sw.elapsedMilliseconds}ms] before_novel_join');
  }
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
  if (kDebugMode) {
    debugPrint('[AISearch][T+${sw.elapsedMilliseconds}ms] after_novel_join');
  }

  return results;
}

/// 1 バッチ分の類似度計算を Isolate 内で実行する。
///
/// 渡すのは JSON シリアライズ可能な `List<Map<String, dynamic>>`（バッチ分のみ）
/// と Float32List なので、直列化コストはバッチサイズに比例して小さい。
/// 戻り値はそのバッチ内の上位 `capacity` 件の `{work_id, similarity}`。
List<Map<String, dynamic>> _computeBatchSimilarities(
  List<Map<String, dynamic>> rows,
  Float32List userEmbedding,
  double userNorm,
  double minSimilarity,
  int capacity,
) {
  int skippedByModel = 0;
  final similarities = <_SimilarityEntry>[];
  for (final row in rows) {
    final workId = row['work_id'] as int?;
    final embRaw = row['embedding'];
    if (workId == null || embRaw == null) continue;

    // アクティブモデル・prefix 方式と異なる Embedding はスキップ
    // （モデル切り替え時に次元が変わるため、互換ベクトルのみ検索対象とする）
    if (row['model_id'] != RuriModelManager.embeddingModelId ||
        row['model_version'] != RuriModelManager.embeddingModelVersion ||
        (row['prefix_scheme_version'] as int? ?? 0) !=
            RuriModelManager.prefixSchemeVersion) {
      skippedByModel++;
      continue;
    }

    try {
      final decoded = jsonDecode(embRaw as String) as List<dynamic>;
      final embedding = Float32List.fromList(
        decoded.map((e) => (e as num).toDouble()).toList(),
      );
      if (embedding.length != userEmbedding.length) {
        debugPrint(
          '[warn] Embedding次元数不一致 workId=$workId '
          'query=${userEmbedding.length} db=${embedding.length}',
        );
        continue;
      }
      final sim = _cosineSimilarity(userEmbedding, embedding, userNorm);
      if (sim >= minSimilarity) {
        similarities.add(_SimilarityEntry(workId, sim));
      }
    } catch (e) {
      debugPrint('embedding decode error for workId=$workId: $e');
    }
  }

  if (skippedByModel > 0) {
    debugPrint(
      '[Search] モデル不一致のためスキップした Embedding: $skippedByModel 件 '
      '(現行: ${RuriModelManager.embeddingModelId} '
      'v${RuriModelManager.embeddingModelVersion})',
    );
  }

  // 類似度降順ソートしてバッチ内上位 capacity 件を返す。
  similarities.sort((a, b) => b.similarity.compareTo(a.similarity));

  return similarities
      .take(capacity)
      .map(
        (e) => <String, dynamic>{
          'work_id': e.workId,
          'similarity': e.similarity,
        },
      )
      .toList();
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

/// 類似度エントリのデータクラス
class _SimilarityEntry {
  final int workId;
  final double similarity;
  _SimilarityEntry(this.workId, this.similarity);
}

/// 類似度降順で上位 `capacity` 件だけを保持する bounded heap。
///
/// 全件をメモリに保持せず、Isolate バッチの結果をマージしながら最大 `capacity`
/// 件に絞ることで、embedding 数が増えてもメモリと最終ソートコストを抑える。
class _BoundedTopHeap {
  _BoundedTopHeap(this.capacity) : _items = [];

  final int capacity;
  final List<_SimilarityEntry> _items;

  int get size => _items.length;

  void add(int workId, double similarity) {
    _items.add(_SimilarityEntry(workId, similarity));
    if (_items.length > capacity) {
      // 最小要素を削除して capacity に戻す（線形探索で十分なサイズ）。
      var minIdx = 0;
      for (var i = 1; i < _items.length; i++) {
        if (_items[i].similarity < _items[minIdx].similarity) minIdx = i;
      }
      _items.removeAt(minIdx);
    }
  }

  List<_SimilarityEntry> sortedDescending() {
    final sorted = List<_SimilarityEntry>.from(_items)
      ..sort((a, b) => b.similarity.compareTo(a.similarity));
    return sorted;
  }
}

/// ベクトル検索の補完用：キーワード（タイトル／概要／タグ）で小説を検索する。
///
/// ベクトル検索結果が少ない場合に呼び出し、既存結果（excludeWorkIds）を
/// 除外してマージする。類似度バッジと区別できるよう is_keyword_match=1 を付与。
/// タグは tags_json（JSON 配列文字列）にも LIKE するため部分一致も拾う。
Future<List<Map<String, dynamic>>> searchNovelsByKeywordFallback({
  required Database db,
  required String query,
  required Set<int> excludeWorkIds,
  int limit = 10,
}) async {
  if (query.trim().isEmpty) return [];

  final likeArg = '%$query%';
  final rows = await db.query(
    'novels',
    where:
        '(title LIKE ? OR description LIKE ? OR tags LIKE ? OR tags_json LIKE ?)',
    whereArgs: [likeArg, likeArg, likeArg, likeArg],
    limit: limit,
  );

  return rows
      .where((row) => !excludeWorkIds.contains(row['id']))
      .map((row) => {...row, 'similarity': null, 'is_keyword_match': 1})
      .toList();
}

/// ハイブリッド検索（Step B-2）の lexical 候補取得。
///
/// 複数のキーワード・タグを OR でマッチさせ、work_id の集合を返す。
/// 完全一致タグ（exactTags）は tags_json に "tag" を含む行を優先的に拾う。
/// ここでは hard filter（R-18/AI/ブクマ/文字数）は適用せず、
/// 呼び出し側（HybridSearchService）で統合・絞り込みを行う。
Future<List<Map<String, dynamic>>> searchNovelsLexical({
  required Database db,
  required FeelingSearchQuery query,
  int limit = 200,
}) async {
  final conditions = <String>[];
  final args = <Object>[];

  final terms = <String>[
    ...query.mustKeywords,
    ...query.shouldKeywords,
    ...query.exactTags,
    ...query.partialTags,
  ];
  // キーワードが無い場合は semantic のみの検索なので空を返す
  if (terms.isEmpty && query.semanticText.trim().isEmpty) return [];

  for (final t in terms) {
    final trimmed = t.trim();
    if (trimmed.isEmpty) continue;
    // LIKEパターンではなく語自体の長さで判定（旧実装は likeArg.length で
    // 常に >= 3 となり極短語の除外が機能していなかった）。
    if (trimmed.length <= 1) continue; // 1文字の語はノイズが多すぎるため除外
    final likeArg = '%$trimmed%';
    conditions.add(
      '(title LIKE ? OR description LIKE ? OR tags LIKE ? OR tags_json LIKE ?)',
    );
    args.addAll([likeArg, likeArg, likeArg, likeArg]);
  }

  // 意味テキストも lexical 側の補完に使う（単語分割はせず全体 LIKE で緩く拾う）
  if (query.semanticText.trim().isNotEmpty) {
    final likeArg = '%${query.semanticText.trim()}%';
    conditions.add(
      '(title LIKE ? OR description LIKE ? OR tags LIKE ? OR tags_json LIKE ?)',
    );
    args.addAll([likeArg, likeArg, likeArg, likeArg]);
  }

  if (conditions.isEmpty) return [];

  final rows = await db.query(
    'novels',
    where: conditions.join(' OR '),
    whereArgs: args,
    limit: limit,
  );
  return List<Map<String, dynamic>>.from(rows);
}

/// イラスト意味検索：illust_embeddings から類似度上位を取得し、
/// illusts メタデータテーブルに結合する。novel 版と同一アルゴリズム。
Future<List<Map<String, dynamic>>> searchIllustsByEmbedding({
  required Database db,
  required Float32List userEmbedding,
  int limit = 20,
  double minSimilarity = 0.5,
}) async {
  final userNorm = _vectorNorm(userEmbedding);
  if (userNorm == 0) return [];

  final topHeap = _BoundedTopHeap(limit * 4);
  const batchSize = 100;
  int offset = 0;
  int totalRows = 0;
  int bytesApprox = 0;

  while (true) {
    final rows = await db.query(
      'illust_embeddings',
      columns: [
        'work_id',
        'embedding',
        'model_id',
        'model_version',
        'prefix_scheme_version',
      ],
      limit: batchSize,
      offset: offset,
    );
    if (rows.isEmpty) break;
    totalRows += rows.length;
    for (final r in rows) {
      final emb = r['embedding'];
      if (emb is String) bytesApprox += emb.length;
    }
    if (kDebugMode) {
      debugPrint(
        '[AISearch][illust] db_query_embeddings offset=$offset bytesApprox=$bytesApprox',
      );
    }
    final batchTop = await Isolate.run(
      () => _computeBatchSimilarities(
        rows,
        userEmbedding,
        userNorm,
        minSimilarity,
        topHeap.capacity,
      ),
    );
    for (final e in batchTop) {
      topHeap.add(e['work_id'] as int, e['similarity'] as double);
    }
    offset += batchSize;
    await Future<void>.delayed(Duration.zero);
  }

  final topEntries = topHeap.sortedDescending().take(limit).toList();
  if (kDebugMode) {
    debugPrint('[AISearch][illust] all_batches_done totalRows=$totalRows');
  }
  final results = <Map<String, dynamic>>[];
  for (final entry in topEntries) {
    final illustResult = await db.query(
      'illusts',
      where: 'id = ?',
      whereArgs: [entry.workId],
    );
    if (illustResult.isNotEmpty) {
      results.add({...illustResult.first, 'similarity': entry.similarity});
    }
  }
  if (kDebugMode) {
    debugPrint('[AISearch][illust] embedding candidates=${results.length}');
  }
  return results;
}

/// イラスト意味検索の lexical 候補取得（Step B-2）。
/// illusts テーブルに対してキーワード/タグの OR LIKE 検索を行う。
Future<List<Map<String, dynamic>>> searchIllustsLexical({
  required Database db,
  required FeelingSearchQuery query,
  int limit = 200,
}) async {
  final conditions = <String>[];
  final args = <Object>[];

  final terms = <String>[
    ...query.mustKeywords,
    ...query.shouldKeywords,
    ...query.exactTags,
    ...query.partialTags,
  ];
  if (terms.isEmpty && query.semanticText.trim().isEmpty) return [];

  for (final t in terms) {
    final trimmed = t.trim();
    if (trimmed.isEmpty) continue;
    // LIKEパターンではなく語自体の長さで判定（旧実装は likeArg.length で
    // 常に >= 3 となり極短語の除外が機能していなかった）。
    if (trimmed.length <= 1) continue; // 1文字の語はノイズが多すぎるため除外
    final likeArg = '%$trimmed%';
    conditions.add(
      '(title LIKE ? OR description LIKE ? OR tags LIKE ? OR tags_json LIKE ?)',
    );
    args.addAll([likeArg, likeArg, likeArg, likeArg]);
  }

  if (query.semanticText.trim().isNotEmpty) {
    final likeArg = '%${query.semanticText.trim()}%';
    conditions.add(
      '(title LIKE ? OR description LIKE ? OR tags LIKE ? OR tags_json LIKE ?)',
    );
    args.addAll([likeArg, likeArg, likeArg, likeArg]);
  }

  if (conditions.isEmpty) return [];

  final rows = await db.query(
    'illusts',
    where: conditions.join(' OR '),
    whereArgs: args,
    limit: limit,
  );
  return List<Map<String, dynamic>>.from(rows);
}
