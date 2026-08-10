import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'ruri_model_manager.dart';

/// データベース初期化・管理用クラス
class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;

  /// データベースインスタンスを取得
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'pixiv_viewer.db');
    return await openDatabase(
      path,
      version: 7,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        type TEXT NOT NULL,
        work_id INTEGER NOT NULL,
        author_name TEXT NOT NULL DEFAULT '',
        url TEXT,
        metadata TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE novels (
        id INTEGER PRIMARY KEY,
        title TEXT,
        description TEXT,
        author_id INTEGER,
        series_id INTEGER,
        series_order INTEGER,
        text TEXT,
        text_length INTEGER,
        tags TEXT,
        tags_json TEXT,
        x_restrict INTEGER,
        novel_ai_type INTEGER,
        created_at TEXT,
        updated_at TEXT,
        author_name TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        page_count INTEGER NOT NULL DEFAULT 0,
        total_bookmarks INTEGER NOT NULL DEFAULT 0,
        create_date TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE novel_text (
        work_id INTEGER PRIMARY KEY,
        pages_json TEXT,
        text TEXT,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE novel_embeddings (
        work_id INTEGER PRIMARY KEY,
        embedding TEXT,
        model_id TEXT NOT NULL DEFAULT '',
        model_version INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE downloaded_illust (
        illust_id INTEGER PRIMARY KEY,
        local_path TEXT NOT NULL,
        thumbnail_path TEXT,
        download_date TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE mutes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mute_type TEXT NOT NULL,
        value TEXT NOT NULL,
        label TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE folder_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        folder_id INTEGER NOT NULL,
        work_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        author_name TEXT NOT NULL,
        preview_url TEXT NOT NULL,
        type TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        FOREIGN KEY (folder_id) REFERENCES folders(id) ON DELETE CASCADE
      )
    ''');

    // 検索用インデックス
    await db.execute('CREATE INDEX idx_history_workid ON history(work_id)');
    await db.execute(
      'CREATE INDEX idx_folder_items_folderid ON folder_items(folder_id)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // label 列を追加（既存DB互換）
      await db.execute('ALTER TABLE mutes ADD COLUMN label TEXT');
    }
    if (oldVersion < 3) {
      // subscribed_tags テーブルの作成
      await db.execute('''
        CREATE TABLE IF NOT EXISTS subscribed_tags (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tag TEXT NOT NULL,
          type TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
      // novel_text に title / author_name 列を追加（既存DB互換）
      await db.execute('ALTER TABLE novel_text ADD COLUMN title TEXT');
      await db.execute('ALTER TABLE novel_text ADD COLUMN author_name TEXT');
    }
    if (oldVersion < 4) {
      // history テーブルに author_name 列を追加（既存DB互換、既存データは保持）
      final columns = await db.rawQuery('PRAGMA table_info(history)');
      final hasAuthorName = columns.any((c) => c['name'] == 'author_name');
      if (!hasAuthorName) {
        await db.execute(
          'ALTER TABLE history ADD COLUMN author_name TEXT NOT NULL DEFAULT \'\'',
        );
      }
    }
    if (oldVersion < 5) {
      // novels テーブルにメタデータ列を追加（既存DB互換、既存データは保持）
      final columns = await db.rawQuery('PRAGMA table_info(novels)');
      final existing = columns.map((c) => c['name'] as String).toSet();
      if (!existing.contains('author_name')) {
        await db.execute(
          'ALTER TABLE novels ADD COLUMN author_name TEXT NOT NULL DEFAULT \'\'',
        );
      }
      if (!existing.contains('cover_url')) {
        await db.execute(
          'ALTER TABLE novels ADD COLUMN cover_url TEXT NOT NULL DEFAULT \'\'',
        );
      }
      if (!existing.contains('page_count')) {
        await db.execute(
          'ALTER TABLE novels ADD COLUMN page_count INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!existing.contains('total_bookmarks')) {
        await db.execute(
          'ALTER TABLE novels ADD COLUMN total_bookmarks INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!existing.contains('create_date')) {
        await db.execute(
          'ALTER TABLE novels ADD COLUMN create_date TEXT NOT NULL DEFAULT \'\'',
        );
      }
    }
    if (oldVersion < 6) {
      // 次元数バグ（encode() の hiddenSize 計算誤り）により
      // 壊れた Embedding データを全削除する。novels 等のメタデータは保持。
      await db.delete('novel_embeddings');
      debugPrint('[Migration] novel_embeddings cleared (次元数バグの修正)');
    }
    if (oldVersion < 7) {
      // Ruri v3-310m INT8（768次元）への移行。
      // 旧モデル(MiniLM 384次元)の Embedding は互換性がないため全削除する。
      // novels / novel_text / history / folders 等のデータは維持する。
      final columns = await db.rawQuery('PRAGMA table_info(novel_embeddings)');
      final existing = columns.map((c) => c['name'] as String).toSet();
      if (!existing.contains('model_id')) {
        await db.execute(
          "ALTER TABLE novel_embeddings ADD COLUMN model_id TEXT NOT NULL DEFAULT ''",
        );
      }
      if (!existing.contains('model_version')) {
        await db.execute(
          'ALTER TABLE novel_embeddings ADD COLUMN model_version INTEGER NOT NULL DEFAULT 0',
        );
      }
      final deleted = await db.delete('novel_embeddings');
      debugPrint(
        '[Migration v6->v7] novel_embeddings を全削除しました: $deleted 件 '
        '(旧モデルのベクトルは Ruri v3 と非互換のため)',
      );
      debugPrint(
        '[Migration v6->v7] モデル管理情報を更新: '
        'modelId=${RuriModelManager.embeddingModelId} '
        'modelVersion=${RuriModelManager.embeddingModelVersion} '
        'embeddingDimension=${RuriModelManager.embeddingDimension} '
        'prefixSchemeVersion=${RuriModelManager.prefixSchemeVersion}',
      );
      debugPrint(
        '[Migration v6->v7] novels / novel_text / history / folders は維持',
      );
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
  }

  /// DBインスタンスを再起動（復元後のリフレッシュ用）
  Future<void> restartDatabase() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  // ==========================================
  // MUTES (ミュート設定) CRUD
  // ==========================================

  Future<List<Map<String, dynamic>>> getMutesList() async {
    final db = await database;
    return await db.query('mutes', orderBy: 'id ASC');
  }

  Future<int> addMute({
    required String muteType,
    required String value,
    String? label,
  }) async {
    final db = await database;
    return await db.insert('mutes', {
      'mute_type': muteType,
      'value': value,
      'label': label,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// ミュート設定を追加/更新（HomeSyncHandler などから呼ばれる）
  Future<int> insertOrUpdateMute({
    required String muteType,
    required String value,
    String? label,
  }) async {
    return addMute(muteType: muteType, value: value, label: label);
  }

  Future<int> deleteMute(int muteId) async {
    final db = await database;
    return await db.delete('mutes', where: 'id = ?', whereArgs: [muteId]);
  }

  Future<int> clearMutes() async {
    final db = await database;
    return await db.delete('mutes');
  }

  // ==========================================
  // FOLDERS (お気に入りフォルダ) CRUD
  // ==========================================

  Future<int> createFolder(String name) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return await db.insert('folders', {'name': name, 'created_at': now});
  }

  Future<List<Map<String, dynamic>>> getFoldersList() async {
    final db = await database;
    return await db.query('folders', orderBy: 'created_at DESC');
  }

  Future<int> deleteFolder(int id) async {
    final db = await database;
    await db.delete('folder_items', where: 'folder_id = ?', whereArgs: [id]);
    return await db.delete('folders', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> renameFolder(int id, String newName) async {
    final db = await database;
    return await db.update(
      'folders',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ==========================================
  // FOLDER ITEMS (お気に入りアイテム) CRUD
  // ==========================================

  Future<int> addFolderItem({
    required int folderId,
    required int workId,
    required String title,
    required String authorName,
    required String previewUrl,
    required String type,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return await db.insert('folder_items', {
      'folder_id': folderId,
      'work_id': workId,
      'title': title,
      'author_name': authorName,
      'preview_url': previewUrl,
      'type': type,
      'added_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getFolderItems({
    required int folderId,
    String? type,
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await database;
    if (type != null) {
      return await db.query(
        'folder_items',
        where: 'folder_id = ? AND type = ?',
        whereArgs: [folderId, type],
        orderBy: 'added_at DESC',
        limit: limit,
        offset: offset,
      );
    } else {
      return await db.query(
        'folder_items',
        where: 'folder_id = ?',
        whereArgs: [folderId],
        orderBy: 'added_at DESC',
        limit: limit,
        offset: offset,
      );
    }
  }

  Future<int> removeFolderItem({
    required int folderId,
    required int workId,
    required String type,
  }) async {
    final db = await database;
    return await db.delete(
      'folder_items',
      where: 'folder_id = ? AND work_id = ? AND type = ?',
      whereArgs: [folderId, workId, type],
    );
  }

  Future<bool> isWorkInFolder(int workId, String type) async {
    final db = await database;
    final result = await db.query(
      'folder_items',
      where: 'work_id = ? AND type = ?',
      whereArgs: [workId, type],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  // ==========================================
  // HISTORY (履歴) - 便利メソッド
  // ==========================================

  Future<List<Map<String, dynamic>>> getHistoryList() async {
    final db = await database;
    return await db.query('history', orderBy: 'created_at DESC');
  }

  /// 閲覧履歴を追加/更新
  Future<int> insertOrUpdateHistory({
    required int workId,
    required String title,
    required String authorName,
    required String previewUrl,
    required String type,
    String? url,
    String? metadata,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return await db.insert('history', {
      'work_id': workId,
      'title': title,
      'author_name': authorName,
      'url': url,
      'metadata': metadata,
      'type': type,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// ダウンロード済みイラストを登録
  Future<int> insertDownloadedIllust({
    required int workId,
    required String title,
    required String authorName,
    required String type,
    String? localPath,
    String? thumbnailPath,
  }) async {
    final db = await database;
    return await db.insert('downloaded_illust', {
      'illust_id': workId,
      'local_path': localPath ?? '',
      'thumbnail_path': thumbnailPath,
      'download_date': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    ];
    final Map<String, dynamic> result = {};
    for (final table in tables) {
      result[table] = await db.query(table);
    }
    return result;
  }

  // ==========================================
  // NOVELS (小説本文・ベクトル・購読タグ) - 便利メソッド
  // ==========================================

  /// 小説本文をキャッシュ（UPSERT）
  Future<int> saveNovelText({
    required int workId,
    required String title,
    required String authorName,
    required String text,
    required String pagesJson,
  }) async {
    final db = await database;
    return await db.insert('novel_text', {
      'work_id': workId,
      'title': title,
      'author_name': authorName,
      'pages_json': pagesJson,
      'text': text,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// キャッシュされた小説本文を取得
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

  /// 小説のメタデータを novels テーブルに保存（UPSERT）
  /// フィーリング検索で使用する author_name / cover_url / page_count 等を保持する。
  /// 既存の title / description / text などは上書きしないよう既存行とマージする。
  Future<int> saveNovelMeta({
    required int workId,
    required String title,
    required String description,
    required String authorName,
    required String coverUrl,
    required int pageCount,
    required int totalBookmarks,
    required String createDate,
  }) async {
    final db = await database;
    final existing = await db.query(
      'novels',
      where: 'id = ?',
      whereArgs: [workId],
    );
    final merged = <String, dynamic>{
      'id': workId,
      'title': title,
      'description': description,
      'author_name': authorName,
      'cover_url': coverUrl,
      'page_count': pageCount,
      'total_bookmarks': totalBookmarks,
      'create_date': createDate,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (existing.isNotEmpty) {
      // 既存データを保持（NULL のものだけ新しい値で補完）
      final row = existing.first;
      merged['author_id'] = row['author_id'] ?? 0;
      merged['series_id'] = row['series_id'] ?? 0;
      merged['series_order'] = row['series_order'] ?? 0;
      merged['text'] = row['text'] ?? '';
      merged['text_length'] = row['text_length'] ?? 0;
      merged['tags'] = row['tags'] ?? '';
      merged['tags_json'] = row['tags_json'] ?? '';
      merged['x_restrict'] = row['x_restrict'] ?? 0;
      merged['novel_ai_type'] = row['novel_ai_type'] ?? 0;
      merged['created_at'] = row['created_at'] ?? createDate;
    }
    return await db.insert(
      'novels',
      merged,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
          'work_id IN ($placeholders) AND model_id = ? AND model_version = ?',
      whereArgs: [
        ...workIds,
        RuriModelManager.embeddingModelId,
        RuriModelManager.embeddingModelVersion,
      ],
    );
    final existing = rows.map((r) => r['work_id'] as int).toSet();
    return workIds.where((id) => !existing.contains(id)).toList();
  }

  /// 購読タグを追加
  Future<int> addSubscribedTag(String tag, String type) async {
    final db = await database;
    return await db.insert('subscribed_tags', {
      'tag': tag,
      'type': type,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
      ],
      'novel_text': ['work_id', 'pages_json', 'text', 'updated_at'],
      'novel_embeddings': ['work_id', 'embedding', 'updated_at'],
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
    };

    for (final entry in tableSchemes.entries) {
      final table = entry.key;
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

    return summary;
  }
}
