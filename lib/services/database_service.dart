import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static Database? _database;
  // 並行初期化による sqflite の二重オープン（デッドロックの根源）を排除するためのガード
  static Completer<Database>? _initCompleter;

  factory DatabaseService() {
    return _instance;
  }

  DatabaseService._internal();

  Future<Database> get database async {
    // 並行初期化競合を排除：既に初期化中なら同じ Future を共有して openDatabase の二重実行を防ぐ
    if (_database != null) return _database!;
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<Database>();
    try {
      _database = await _initDatabase();
      _initCompleter!.complete(_database!);
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null; // 失敗時は次回の呼び出しで再試行できるようにリセット
      rethrow;
    }
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, 'pixiv_history_local.db');

    return await openDatabase(path, version: 1, onCreate: _onCreate);
  }

  Future<void> _onCreate(Database db, int version) async {
    // 1. 履歴テーブルの作成
    await db.execute('''
      CREATE TABLE history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        author_name TEXT NOT NULL,
        preview_url TEXT NOT NULL,
        type TEXT NOT NULL, -- 'illust' or 'novel'
        viewed_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_history_work_type ON history (work_id, type)
    ''');

    // 2. ミュート（ブラックリスト）テーブルの作成
    // mute_type: 'tag' (タグ), 'user' (ユーザーID), 'ai' (AI判定: '0'=AI以外, '1'=AI作品, '2'=すべて)
    await db.execute('''
      CREATE TABLE mutes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mute_type TEXT NOT NULL,
        value TEXT NOT NULL, -- タグ文字列、ユーザーID文字列、またはAIフラグ
        label TEXT, -- 表示名（ユーザー名やタグ名など）
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_mutes_type_value ON mutes (mute_type, value)
    ''');

    // 3. お気に入りフォルダテーブルの作成
    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL
      )
    ''');

    // 4. フォルダ内お気に入りアイテムテーブルの作成
    await db.execute('''
      CREATE TABLE folder_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        folder_id INTEGER NOT NULL,
        work_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        author_name TEXT NOT NULL,
        preview_url TEXT NOT NULL,
        type TEXT NOT NULL, -- 'illust' or 'novel'
        added_at INTEGER NOT NULL,
        FOREIGN KEY (folder_id) REFERENCES folders(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_folder_items_unique ON folder_items (folder_id, work_id, type)
    ''');

    // 5. 購読タグ管理テーブルの作成
    await db.execute('''
      CREATE TABLE subscribed_tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tag_name TEXT NOT NULL,
        type TEXT NOT NULL, -- 'illust' or 'novel'
        last_synced_at INTEGER, -- 最終同期エポック秒
        latest_work_id INTEGER, -- 最後に検知した最新作品のID（新着検知用）
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_subscribed_tags_unique ON subscribed_tags (tag_name, type)
    ''');
  }

  // ==========================================
  // 1. HISTORY (閲覧履歴) CRUD
  // ==========================================

  Future<int> insertOrUpdateHistory({
    required int workId,
    required String title,
    required String authorName,
    required String previewUrl,
    required String type,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // トランザクションを使わず、シンプルな単一 INSERT + conflictAlgorithm で UPSERT。
    // これにより sqflite のデッドロックを 100% 回避する。
    return await db.insert(
      'history',
      {
        'work_id': workId,
        'title': title,
        'author_name': authorName,
        'preview_url': previewUrl,
        'type': type,
        'viewed_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getHistoryList({
    String? type, // 'illust' or 'novel'
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await database;
    if (type != null) {
      return await db.query(
        'history',
        where: 'type = ?',
        whereArgs: [type],
        orderBy: 'viewed_at DESC',
        limit: limit,
        offset: offset,
      );
    } else {
      return await db.query(
        'history',
        orderBy: 'viewed_at DESC',
        limit: limit,
        offset: offset,
      );
    }
  }

  Future<int> clearHistory() async {
    final db = await database;
    return await db.delete('history');
  }

  Future<int> deleteHistoryItem(int workId, String type) async {
    final db = await database;
    return await db.delete(
      'history',
      where: 'work_id = ? AND type = ?',
      whereArgs: [workId, type],
    );
  }

  // ==========================================
  // 2. MUTES (ミュート / ブラックリスト) CRUD
  // ==========================================

  Future<int> insertOrUpdateMute({
    required String muteType, // 'tag', 'user', 'ai'
    required String value,
    String? label,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // トランザクション不使用の単一 INSERT + conflictAlgorithm で UPSERT。
    return await db.insert(
      'mutes',
      {
        'mute_type': muteType,
        'value': value,
        'label': label,
        'created_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getMutesList() async {
    final db = await database;
    return await db.query('mutes', orderBy: 'created_at DESC');
  }

  Future<int> deleteMute(int id) async {
    final db = await database;
    return await db.delete('mutes', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteMuteByValue(String muteType, String value) async {
    final db = await database;
    return await db.delete(
      'mutes',
      where: 'mute_type = ? AND value = ?',
      whereArgs: [muteType, value],
    );
  }

  // ==========================================
  // 3. FOLDERS (お気に入りフォルダ) CRUD
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
    // Cascade delete manually since foreign keys support in sqflite needs "PRAGMA foreign_keys = ON"
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
  // 4. FOLDER ITEMS (お気に入りアイテム) CRUD
  // ==========================================

  Future<int> addFolderItem({
    required int folderId,
    required int workId,
    required String title,
    required String authorName,
    required String previewUrl,
    required String type, // 'illust' or 'novel'
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // トランザクション不使用の単一 INSERT + conflictAlgorithm で UPSERT。
    return await db.insert(
      'folder_items',
      {
        'folder_id': folderId,
        'work_id': workId,
        'title': title,
        'author_name': authorName,
        'preview_url': previewUrl,
        'type': type,
        'added_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    final res = await db.query(
      'folder_items',
      columns: ['id'],
      where: 'work_id = ? AND type = ?',
      whereArgs: [workId, type],
      limit: 1,
    );
    return res.isNotEmpty;
  }

  // ==========================================
  // 5. SUBSCRIBED TAGS (購読タグ) CRUD
  // ==========================================

  Future<int> addSubscribedTag(String tagName, String type) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // トランザクション不使用の単一 INSERT。重複時は何もしない（ignore）。
    return await db.insert(
      'subscribed_tags',
      {
        'tag_name': tagName,
        'type': type,
        'created_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, dynamic>>> getSubscribedTagsList({
    String? type,
  }) async {
    final db = await database;
    if (type != null) {
      return await db.query(
        'subscribed_tags',
        where: 'type = ?',
        whereArgs: [type],
        orderBy: 'created_at DESC',
      );
    } else {
      return await db.query('subscribed_tags', orderBy: 'created_at DESC');
    }
  }

  Future<int> deleteSubscribedTag(int id) async {
    final db = await database;
    return await db.delete('subscribed_tags', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteSubscribedTagByName(String tagName, String type) async {
    final db = await database;
    return await db.delete(
      'subscribed_tags',
      where: 'tag_name = ? AND type = ?',
      whereArgs: [tagName, type],
    );
  }

  Future<int> updateSubscriptionSyncState(
    int id, {
    required int lastSyncedAt,
    required int latestWorkId,
  }) async {
    final db = await database;
    return await db.update(
      'subscribed_tags',
      {'last_synced_at': lastSyncedAt, 'latest_work_id': latestWorkId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// DBインスタンスを再起動（復元後のリフレッシュ用）
  Future<void> restartDatabase() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
