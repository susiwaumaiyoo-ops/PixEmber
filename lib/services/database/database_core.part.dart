part of 'database_service.dart';

/// DatabaseService の Core 層（DB 接続・テスト注入・オープン）。
///
/// このクラスは [DatabaseService] の part であり、
/// `database` getter / `setTestDatabase` / `clearTestDatabase` /
/// `_initDatabase` を提供する。`_onCreate` / `_onUpgrade` / `_ensureTablesExist`
/// は本体側（database_service.dart）で実装されるフック。
/// 挙動は分割前の単一クラス実装と完全に同一。
abstract class DatabaseServiceCore {
  Database? _database;

  /// データベースインスタンスを取得
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// テスト用: 外部からDBインスタンスを注入する（sqflite_ffi のインメモリDB等）。
  /// 注入後は `database` getter がこのインスタンスを返す。
  void setTestDatabase(Database db) {
    _database = db;
  }

  /// テスト用: 注入した DB インスタンスを解除する。
  /// 解除後の `database` getter は通常の初期化フローに戻る。
  @visibleForTesting
  void clearTestDatabase() {
    _database = null;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'pixiv_viewer.db');
    return await openDatabase(
      path,
      version: 26,
      onConfigure: (db) async {
        // 外部キー制約（ON DELETE CASCADE 等）を有効化。
        // SQLite はデフォルトで無効のため接続毎に設定が必要。
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: _ensureTablesExist,
    );
  }

  // --- 本体側（DatabaseService）で実装されるフック ---

  Future<void> _onCreate(Database db, int version);

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion);

  Future<void> _ensureTablesExist(Database db);
}
