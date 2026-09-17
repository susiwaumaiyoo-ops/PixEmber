part of 'database_service.dart';

/// DatabaseService の Schema 層（DDL / マイグレーション / 自己修復）。
///
/// テーブル作成（`_create*`）、カラム補完（`_ensure*Columns`）、
/// ライフサイクル（`_onCreate` / `_onUpgrade` / `_ensureTablesExist`）を担う。
/// 挙動は分割前の単一クラス実装と完全に同一。
abstract class DatabaseServiceSchema extends DatabaseServiceCore {
  /// 10-B1: PC Companion（LAN生成）結果の保存テーブル。
  ///
  /// §5: ローカル llm_summaries とは別テーブル。同一 work_id でも
  /// (work_id, model_id, prompt_version, source_fingerprint) の完全一致で
  /// のみ置換（盲目的な work_id 上書き禁止）。
  Future<void> _createServerSummaries(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS server_summaries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id TEXT,
        job_id INTEGER,
        work_id INTEGER NOT NULL,
        model_id TEXT NOT NULL,
        model_artifact_sha256 TEXT,
        prompt_version INTEGER NOT NULL,
        source_fingerprint TEXT NOT NULL,
        synopsis TEXT NOT NULL,
        spoiler_free_intro TEXT,
        suggested_tags_json TEXT,
        copy_warning INTEGER NOT NULL DEFAULT 0,
        generation_ms INTEGER,
        generated_at TEXT,
        fetched_at TEXT NOT NULL,
        UNIQUE(work_id, model_id, prompt_version, source_fingerprint)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_server_summaries_work ON server_summaries(work_id)',
    );
  }

  /// ダウンロードキューグループテーブルを作成する（_onCreate / v17 migration / onOpen 共用）。
  /// 1 作品（複数ページ含む）= 1 グループ。親ジョブの進捗・ステータスを管理する。
  Future<void> _createDownloadQueueGroups(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS download_queue_groups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL,
        work_type TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        author_name TEXT NOT NULL DEFAULT '',
        page_total INTEGER NOT NULL DEFAULT 1,
        page_completed INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending',
        priority INTEGER NOT NULL DEFAULT 5,
        retry_count INTEGER NOT NULL DEFAULT 0,
        max_retry INTEGER NOT NULL DEFAULT 3,
        error_code TEXT,
        error_message TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT,
        UNIQUE(work_id, work_type)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dqg_status ON download_queue_groups(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dqg_work ON download_queue_groups(work_id, work_type)',
    );
  }

  /// ダウンロードキューテーブルを作成する（_onCreate / v17 migration / onOpen 共用）。
  /// 1 ページ = 1 行。親グループに紐づく。ファイル実体のダウンロード状態を管理する。
  Future<void> _createDownloadQueues(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS download_queues (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id INTEGER NOT NULL,
        work_id INTEGER NOT NULL,
        work_type TEXT NOT NULL,
        page_index INTEGER NOT NULL DEFAULT 0,
        url TEXT NOT NULL DEFAULT '',
        local_path TEXT NOT NULL DEFAULT '',
        file_size INTEGER NOT NULL DEFAULT 0,
        downloaded_bytes INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending',
        retry_count INTEGER NOT NULL DEFAULT 0,
        max_retry INTEGER NOT NULL DEFAULT 3,
        error_code TEXT,
        error_message TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT,
        FOREIGN KEY (group_id) REFERENCES download_queue_groups(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dq_group ON download_queues(group_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dq_status ON download_queues(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_dq_work ON download_queues(work_id, work_type)',
    );
  }

  /// オープン時に全テーブル・全カラムを冪等に保証する。
  ///
  /// 1) CREATE TABLE IF NOT EXISTS で不足テーブルを補完。
  /// 2) 過去のマイグレーションで追加されたカラムを PRAGMA table_info で検証し、
  ///    不足があれば ALTER TABLE ADD COLUMN で追加。
  ///
  /// これにより「マイグレーションを飛ばしてしまった破損DB」
  /// （例: v13 だが prefix_scheme_version が欠落したままの DB）も
  /// onOpen 時に自動修復される。既存データは一切削除しない。
  @override
  Future<void> _ensureTablesExist(Database db) async {
    await _createSubscribedTags(db);
    await _createSubscriptionNewItems(db);
    await _createReadLater(db);
    await _ensureNovelsColumns(db);
    await _ensureNovelTextColumns(db);
    await _ensureNovelEmbeddingsColumns(db);
    await _ensureIllustEmbeddingsColumns(db);
    await _ensureIllustsColumns(db);
    await _ensureReadLaterColumns(db);
    await _ensureHistoryColumns(db);
    await _ensureSubscribedTagsColumns(db);
    await _ensureMutesColumns(db);
    // 検索履歴テーブルが存在しない場合は先に作成してからカラム確認を行う
    await _createSearchHistory(db);
    await _ensureSearchHistoryColumns(db);
    // ダウンロードキュー（v17 追加）
    await _createDownloadQueueGroups(db);
    await _createDownloadQueues(db);
    // TTS読み上げ位置（v18 追加）
    await _createTtsReadingPositions(db);
    // 利用時間トラッキング（v19 追加）
    await _createUsageSessions(db);
    // 視覚類似検索エンベディング（v20 追加）
    await _createImageEmbeddings(db);
    // 画像指紋（重複検出・v21 追加）
    await _createImageFingerprints(db);
    // 小説の感情曲線キャッシュ（v23 追加）
    await _createEmotionCurves(db);
    // 読書メモ（v24 追加）
    await _createReadingNotes(db);
    // LLM要約キャッシュ（v25 追加）
    await _createLlmSummaries(db);
    // 自動要約の実行状態・作品キュー（v26 追加）
    await _createAutoSummary(db);
    // PCサーバー生成結果（10-B1 追加・llm_summaries とは分離）
    await _createServerSummaries(db);
  }

  /// 指定テーブルに指定カラムが無ければ ALTER TABLE ADD COLUMN する（冪等）。
  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String alterSql,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final existing = cols.map((c) => c['name'] as String).toSet();
    if (!existing.contains(column)) {
      await db.execute(alterSql);
    }
  }

  /// novels の必須カラムを検証・補完（v5/v8 で追加された列）。
  Future<void> _ensureNovelsColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'novels',
      'author_name',
      "ALTER TABLE novels ADD COLUMN author_name TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      db,
      'novels',
      'cover_url',
      "ALTER TABLE novels ADD COLUMN cover_url TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      db,
      'novels',
      'page_count',
      'ALTER TABLE novels ADD COLUMN page_count INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'novels',
      'total_bookmarks',
      'ALTER TABLE novels ADD COLUMN total_bookmarks INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'novels',
      'create_date',
      "ALTER TABLE novels ADD COLUMN create_date TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      db,
      'novels',
      'total_view',
      'ALTER TABLE novels ADD COLUMN total_view INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'novels',
      'meta_json',
      'ALTER TABLE novels ADD COLUMN meta_json TEXT',
    );
  }

  /// novel_text の必須カラムを検証・補完（v3 で追加された列）。
  Future<void> _ensureNovelTextColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'novel_text',
      'title',
      'ALTER TABLE novel_text ADD COLUMN title TEXT',
    );
    await _addColumnIfMissing(
      db,
      'novel_text',
      'author_name',
      'ALTER TABLE novel_text ADD COLUMN author_name TEXT',
    );
  }

  /// novel_embeddings の必須カラムを検証・補完（v7/v13 で追加された列）。
  /// 共有ヘルパーとして、ALTER 判定をここに一元化する。
  /// 既存行は prefix 方式互換を前提に現行バージョンで一括バックフィル。
  Future<void> _ensureNovelEmbeddingsColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'novel_embeddings',
      'model_id',
      "ALTER TABLE novel_embeddings ADD COLUMN model_id TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      db,
      'novel_embeddings',
      'model_version',
      'ALTER TABLE novel_embeddings ADD COLUMN model_version INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'novel_embeddings',
      'prefix_scheme_version',
      'ALTER TABLE novel_embeddings ADD COLUMN prefix_scheme_version INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'novel_embeddings',
      'embedding_dim',
      'ALTER TABLE novel_embeddings ADD COLUMN embedding_dim INTEGER NOT NULL DEFAULT 0',
    );
    // 既存行を現行プレフィックスバージョンに一括更新（互換性維持）
    await db.update(
      'novel_embeddings',
      {'prefix_scheme_version': RuriModelManager.prefixSchemeVersion},
      where: 'prefix_scheme_version != ?',
      whereArgs: [RuriModelManager.prefixSchemeVersion],
    );
  }

  /// illust_embeddings の必須カラムを検証・補完。
  /// novel_embeddings と同一設計方針（モデル互換カラム・冪等ALTER）。
  Future<void> _ensureIllustEmbeddingsColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'illust_embeddings',
      'model_id',
      "ALTER TABLE illust_embeddings ADD COLUMN model_id TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      db,
      'illust_embeddings',
      'model_version',
      'ALTER TABLE illust_embeddings ADD COLUMN model_version INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'illust_embeddings',
      'prefix_scheme_version',
      'ALTER TABLE illust_embeddings ADD COLUMN prefix_scheme_version INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'illust_embeddings',
      'embedding_dim',
      'ALTER TABLE illust_embeddings ADD COLUMN embedding_dim INTEGER NOT NULL DEFAULT 0',
    );
    // 既存行を現行プレフィックスバージョンに一括更新（互換性維持）
    await db.update(
      'illust_embeddings',
      {'prefix_scheme_version': RuriModelManager.prefixSchemeVersion},
      where: 'prefix_scheme_version != ?',
      whereArgs: [RuriModelManager.prefixSchemeVersion],
    );
  }

  /// illusts の必須カラムを検証・補完（v16 新規テーブル）。
  /// novels と同名カラムを保持し、ハイブリッド検索を共有化する。
  Future<void> _ensureIllustsColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'illusts',
      'author_name',
      "ALTER TABLE illusts ADD COLUMN author_name TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      db,
      'illusts',
      'cover_url',
      "ALTER TABLE illusts ADD COLUMN cover_url TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      db,
      'illusts',
      'page_count',
      'ALTER TABLE illusts ADD COLUMN page_count INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'illusts',
      'total_bookmarks',
      'ALTER TABLE illusts ADD COLUMN total_bookmarks INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'illusts',
      'create_date',
      "ALTER TABLE illusts ADD COLUMN create_date TEXT NOT NULL DEFAULT ''",
    );
    await _addColumnIfMissing(
      db,
      'illusts',
      'total_view',
      'ALTER TABLE illusts ADD COLUMN total_view INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'illusts',
      'meta_json',
      'ALTER TABLE illusts ADD COLUMN meta_json TEXT',
    );
  }

  /// read_later の必須カラムを検証・補完（v12 で追加された列）。
  Future<void> _ensureReadLaterColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'read_later',
      'progress',
      'ALTER TABLE read_later ADD COLUMN progress REAL DEFAULT 0.0',
    );
    await _addColumnIfMissing(
      db,
      'read_later',
      'last_page',
      'ALTER TABLE read_later ADD COLUMN last_page INTEGER DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'read_later',
      'last_offset',
      'ALTER TABLE read_later ADD COLUMN last_offset INTEGER DEFAULT 0',
    );
  }

  /// history の必須カラムを検証・補完（v4 で追加された列）。
  Future<void> _ensureHistoryColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'history',
      'author_name',
      "ALTER TABLE history ADD COLUMN author_name TEXT NOT NULL DEFAULT ''",
    );
  }

  /// subscribed_tags の必須カラムを検証・補完（v9 で追加された列）。
  Future<void> _ensureSubscribedTagsColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'subscribed_tags',
      'last_checked_at',
      'ALTER TABLE subscribed_tags ADD COLUMN last_checked_at TEXT',
    );
    await _addColumnIfMissing(
      db,
      'subscribed_tags',
      'last_newest_date',
      'ALTER TABLE subscribed_tags ADD COLUMN last_newest_date TEXT',
    );
    await _addColumnIfMissing(
      db,
      'subscribed_tags',
      'last_new_count',
      'ALTER TABLE subscribed_tags ADD COLUMN last_new_count INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// mutes の必須カラムを検証・補完（v2 で追加された列）。
  Future<void> _ensureMutesColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'mutes',
      'label',
      'ALTER TABLE mutes ADD COLUMN label TEXT',
    );
  }

  /// search_history の必須カラムを検証・補完（v14 で追加された列）。
  Future<void> _ensureSearchHistoryColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'search_history',
      'last_searched_at',
      "ALTER TABLE search_history ADD COLUMN last_searched_at TEXT",
    );
    await _addColumnIfMissing(
      db,
      'search_history',
      'use_count',
      'ALTER TABLE search_history ADD COLUMN use_count INTEGER NOT NULL DEFAULT 1',
    );
  }

  /// 購読タグテーブルを作成する（_onCreate / v3 migration / onOpen 共用）。
  /// 最新スキーマ（v9 以降: last_checked_at / last_newest_date / last_new_count 含む）。
  Future<void> _createSubscribedTags(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS subscribed_tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tag TEXT NOT NULL,
        type TEXT NOT NULL,
        created_at TEXT NOT NULL,
        last_checked_at TEXT,
        last_newest_date TEXT,
        last_new_count INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  /// 購読タグの新着作品キャッシュテーブルを作成する（_onCreate / v10 共用）。
  Future<void> _createSubscriptionNewItems(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS subscription_new_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        subscribed_tag_id INTEGER NOT NULL,
        work_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        title TEXT,
        author_name TEXT,
        preview_url TEXT,
        create_date TEXT,
        x_restrict INTEGER DEFAULT 0,
        found_at TEXT,
        is_read INTEGER DEFAULT 0,
        UNIQUE(subscribed_tag_id, work_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sni_tagid '
      'ON subscription_new_items(subscribed_tag_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sni_isread '
      'ON subscription_new_items(is_read)',
    );
  }

  /// 検索履歴テーブルを作成する（_onCreate / v14 migration / onOpen 共用）。
  Future<void> _createSearchHistory(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS search_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        keyword TEXT NOT NULL UNIQUE,
        last_searched_at TEXT,
        use_count INTEGER DEFAULT 1
      )
    ''');
  }

  /// あとで読む（小説）テーブルを作成する（_onCreate / v11 migration / onOpen 共用）。
  Future<void> _createReadLater(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS read_later (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL UNIQUE,
        title TEXT,
        author_name TEXT,
        author_id INTEGER,
        cover_url TEXT,
        text_length INTEGER,
        tags_json TEXT,
        x_restrict INTEGER DEFAULT 0,
        status INTEGER DEFAULT 0,
        added_at TEXT,
        last_opened_at TEXT,
        finished_at TEXT,
        progress REAL DEFAULT 0.0,
        last_page INTEGER DEFAULT 0,
        last_offset INTEGER DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_read_later_status ON read_later(status)',
    );
  }

  /// TTS読み上げ再開位置テーブルを作成する（_onCreate / v18 migration / onOpen 共用）。
  /// 端末ローカルの位置情報（再生成可能）のため Google Drive バックアップ対象外。
  Future<void> _createTtsReadingPositions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tts_reading_positions (
        work_id INTEGER PRIMARY KEY,
        chunk_index INTEGER NOT NULL DEFAULT 0,
        page_index INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  /// 利用時間トラッキングテーブルを作成する（_onCreate / v19 migration / onOpen 共用）。
  /// 端末ローカルのプライバシーデータのため Google Drive バックアップ対象外。
  Future<void> _createUsageSessions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS usage_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_type TEXT NOT NULL,
        work_id INTEGER NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_usage_sessions_started_at '
      'ON usage_sessions(started_at)',
    );
  }

  /// 視覚類似検索用エンベディングテーブルを作成する（_onCreate / v20 migration / onOpen 共用）。
  /// 元画像から再生成可能なため Google Drive バックアップ対象外。
  Future<void> _createImageEmbeddings(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS image_embeddings (
        illust_id INTEGER PRIMARY KEY,
        embedding BLOB NOT NULL,
        dim INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  /// 画像指紋テーブルを作成する（_onCreate / v21 migration / onOpen 共用）。
  /// 元画像から再生成可能なため Google Drive バックアップ対象外。
  Future<void> _createImageFingerprints(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS image_fingerprints (
        illust_id INTEGER PRIMARY KEY,
        sha256 TEXT NOT NULL,
        dhash INTEGER NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_image_fingerprints_sha256 '
      'ON image_fingerprints(sha256)',
    );
  }

  /// 小説の感情曲線テーブルを作成する（_onCreate / v23 migration / onOpen 共用）。
  /// 本文から再生成可能なため Google Drive バックアップ対象外。
  Future<void> _createEmotionCurves(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS emotion_curves (
        work_id INTEGER PRIMARY KEY,
        model_id TEXT NOT NULL,
        chunks_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  /// 読書メモテーブルを作成する（_onCreate / v24 migration / onOpen 共用）。
  /// ユーザー生成データのため Google Drive バックアップ対象。
  Future<void> _createReadingNotes(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS reading_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL,
        work_type TEXT NOT NULL DEFAULT 'novel',
        page_index INTEGER NOT NULL DEFAULT 0,
        anchor_text TEXT,
        note_text TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reading_notes_work '
      'ON reading_notes(work_id)',
    );
  }

  /// LLM要約キャッシュテーブルを作成する（_onCreate / v25 migration / onOpen 共用）。
  /// 本文とモデルから再生成可能なため Google Drive バックアップ対象外。
  /// 同一作品×モデル×プロンプト版×入力フィンガープリントで1行（UNIQUE）。
  Future<void> _createLlmSummaries(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS llm_summaries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL,
        model_id TEXT NOT NULL,
        model_file_hash TEXT NOT NULL,
        prompt_version INTEGER NOT NULL,
        source_fingerprint TEXT NOT NULL,
        synopsis TEXT NOT NULL,
        spoiler_free_intro TEXT NOT NULL,
        suggested_tags_json TEXT NOT NULL,
        copy_warning INTEGER NOT NULL DEFAULT 0,
        generation_ms INTEGER,
        generated_at TEXT NOT NULL,
        UNIQUE(work_id, model_id, prompt_version, source_fingerprint)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_llm_summaries_work '
      'ON llm_summaries(work_id)',
    );
  }

  /// 自動要約の実行状態（auto_summary_runs）と作品キュー
  /// （auto_summary_items）を作成する（_onCreate / v26 migration / onOpen 共用）。
  ///
  /// - 本文・思考・生成途中トークンは保存しない（進捗DBへ本文を複製しない）。
  /// - OS 停止後は stale な running を照合して中断扱いにする（復元用）。
  Future<void> _createAutoSummary(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS auto_summary_runs (
        run_id TEXT PRIMARY KEY,
        phase TEXT NOT NULL,
        wait_reason TEXT NOT NULL DEFAULT 'none',
        started_at_millis INTEGER NOT NULL DEFAULT 0,
        updated_at_millis INTEGER NOT NULL DEFAULT 0,
        current_tag TEXT,
        current_work_id INTEGER,
        current_work_title TEXT,
        model_label TEXT,
        backend_name TEXT,
        candidates_fetched INTEGER NOT NULL DEFAULT 0,
        has_more_candidates INTEGER NOT NULL DEFAULT 0,
        stop_reason TEXT,
        is_final INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS auto_summary_items (
        run_id TEXT NOT NULL,
        work_id INTEGER NOT NULL,
        tags_json TEXT NOT NULL DEFAULT '[]',
        title TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'waiting',
        error_reason TEXT,
        updated_at_millis INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (run_id, work_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_asr_final '
      'ON auto_summary_runs(is_final, updated_at_millis)',
    );
  }

  @override
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
        create_date TEXT NOT NULL DEFAULT '',
        total_view INTEGER NOT NULL DEFAULT 0,
        meta_json TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE novel_text (
        work_id INTEGER PRIMARY KEY,
        pages_json TEXT,
        text TEXT,
        illustrations_json TEXT,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE novel_embeddings (
        work_id INTEGER PRIMARY KEY,
        embedding TEXT,
        model_id TEXT NOT NULL DEFAULT '',
        model_version INTEGER NOT NULL DEFAULT 0,
        prefix_scheme_version INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE illust_embeddings (
        work_id INTEGER PRIMARY KEY,
        embedding TEXT,
        model_id TEXT NOT NULL DEFAULT '',
        model_version INTEGER NOT NULL DEFAULT 0,
        prefix_scheme_version INTEGER NOT NULL DEFAULT 0,
        embedding_dim INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE illusts (
        id INTEGER PRIMARY KEY,
        title TEXT,
        description TEXT,
        author_id INTEGER,
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
        create_date TEXT NOT NULL DEFAULT '',
        total_view INTEGER NOT NULL DEFAULT 0,
        meta_json TEXT
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

    // 購読タグ（新規インストール時はここで最新スキーマを一括作成）
    await _createSubscribedTags(db);

    // 購読タグの新着作品キャッシュ
    await _createSubscriptionNewItems(db);

    // あとで読む（小説）
    await _createReadLater(db);

    // 検索履歴（v14 新規テーブル）
    await _createSearchHistory(db);

    // 検索用インデックス
    await db.execute('''
      CREATE TABLE IF NOT EXISTS illusts (
        id INTEGER PRIMARY KEY,
        title TEXT,
        description TEXT,
        author_id INTEGER,
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
        create_date TEXT NOT NULL DEFAULT '',
        total_view INTEGER NOT NULL DEFAULT 0,
        meta_json TEXT
      )
    ''');
    // ダウンロードキュー（v17 追加）
    await _createDownloadQueueGroups(db);
    await _createDownloadQueues(db);

    // TTS読み上げ位置（v18 追加）
    await _createTtsReadingPositions(db);

    // 利用時間トラッキング（v19 追加）
    await _createUsageSessions(db);

    // 視覚類似検索エンベディング（v20 追加）
    await _createImageEmbeddings(db);

    // 画像指紋（v21 追加）
    await _createImageFingerprints(db);

    // 小説の感情曲線キャッシュ（v23 追加）
    await _createEmotionCurves(db);

    // 読書メモ（v24 追加）
    await _createReadingNotes(db);

    // LLM要約キャッシュ（v25 追加）
    await _createLlmSummaries(db);

    // 自動要約の実行状態・作品キュー（v26 追加）
    await _createAutoSummary(db);

    await db.execute('CREATE INDEX idx_history_workid ON history(work_id)');
    await db.execute(
      'CREATE INDEX idx_folder_items_folderid ON folder_items(folder_id)',
    );
  }

  @override
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
    if (oldVersion < 8) {
      // novels に total_view / meta_json（完全な Novel スナップショット）を追加。
      // 既存データは削除せず、列追加のみの非破壊マイグレーション。
      final columns = await db.rawQuery('PRAGMA table_info(novels)');
      final existing = columns.map((c) => c['name'] as String).toSet();
      if (!existing.contains('total_view')) {
        await db.execute(
          'ALTER TABLE novels ADD COLUMN total_view INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!existing.contains('meta_json')) {
        await db.execute('ALTER TABLE novels ADD COLUMN meta_json TEXT');
      }
      debugPrint('[Migration v7->v8] novels に total_view / meta_json を追加');
    }
    if (oldVersion < 9) {
      // 購読タグの新着チェック用カラムを追加（非破壊マイグレーション）。
      // 既存データは維持し、新カラムは NULL/0 で初期化される。
      final columns = await db.rawQuery('PRAGMA table_info(subscribed_tags)');
      final existing = columns.map((c) => c['name'] as String).toSet();
      if (!existing.contains('last_checked_at')) {
        await db.execute(
          'ALTER TABLE subscribed_tags ADD COLUMN last_checked_at TEXT',
        );
      }
      if (!existing.contains('last_newest_date')) {
        await db.execute(
          'ALTER TABLE subscribed_tags ADD COLUMN last_newest_date TEXT',
        );
      }
      if (!existing.contains('last_new_count')) {
        await db.execute(
          'ALTER TABLE subscribed_tags ADD COLUMN last_new_count INTEGER NOT NULL DEFAULT 0',
        );
      }
      debugPrint('[Migration v8->v9] subscribed_tags に新着チェック用カラムを追加');
    }
    if (oldVersion < 10) {
      // 購読タグの新着作品キャッシュテーブルを追加（既存データ非破壊）。
      await _createSubscriptionNewItems(db);
      debugPrint('[Migration v9->v10] subscription_new_items を追加');
    }
    if (oldVersion < 11) {
      // あとで読む（小説）テーブルを追加（既存データ非破壊）。
      await _createReadLater(db);
      debugPrint('[Migration v10->v11] read_later を追加');
    }
    if (oldVersion < 12) {
      // 読書進捗・再開位置の保存用カラムを追加（既存データ非破壊）。
      // _createReadLater は IF NOT EXISTS のため既存テーブルには効かず、
      // 既存列の有無を確認して ALTER TABLE で後付けする。
      final cols = await db.rawQuery('PRAGMA table_info(read_later)');
      final existing = cols.map((c) => c['name'] as String).toSet();
      if (!existing.contains('progress')) {
        await db.execute(
          'ALTER TABLE read_later ADD COLUMN progress REAL DEFAULT 0.0',
        );
      }
      if (!existing.contains('last_page')) {
        await db.execute(
          'ALTER TABLE read_later ADD COLUMN last_page INTEGER DEFAULT 0',
        );
      }
      if (!existing.contains('last_offset')) {
        await db.execute(
          'ALTER TABLE read_later ADD COLUMN last_offset INTEGER DEFAULT 0',
        );
      }
      debugPrint(
        '[Migration v11->v12] read_later に progress/last_page/last_offset を追加',
      );
    }
    if (oldVersion < 13) {
      // prefixSchemeVersion が変わった場合、古い埋め込みを検索時にスキップするため。
      final cols = await db.rawQuery('PRAGMA table_info(novel_embeddings)');
      final existing = cols.map((c) => c['name'] as String).toSet();
      if (!existing.contains('prefix_scheme_version')) {
        await db.execute(
          'ALTER TABLE novel_embeddings ADD COLUMN prefix_scheme_version INTEGER NOT NULL DEFAULT 0',
        );
      }
      // prefix 方式（検索クエリ/検索文書プレフィックス）は過去から一貫しているため、
      // 既存の埋め込みも現行 scheme と互換。強制再インデックスを避けるため、
      // 既存行を現行バージョンに一括更新する。
      await db.update(
        'novel_embeddings',
        {'prefix_scheme_version': RuriModelManager.prefixSchemeVersion},
        where: 'prefix_scheme_version != ?',
        whereArgs: [RuriModelManager.prefixSchemeVersion],
      );
      debugPrint(
        '[Migration v12->v13] novel_embeddings に prefix_scheme_version を追加',
      );
    }
    if (oldVersion < 14) {
      // 検索履歴テーブルを追加（既存データ非破壊）。
      // 先に CREATE TABLE IF NOT EXISTS でテーブル本体を確保してから、
      // 既存列の有無を確認して ALTER TABLE で後付けする（順序逆転バグ防止）。
      await _createSearchHistory(db);
      final cols = await db.rawQuery('PRAGMA table_info(search_history)');
      final existing = cols.map((c) => c['name'] as String).toSet();
      if (!existing.contains('last_searched_at')) {
        await db.execute(
          'ALTER TABLE search_history ADD COLUMN last_searched_at TEXT',
        );
      }
      if (!existing.contains('use_count')) {
        await db.execute(
          'ALTER TABLE search_history ADD COLUMN use_count INTEGER NOT NULL DEFAULT 1',
        );
      }
      debugPrint('[Migration v13->v14] search_history を追加');
    }
    if (oldVersion < 15) {
      // イラスト意味検索用の illust_embeddings テーブルを追加（既存データ非破壊）。
      // novel_embeddings と完全同スキーマ。
      await db.execute('''
        CREATE TABLE IF NOT EXISTS illust_embeddings (
          work_id INTEGER PRIMARY KEY,
          embedding TEXT,
          model_id TEXT NOT NULL DEFAULT '',
          model_version INTEGER NOT NULL DEFAULT 0,
          prefix_scheme_version INTEGER NOT NULL DEFAULT 0,
          embedding_dim INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL
        )
      ''');
      debugPrint('[Migration v14->v15] illust_embeddings を追加');
    }
    if (oldVersion < 16) {
      // イラスト意味検索用の illusts メタデータテーブルを追加（既存データ非破壊）。
      // novels と同名列でハイブリッド検索を共有化する。
      await db.execute('''
        CREATE TABLE IF NOT EXISTS illusts (
          id INTEGER PRIMARY KEY,
          title TEXT,
          description TEXT,
          author_id INTEGER,
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
          create_date TEXT NOT NULL DEFAULT '',
          total_view INTEGER NOT NULL DEFAULT 0,
          meta_json TEXT
        )
      ''');
      debugPrint('[Migration v15->v16] illusts を追加');
    }
    if (oldVersion < 17) {
      // ダウンロードキューテーブルを追加（既存データ非破壊）。
      // download_queue_groups: 親ジョブ（1作品=1グループ）
      // download_queues: 子ジョブ（1ページ=1行）、FK group_id ON DELETE CASCADE
      await _createDownloadQueueGroups(db);
      await _createDownloadQueues(db);
      debugPrint(
        '[Migration v16->v17] download_queue_groups / download_queues を追加',
      );
    }
    if (oldVersion < 18) {
      // TTS読み上げ再開位置テーブルを追加（既存データ非破壊）。
      // 端末ローカル設定のため Google Drive バックアップ対象外。
      await _createTtsReadingPositions(db);
      debugPrint('[Migration v17->v18] tts_reading_positions を追加');
    }
    if (oldVersion < 19) {
      // 利用時間トラッキングテーブルを追加（既存データ非破壊）。
      // 端末ローカルのプライバシーデータのため Google Drive バックアップ対象外。
      await _createUsageSessions(db);
      debugPrint('[Migration v18->v19] usage_sessions を追加');
    }
    if (oldVersion < 20) {
      // 視覚類似検索用エンベディングテーブルを追加（既存データ非破壊）。
      // 元画像から再生成可能なため Google Drive バックアップ対象外。
      await _createImageEmbeddings(db);
      debugPrint('[Migration v19->v20] image_embeddings を追加');
    }
    if (oldVersion < 21) {
      // 画像指紋テーブルを追加（既存データ非破壊）。
      // 元画像から再生成可能なため Google Drive バックアップ対象外。
      await _createImageFingerprints(db);
      debugPrint('[Migration v20->v21] image_fingerprints を追加');
    }
    if (oldVersion < 22) {
      // 小説リッチレンダリング（Phase 1）: 挿絵 URL キャッシュ列を追加
      // （既存データ非破壊。NULL=旧データ。設計書 §9.2）。
      await _addColumnIfMissing(
        db,
        'novel_text',
        'illustrations_json',
        'ALTER TABLE novel_text ADD COLUMN illustrations_json TEXT',
      );
      debugPrint('[Migration v21->v22] novel_text.illustrations_json を追加');
    }
    if (oldVersion < 23) {
      // 小説の感情曲線キャッシュテーブルを追加（既存データ非破壊）。
      // 本文から再生成可能なため Google Drive バックアップ対象外。
      await _createEmotionCurves(db);
      debugPrint('[Migration v22->v23] emotion_curves を追加');
    }
    if (oldVersion < 24) {
      // 読書メモテーブルを追加（Phase N6・非破壊的増設）。
      // ユーザー生成データのため Google Drive バックアップ対象。
      await _createReadingNotes(db);
      debugPrint('[Migration v23->v24] reading_notes を追加');
    }
    if (oldVersion < 25) {
      // LLM要約キャッシュ（本文・モデルから再生成可能なため
      // Google Drive バックアップ対象外）。
      await _createLlmSummaries(db);
      debugPrint('[Migration v24->v25] llm_summaries を追加');
    }
    if (oldVersion < 26) {
      // 自動要約の実行状態・作品キュー（Phase 9-B・非破壊的増設）。
      await _createAutoSummary(db);
      debugPrint('[Migration v25->v26] auto_summary_runs/items を追加');
    }
  }
}
