import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../ruri_model_manager.dart';
import '../../novel_model.dart';
import '../../illust_model.dart';

part 'database_core.part.dart';
part 'database_schema.part.dart';
part 'database_novel_meta.part.dart';
part 'database_history.part.dart';
part 'database_download_queue.part.dart';
part 'database_read_later.part.dart';
part 'database_mutes.part.dart';
part 'database_folders.part.dart';
part 'database_subscriptions.part.dart';

/// データベース初期化・管理用クラス
class DatabaseService extends DatabaseServiceSubscriptions {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  // ==========================================
  // READING NOTES (読書メモ・引用メモ、Phase N6 / DB v24)
  // ==========================================

  /// 読書メモを追加する。空白のみの [noteText] は拒否して -1 を返す。
  /// [anchorText] はメモ位置のページ先頭テキスト（引用表示用・任意）。
  Future<int> addReadingNote({
    required int workId,
    required int pageIndex,
    required String noteText,
    String workType = 'novel',
    String? anchorText,
  }) async {
    final text = noteText.trim();
    if (text.isEmpty) return -1;
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    final anchor = (anchorText ?? '').trim();
    return await db.insert('reading_notes', {
      'work_id': workId,
      'work_type': workType,
      'page_index': pageIndex,
      'anchor_text': anchor.isEmpty ? null : anchor,
      'note_text': text,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 読書メモの本文を更新する。空白のみは拒否して -1 を返す。
  /// [anchorText] が指定された場合のみアンカーも更新する。
  Future<int> updateReadingNote(
    int id,
    String noteText, {
    String? anchorText,
  }) async {
    final text = noteText.trim();
    if (text.isEmpty) return -1;
    final db = await database;
    final values = <String, dynamic>{
      'note_text': text,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (anchorText != null) values['anchor_text'] = anchorText;
    return await db.update(
      'reading_notes',
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 読書メモを1件削除する。
  Future<int> deleteReadingNote(int id) async {
    final db = await database;
    return await db.delete('reading_notes', where: 'id = ?', whereArgs: [id]);
  }

  /// 読書メモの一覧を取得する（新しい順: created_at DESC, id DESC）。
  /// [workId] が指定された場合はその作品のみのメモを返す。
  Future<List<Map<String, dynamic>>> getReadingNotes({int? workId}) async {
    final db = await database;
    final rows = workId == null
        ? await db.query('reading_notes', orderBy: 'created_at DESC, id DESC')
        : await db.query(
            'reading_notes',
            where: 'work_id = ?',
            whereArgs: [workId],
            orderBy: 'created_at DESC, id DESC',
          );
    return List<Map<String, dynamic>>.from(rows);
  }

  /// 起動時に1回だけ実行する軽量なデータ修復。
  ///
  /// 旧バグ版で保存された「id=0（無効）」の小説レコードを novels / novel_embeddings
  /// から削除する。これらは getNovelById(0) で必ず 404 になるため、検索結果に
  /// 二度と出ないよう排除する。DBバージョンは変更しない（単純な DELETE のみ）。
  /// 費用は最大でも既存件数分の数行 DELETE なので、起動時のブロックは無視できる。
  Future<void> cleanupInvalidNovelRecords() async {
    try {
      final db = await database;
      // id=0 は明らかに無効なレコード
      final deletedNovels = await db.delete(
        'novels',
        where: 'id = ?',
        whereArgs: [0],
      );
      final deletedEmbeddings = await db.delete(
        'novel_embeddings',
        where: 'work_id = ?',
        whereArgs: [0],
      );
      final deletedText = await db.delete(
        'novel_text',
        where: 'work_id = ?',
        whereArgs: [0],
      );
      if (deletedNovels > 0 || deletedEmbeddings > 0 || deletedText > 0) {
        debugPrint(
          '[Cleanup] 無効な小説レコード(id=0)を削除しました: '
          'novels=$deletedNovels, embeddings=$deletedEmbeddings, text=$deletedText',
        );
      }
    } catch (e) {
      debugPrint('[Cleanup] 無効レコード削除中にエラー: $e');
    }
  }

  /// 指定した小説IDが「削除済み / 存在しない（404）」と判定された場合に呼び出し、
  /// novels / novel_embeddings / novel_text から該当レコードを遅延削除する。
  ///
  /// 一括APIバリデーションは行わず、ユーザーが実際にタップして 404 になった時点で
  /// のみ呼ぶ（レート制限回避）。次回検索・一覧からは該当作品が出なくなる。
  /// 小説詳細取得エラーから「本当にローカル削除してよいか」を判定する。
  ///
  /// 削除してよい（真の削除・非公開・閲覧不可）:
  ///   - エラー本文が「小説が見つかりませんでした」等、作品単位の不存在
  ///   - 404 かつエンドポイント不存在系の文言を含まない
  ///
  /// 削除してはいけない（API側仕様変更・認証・通信・レート制限の疑い）:
  ///   - 「指定されたエンドポイントは存在しません」「エンドポイントが存在しない」
  ///   - 401 / 403 / 429（認証・権限・レート制限）
  ///   - それ以外の通信エラー・例外
  static bool isGenuineNovelMissing(String errorMessage) {
    final msg = errorMessage.toLowerCase();
    // エンドポイント不存在系は絶対に削除しない（API仕様変更の誤判定）
    if (msg.contains('指定されたエンドポイント') ||
        msg.contains('エンドポイント') ||
        msg.contains('endpoint') ||
        msg.contains('存在しません')) {
      return false;
    }
    // 認証・権限・レート制限は削除しない
    if (msg.contains('401') ||
        msg.contains('403') ||
        msg.contains('429') ||
        msg.contains('unauthorized') ||
        msg.contains('forbidden') ||
        msg.contains('rate limit')) {
      return false;
    }
    // 作品が存在しない（404 / 見つかりませんでした）のみ削除対象
    return msg.contains('404') || msg.contains('見つかりませんでした');
  }

  /// 404等で存在しないと判定された小説のローカル残骸を遅延削除（novels/embeddings/text）。
  /// ただし [errorMessage] が与えられた場合は [isGenuineNovelMissing] で
  /// 真の削除かどうかを厳格に判定し、API側仕様変更等の疑いがあれば削除しない。
  Future<void> removeInvalidNovel(int novelId, {String? errorMessage}) async {
    if (novelId <= 0) return;
    if (errorMessage != null && !isGenuineNovelMissing(errorMessage)) {
      debugPrint(
        '[Cleanup] エラーが「真の小説削除」ではないため削除を見送りました: id=$novelId (error=$errorMessage)',
      );
      return;
    }
    try {
      final db = await database;
      await db.delete('novels', where: 'id = ?', whereArgs: [novelId]);
      await db.delete(
        'novel_embeddings',
        where: 'work_id = ?',
        whereArgs: [novelId],
      );
      await db.delete('novel_text', where: 'work_id = ?', whereArgs: [novelId]);
      debugPrint('[Cleanup] 404 小説を削除しました: id=$novelId');
    } catch (e) {
      debugPrint('[Cleanup] 404 小説削除中にエラー(id=$novelId): $e');
    }
  }

  /// 全テーブルの内容を削除
  Future<void> clearAllTables() async {
    final db = await database;
    await db.delete('history');
    await db.delete('novels');
    await db.delete('novel_text');
    await db.delete('novel_embeddings');
    await db.delete('downloaded_illust');
    await db.delete('mutes');
    await db.delete('folder_items');
    await db.delete('folders');
    await db.delete('tts_reading_positions');
    await db.delete('usage_sessions');
    await db.delete('image_embeddings');
    await db.delete('image_fingerprints');
  }

  /// DBインスタンスを再起動（復元後のリフレッシュ用）
  Future<void> restartDatabase() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  // ==========================================
  // バックアップ/リストア（Google Drive 連携用）
  // ==========================================

  /// 全テーブルのデータを Map としてエクスポート
  Future<Map<String, dynamic>> exportAllData() async {
    final db = await database;
    final tables = [
      'history',
      'novels',
      'novel_text',
      'novel_embeddings',
      'downloaded_illust',
      'mutes',
      'folders',
      'folder_items',
      'subscribed_tags',
      'read_later',
      'search_history',
      'reading_notes',
    ];
    final Map<String, dynamic> result = {};
    for (final table in tables) {
      result[table] = await db.query(table);
    }
    return result;
  }

  // ==========================================================================
  // TTS読み上げ位置（tts_reading_positions）CRUD - Phase 3 (v18)
  // ==========================================================================

  /// TTS読み上げの再開位置を保存（UPSERT）。
  Future<int> saveTtsPosition({
    required int workId,
    required int chunkIndex,
    required int pageIndex,
  }) async {
    final db = await database;
    return await db.insert('tts_reading_positions', {
      'work_id': workId,
      'chunk_index': chunkIndex,
      'page_index': pageIndex,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// TTS読み上げの再開位置を取得（なければ null）。
  Future<Map<String, dynamic>?> getTtsPosition(int workId) async {
    final db = await database;
    final result = await db.query(
      'tts_reading_positions',
      where: 'work_id = ?',
      whereArgs: [workId],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  /// TTS読み上げ位置を削除（読了時等）。
  Future<int> deleteTtsPosition(int workId) async {
    final db = await database;
    return await db.delete(
      'tts_reading_positions',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }

  // ==========================================================================
  // 利用時間トラッキング（usage_sessions）CRUD
  // ==========================================================================

  /// 利用セッション断片を1行保存する（Phase 4: UsageTrackingService から使用）。
  Future<int> insertUsageSession({
    required String workType,
    required int workId,
    required DateTime startedAt,
    required DateTime endedAt,
    required int durationSeconds,
  }) async {
    final db = await database;
    return await db.insert('usage_sessions', {
      'work_type': workType,
      'work_id': workId,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt.toIso8601String(),
      'duration_seconds': durationSeconds,
    });
  }

  /// 利用セッションを全件取得（新しい順）。集計は computeUsageStatsMap で行う。
  Future<List<Map<String, dynamic>>> getUsageSessions() async {
    final db = await database;
    return await db.query('usage_sessions', orderBy: 'started_at DESC');
  }

  /// 利用セッションを全削除（プライバシー用の完全削除から使用）。
  Future<int> deleteAllUsageSessions() async {
    final db = await database;
    return await db.delete('usage_sessions');
  }

  // ==========================================================================
  // 視覚類似検索（image_embeddings）CRUD — Phase 5
  // ==========================================================================

  /// 視覚エンベディングを保存（UPSERT）。embedding は Float32List の BLOB。
  Future<int> saveImageEmbedding({
    required int illustId,
    required Uint8List embedding,
    required int dim,
  }) async {
    final db = await database;
    return await db.insert('image_embeddings', {
      'illust_id': illustId,
      'embedding': embedding,
      'dim': dim,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全視覚エンベディングを取得（類似検索のスキャン用）。
  Future<List<Map<String, dynamic>>> getAllImageEmbeddings() async {
    final db = await database;
    return await db.query('image_embeddings');
  }

  /// 指定イラストの視覚エンベディングを削除（画像削除時の整合性維持）。
  Future<int> deleteImageEmbedding(int illustId) async {
    final db = await database;
    return await db.delete(
      'image_embeddings',
      where: 'illust_id = ?',
      whereArgs: [illustId],
    );
  }

  // ==========================================================================
  // 画像指納（image_fingerprints）CRUD — Phase 6
  // ==========================================================================

  /// 画像指納を保存（UPSERT）。
  Future<int> saveImageFingerprint({
    required int illustId,
    required String sha256,
    required int dhash,
  }) async {
    final db = await database;
    return await db.insert('image_fingerprints', {
      'illust_id': illustId,
      'sha256': sha256,
      'dhash': dhash,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 全画像指納を取得（重複検出のスキャン用）。
  Future<List<Map<String, dynamic>>> getAllImageFingerprints() async {
    final db = await database;
    return await db.query('image_fingerprints');
  }

  /// 指定イラストの指納を削除（画像削除時の整合性維持）。
  Future<int> deleteImageFingerprint(int illustId) async {
    final db = await database;
    return await db.delete(
      'image_fingerprints',
      where: 'illust_id = ?',
      whereArgs: [illustId],
    );
  }

  // ==========================================================================
  // 小説の感情曲線（emotion_curves）CRUD — Phase C (v23)
  // ==========================================================================

  /// 小説の感情曲線キャッシュを保存（UPSERT）。
  /// 本文から再生成可能なため Google Drive バックアップ対象外。
  Future<int> saveEmotionCurve({
    required int workId,
    required String modelId,
    required String chunksJson,
  }) async {
    final db = await database;
    return await db.insert('emotion_curves', {
      'work_id': workId,
      'model_id': modelId,
      'chunks_json': chunksJson,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 指定小説の感情曲線キャッシュを取得（無い場合は null）。
  Future<Map<String, dynamic>?> getEmotionCurve(int workId) async {
    final db = await database;
    final rows = await db.query(
      'emotion_curves',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  /// 指定小説の感情曲線キャッシュを削除。
  Future<int> deleteEmotionCurve(int workId) async {
    final db = await database;
    return await db.delete(
      'emotion_curves',
      where: 'work_id = ?',
      whereArgs: [workId],
    );
  }

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

  /// エクスポートされた全データをインポート（マージ）する。
  /// 各テーブルを消去してから全件 insert（replace）する。
  /// 戻り値: 各テーブルの追加/更新件数
  Future<Map<String, int>> importAllData(Map<String, dynamic> data) async {
    final db = await database;
    final Map<String, int> summary = {};

    final tableSchemes = {
      'history': [
        'id',
        'title',
        'type',
        'work_id',
        'url',
        'metadata',
        'created_at',
      ],
      'novels': [
        'id',
        'title',
        'description',
        'author_id',
        'series_id',
        'series_order',
        'text',
        'text_length',
        'tags',
        'tags_json',
        'x_restrict',
        'novel_ai_type',
        'created_at',
        'updated_at',
        'author_name',
        'cover_url',
        'page_count',
        'total_bookmarks',
        'create_date',
        'total_view',
        'meta_json',
      ],
      'novel_text': [
        'work_id',
        'pages_json',
        'text',
        'illustrations_json',
        'updated_at',
      ],
      'novel_embeddings': [
        'work_id',
        'embedding',
        'model_id',
        'model_version',
        'prefix_scheme_version',
        'updated_at',
      ],
      'downloaded_illust': [
        'illust_id',
        'local_path',
        'thumbnail_path',
        'download_date',
      ],
      'mutes': ['id', 'mute_type', 'value', 'label'],
      'folders': ['id', 'name', 'created_at'],
      'folder_items': [
        'id',
        'folder_id',
        'work_id',
        'title',
        'author_name',
        'preview_url',
        'type',
        'added_at',
      ],
      'read_later': [
        'id',
        'work_id',
        'title',
        'author_name',
        'author_id',
        'cover_url',
        'text_length',
        'tags_json',
        'x_restrict',
        'status',
        'added_at',
        'last_opened_at',
        'finished_at',
      ],
      'reading_notes': [
        'id',
        'work_id',
        'work_type',
        'page_index',
        'anchor_text',
        'note_text',
        'created_at',
        'updated_at',
      ],
    };

    // subscribed_tags は専用処理（他テーブルは汎用ループで処理）
    await _importSubscribedTags(data, db, summary);

    // 新着キャッシュ（subscription_new_items）は端末ローカル扱いでバックアップ
    // 対象外。subscribed_tags の id が再採番されるため、参照切れレコードを
    // 残さないよう復元時にクリアする。
    await db.delete('subscription_new_items');

    for (final entry in tableSchemes.entries) {
      final table = entry.key;
      if (table == 'subscribed_tags') continue; // 専用ブロックで処理済み
      final columns = entry.value;
      final rows = data[table];
      if (rows is! List) continue;

      // 既存データを消去
      await db.delete(table);

      var count = 0;
      final batch = db.batch();
      for (final raw in rows) {
        if (raw is! Map) continue;
        final Map<String, dynamic> row = Map<String, dynamic>.from(raw);
        final cleaned = <String, dynamic>{};
        for (final col in columns) {
          if (row.containsKey(col)) {
            cleaned[col] = row[col];
          }
        }
        // 旧バックアップ互換: モデル識別列が無い/空/0 の場合の補完（Task 6 強化）。
        // ただし「実際に現在の Ruri モデルで生成された互換ベクトル」のみ上書きし、
        // 壊れた/旧モデル(MiniLM等)の非互換ベクトルは偽装せず再インデックス対象に残す。
        if (table == 'novel_embeddings') {
          final rawEmb = cleaned['embedding'];
          var validDim = false;
          if (rawEmb is String && rawEmb.isNotEmpty) {
            try {
              final decoded = jsonDecode(rawEmb) as List<dynamic>;
              validDim =
                  decoded.length == RuriModelManager.embeddingDimension &&
                  RuriModelManager.embeddingModelId.isNotEmpty;
            } catch (_) {
              validDim = false;
            }
          }
          if (validDim) {
            final mid = cleaned['model_id'];
            if (mid == null || mid is! String || mid.isEmpty) {
              cleaned['model_id'] = RuriModelManager.embeddingModelId;
            }
            final mv = cleaned['model_version'];
            if (mv == null || (mv is int && mv <= 0)) {
              cleaned['model_version'] = RuriModelManager.embeddingModelVersion;
            }
            final ps = cleaned['prefix_scheme_version'];
            if (ps == null || (ps is int && ps <= 0)) {
              cleaned['prefix_scheme_version'] =
                  RuriModelManager.prefixSchemeVersion;
            }
          }
          // 非互換(dim不一致/壊れ)は識別値を埋めず、検索時にスキップされる
        } else if (table == 'novels') {
          // 旧バックアップでメタデータ列が欠落していた場合でも、
          // 明示的な安全値で補完して復元時の不完全挿入を防ぐ。
          // （本来は saveNovel 経由で全メタデータが保存されるため、
          //  現在のバックアップには全列が含まれる。この補完は
          //  過去バックアップ互換・堅牢性のための措置。）
          final defaults = <String, dynamic>{
            'author_name': '',
            'cover_url': '',
            'page_count': 0,
            'total_bookmarks': 0,
            'total_view': 0,
            'create_date': '',
            'created_at': DateTime.now().toIso8601String(),
            'text_length': 0,
            'tags': '',
            'tags_json': '[]',
            'x_restrict': 0,
            'novel_ai_type': 0,
          };
          defaults.forEach((k, v) {
            if (!cleaned.containsKey(k)) cleaned[k] = v;
          });
          if (!cleaned.containsKey('meta_json') ||
              (cleaned['meta_json'] as String? ?? '').isEmpty) {
            // meta_json が無い場合は既存の列から最小限の JSON を構築
            cleaned['meta_json'] = jsonEncode({
              'id': cleaned['id'],
              'title': cleaned['title'] ?? '',
              'caption': cleaned['description'] ?? '',
            });
          }
        }
        batch.insert(
          table,
          cleaned,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        count++;
      }
      await batch.commit(noResult: true);
      summary[table] = count;
    }

    // 復元検証ログ（デバッグ用）: フィーリング発掘関連カラムの欠落を検出
    final restoredNovels = await db.query('novels');
    final restoredEmb = await db.query('novel_embeddings');
    final textLenOk = restoredNovels
        .where((r) => (r['text_length'] as int? ?? 0) > 0)
        .length;
    final pageOk = restoredNovels
        .where((r) => (r['page_count'] as int? ?? 0) > 0)
        .length;
    final metaOk = restoredNovels
        .where((r) => (r['meta_json'] as String? ?? '').toString().isNotEmpty)
        .length;
    final embModelOk = restoredEmb
        .where((r) => (r['model_id'] as String? ?? '').toString().isNotEmpty)
        .length;
    debugPrint(
      '[importAllData] 復元検証: novels=${restoredNovels.length} '
      '(text_length>0: $textLenOk, page_count>0: $pageOk, meta_json: $metaOk), '
      'novel_embeddings=${restoredEmb.length} (model_id設定: $embModelOk)'
      '${embModelOk < restoredEmb.length ? " [警告] モデル不整合の埋め込みあり" : ""}, '
      'summary=$summary',
    );

    return summary;
  }

  /// subscribed_tags をインポートする（Google Drive バックアップ/復元用）。
  ///
  /// 方針:
  /// - テーブルを一旦消去し、バックアップから再構築（他テーブルと同じ流れ）。
  /// - id は固定復元せず環境ごとに再採番する（AUTOINCREMENT）。
  /// - tag/type が空のレコードは skip（壊れた1件で全体を落とさない）。
  /// - created_at が欠損/空なら現在時刻(UTC)で補完。
  /// - last_checked_at / last_newest_date が無くても落ちない（NULL で許容）。
  /// - last_new_count が無ければ 0 で補完。
  /// - 後方互換: バックアップ JSON に subscribed_tags が無い場合は何もしない。
  Future<void> _importSubscribedTags(
    Map<String, dynamic> data,
    Database db,
    Map<String, int> summary,
  ) async {
    final rows = data['subscribed_tags'];
    if (rows is! List) {
      summary['subscribed_tags'] = 0;
      return;
    }

    // 既存データを消去
    await db.delete('subscribed_tags');

    final now = DateTime.now().toUtc().toIso8601String();
    var count = 0;
    final batch = db.batch();
    for (final raw in rows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final tag = (row['tag'] as String?)?.toString() ?? '';
      final type = (row['type'] as String?)?.toString() ?? '';
      // 空の tag/type はスキップ（不正データ）
      if (tag.isEmpty || type.isEmpty) continue;

      final createdAt = (row['created_at'] as String?)?.isNotEmpty == true
          ? row['created_at'] as String
          : now;
      final lastNewCount = (row['last_new_count'] as int?) ?? 0;

      batch.insert('subscribed_tags', {
        'tag': tag,
        'type': type,
        'created_at': createdAt,
        'last_checked_at': row['last_checked_at'],
        'last_newest_date': row['last_newest_date'],
        'last_new_count': lastNewCount,
      });
      count++;
    }
    await batch.commit(noResult: true);
    summary['subscribed_tags'] = count;
  }
}
