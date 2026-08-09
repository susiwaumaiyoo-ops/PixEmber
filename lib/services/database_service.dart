import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

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
      version: 3,
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
        updated_at TEXT
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

  /// 小説のベクトルを保存（UPSERT）
  Future<int> saveNovelEmbedding({
    required int workId,
    required Float32List embedding,
  }) async {
    final db = await database;
    return await db.insert('novel_embeddings', {
      'work_id': workId,
      'embedding': jsonEncode(embedding.toList()),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
