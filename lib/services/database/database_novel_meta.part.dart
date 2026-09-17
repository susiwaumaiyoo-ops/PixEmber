part of 'database_service.dart';

/// 小説メタ・埋め込み・小説本文キャッシュ・LLM要約参照を担う層。
/// Phase 3a: DatabaseService から移動（本体は 1 文字も変更せずそのまま）。
abstract class DatabaseServiceNovelMeta extends DatabaseServiceSchema {
  // ==========================================
  // NOVELS (小説本文・ベクトル・購読タグ) - 便利メソッド
  // ==========================================

  /// 小説本文をキャッシュ（UPSERT）。
  /// [illustrationsJson] は挿絵 URL マップ（`"{uploadedimageId}": url` /
  /// `"pixiv:{illustId}:{page}": url`）の JSON エンコード文字列（設計書 §9.2）。
  Future<int> saveNovelText({
    required int workId,
    required String title,
    required String authorName,
    required String text,
    required String pagesJson,
    String? illustrationsJson,
  }) async {
    final db = await database;
    return await db.insert('novel_text', {
      'work_id': workId,
      'title': title,
      'author_name': authorName,
      'pages_json': pagesJson,
      'text': text,
      'illustrations_json': ?illustrationsJson,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// キャッシュされた小説本文を取得
  /// 要約が1件以上保存されている work_id の集合（自動要約の軽量事前除外用）。
  /// モデル/指紋を問わない work_id レベルの判定。規模は要約総数と同オーダー
  /// （現状数十〜数百）で、DISTINCT 取得は十分軽い。厳密な有効性は
  /// LlmSummaryCacheService 側で従来通り検証する。
  Future<Set<int>> getSummarizedWorkIds() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT work_id FROM llm_summaries',
    );
    return rows.map((r) => r['work_id'] as int).where((id) => id > 0).toSet();
  }

  Future<Map<String, dynamic>?> getNovelText(int workId) async {
    final db = await database;
    final result = await db.query(
      'novel_text',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
    if (result.isEmpty) return null;
    return result.first;
  }
  // ==========================================================================
  // オフライン本棚（novel_text キャッシュ）CRUD
  // ==========================================================================

  /// キャッシュされた小説本文の一覧を取得する。
  /// 各要素には 'work_id' / 'title' / 'author_name' / 'updated_at' /
  /// 'text'（文字列長からバイト数を概算）/ 'char_count'（本文文字数）を含む。
  /// updated_at の新しい順でソート。
  Future<List<Map<String, dynamic>>> getCachedNovelTexts() async {
    final db = await database;
    final rows = await db.query(
      'novel_text',
      columns: ['work_id', 'title', 'author_name', 'updated_at', 'text'],
      orderBy: 'updated_at DESC',
    );
    // 概算バイト数・文字数を付与して返す
    return rows.map((r) {
      final text = (r['text'] as String?) ?? '';
      // UTF-8 バイト長で概算キャッシュサイズを算出
      final bytes = text.isEmpty ? 0 : text.length * 3;
      return <String, dynamic>{
        ...r,
        'char_count': text.length,
        'approx_bytes': bytes,
      };
    }).toList();
  }

  /// キャッシュされた小説本文を1件削除する。
  Future<int> deleteCachedNovelText(int workId) async {
    final db = await database;
    return await db.delete(
      'novel_text',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }

  /// [beforeDays] 日以上前に保存されたキャッシュを一括削除する。
  /// [beforeDays] に 0 以下を指定した場合はすべて削除する。
  /// 削除件数を返す。
  Future<int> deleteOldCachedNovelTexts({int beforeDays = 0}) async {
    final db = await database;
    if (beforeDays <= 0) {
      return await db.delete('novel_text');
    }
    final threshold = DateTime.now()
        .toUtc()
        .subtract(Duration(days: beforeDays))
        .toIso8601String();
    return await db.delete(
      'novel_text',
      where: 'updated_at IS NOT NULL AND updated_at < ?',
      whereArgs: [threshold],
    );
  }

  /// 全キャッシュの概算バイト数合計を取得する（文字列長 × 3 で UTF-8 概算）。
  Future<int> getCachedNovelTextsTotalBytes() async {
    final list = await getCachedNovelTexts();
    return list.fold<int>(
      0,
      (sum, r) => sum + ((r['approx_bytes'] as int?) ?? 0),
    );
  }

  /// 完全な Novel モデルを novels テーブルへ保存（UPSERT）。
  /// アプリ内の小説メタデータ保存はこのメソッドに一本化する。
  /// meta_json に Novel.toJson() 全体を保存し、getNovelMeta() で完全復元できる。
  Future<int> saveNovel(Novel novel) async {
    final db = await database;
    final existing = await db.query(
      'novels',
      where: 'id = ?',
      whereArgs: [novel.id],
    );
    final now = DateTime.now().toIso8601String();
    final row = <String, dynamic>{
      'id': novel.id,
      'title': novel.title,
      'description': novel.caption,
      'author_id': novel.author.id,
      'author_name': novel.author.name,
      'series_id': novel.series?.id ?? 0,
      'series_order': novel.seriesOrder ?? 0,
      'text_length': novel.textLength,
      'tags': novel.tags.join(','),
      'tags_json': jsonEncode(novel.tags),
      'x_restrict': novel.xRestrict,
      'novel_ai_type': novel.aiType,
      'cover_url': novel.coverUrl,
      'page_count': novel.pageCount,
      'total_bookmarks': novel.totalBookmarks,
      'total_view': novel.totalView,
      'create_date': novel.createDate,
      'meta_json': jsonEncode({
        ...novel.toJson(),
        if (novel.series != null) 'series_title': novel.series!.title,
      }),
      'updated_at': now,
    };
    if (existing.isNotEmpty) {
      // 本文など API から取得しない列は既存値を保持する
      final old = existing.first;
      row['text'] = old['text'] ?? '';
      row['created_at'] = old['created_at'] ?? now;
      if (novel.textLength == 0) {
        row['text_length'] = old['text_length'] ?? 0;
      }
    } else {
      row['text'] = '';
      row['created_at'] = now;
    }
    return await db.insert(
      'novels',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// novels テーブルから完全な Novel を復元する（meta_json 優先）。
  /// meta_json がない旧データは null を返し、呼び出し側で API 補完させる。
  Future<Novel?> getNovelMeta(int workId) async {
    final db = await database;
    final rows = await db.query(
      'novels',
      where: 'id = ?',
      whereArgs: [workId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final metaJson = rows.first['meta_json'] as String?;
    if (metaJson == null || metaJson.isEmpty) return null;
    try {
      final map = jsonDecode(metaJson) as Map<String, dynamic>;
      return Novel.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// 小説のベクトルを保存（UPSERT）
  Future<int> saveNovelEmbedding({
    required int workId,
    required Float32List embedding,
  }) async {
    final db = await database;
    return await db.insert('novel_embeddings', {
      'work_id': workId,
      'embedding': jsonEncode(embedding.toList()),
      'model_id': RuriModelManager.embeddingModelId,
      'model_version': RuriModelManager.embeddingModelVersion,
      'prefix_scheme_version': RuriModelManager.prefixSchemeVersion,
      'embedding_dim': RuriModelManager.embeddingDimension,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 指定した work_id のうち、novel_embeddings にベクトルが存在しないものを返す。
  /// バックグラウンド Embedding 生成の対象抽出に使用する。
  Future<List<int>> getWorkIdsWithoutEmbedding(List<int> workIds) async {
    if (workIds.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(workIds.length, '?').join(',');
    final rows = await db.query(
      'novel_embeddings',
      columns: ['work_id'],
      where:
          'work_id IN ($placeholders) AND model_id = ? AND model_version = ? AND prefix_scheme_version = ?',
      whereArgs: [
        ...workIds,
        RuriModelManager.embeddingModelId,
        RuriModelManager.embeddingModelVersion,
        RuriModelManager.prefixSchemeVersion,
      ],
    );
    final existing = rows.map((r) => r['work_id'] as int).toSet();
    return workIds.where((id) => !existing.contains(id)).toList();
  }

  /// イラストのベクトルを保存（UPSERT）。novel 版と同型。
  Future<int> saveIllustEmbedding({
    required int workId,
    required Float32List embedding,
  }) async {
    final db = await database;
    return await db.insert('illust_embeddings', {
      'work_id': workId,
      'embedding': jsonEncode(embedding.toList()),
      'model_id': RuriModelManager.embeddingModelId,
      'model_version': RuriModelManager.embeddingModelVersion,
      'prefix_scheme_version': RuriModelManager.prefixSchemeVersion,
      'embedding_dim': RuriModelManager.embeddingDimension,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 指定した work_id のうち、illust_embeddings にベクトルが存在しないものを返す。
  /// バックグラウンド Embedding 生成の対象抽出に使用する。
  Future<List<int>> getIllustIdsWithoutEmbedding(List<int> workIds) async {
    if (workIds.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(workIds.length, '?').join(',');
    final rows = await db.query(
      'illust_embeddings',
      columns: ['work_id'],
      where:
          'work_id IN ($placeholders) AND model_id = ? AND model_version = ? AND prefix_scheme_version = ?',
      whereArgs: [
        ...workIds,
        RuriModelManager.embeddingModelId,
        RuriModelManager.embeddingModelVersion,
        RuriModelManager.prefixSchemeVersion,
      ],
    );
    final existing = rows.map((r) => r['work_id'] as int).toSet();
    return workIds.where((id) => !existing.contains(id)).toList();
  }

  /// イラストの検索用メタデータを保存（UPSERT）。
  /// illust_embeddings とセットで書き込み、ハイブリッド検索（illust モード）の
  /// 結合元とする。novels と同名カラムでスコア計算を共有化する。
  Future<int> saveIllustMeta(Illust illust) async {
    final db = await database;
    return await db.insert('illusts', {
      'id': illust.id,
      'title': illust.title,
      'description': illust.caption,
      'author_id': illust.author.id,
      'tags': illust.tags.join(','),
      'tags_json': jsonEncode(illust.tags),
      'x_restrict': illust.xRestrict,
      'novel_ai_type': illust.aiType,
      'created_at': illust.createDate,
      'updated_at': DateTime.now().toIso8601String(),
      'author_name': illust.author.name,
      'cover_url': illust.urls.preview ?? '',
      'page_count': illust.pageCount,
      'total_bookmarks': illust.totalBookmarks,
      'create_date': illust.createDate,
      'total_view': illust.totalView,
      'meta_json': jsonEncode(illust.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// イラストの検索用メタデータを取得する。
  /// 存在しない場合は null を返す。
  Future<Map<String, dynamic>?> getIllustMeta(int workId) async {
    final db = await database;
    final rows = await db.query(
      'illusts',
      where: 'id = ?',
      whereArgs: [workId],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }
}
