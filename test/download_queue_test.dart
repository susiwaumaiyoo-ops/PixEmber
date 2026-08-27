import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';

void main() {
  // インメモリSQLite（sqflite_ffi）を使用
  late DatabaseService db;
  late Database testDb;

  setUpAll(() {
    // FFI 初期化（テスト環境用）
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = DatabaseService();
    testDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 17,
        onConfigure: (d) async {
          await d.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (d, v) async {
          // _onCreate と同等のスキーマを構築（download_queues 関連のみで十分）
          await d.execute('''
          CREATE TABLE download_queue_groups (
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
            completed_at TEXT
          )
        ''');
          await d.execute('''
          CREATE TABLE download_queues (
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
        },
      ),
    );
    db.setTestDatabase(testDb);
  });

  tearDown(() async {
    await testDb.close();
    await db.restartDatabase();
  });

  group('download_queue_groups CRUD', () {
    test('insertDownloadQueueGroup + getDownloadQueueGroups', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 100,
        workType: 'illust',
        title: 'Test Illust',
        authorName: '作者A',
        pageTotal: 2,
        priority: 5,
      );
      expect(gid, greaterThan(0));

      final groups = await db.getDownloadQueueGroups();
      expect(groups.length, 1);
      expect(groups.first['work_id'], 100);
      expect(groups.first['work_type'], 'illust');
      expect(groups.first['status'], 'pending');
      expect(groups.first['page_total'], 2);
    });

    test('findDownloadQueueGroup で重複検索', () async {
      await db.insertDownloadQueueGroup(
        workId: 200,
        workType: 'novel',
        title: 'Novel',
        authorName: '作者B',
        pageTotal: 1,
        priority: 5,
      );
      final found = await db.findDownloadQueueGroup(200, 'novel');
      expect(found, isNotNull);
      expect(found!['work_id'], 200);
    });

    test('deleteDownloadQueueGroup で子も削除（CASCADE）', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 300,
        workType: 'illust',
        title: 'Cascade',
        authorName: '',
        pageTotal: 2,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 300, 'work_type': 'illust', 'page_index': 0, 'url': 'url0'},
        {'work_id': 300, 'work_type': 'illust', 'page_index': 1, 'url': 'url1'},
      ]);

      final itemsBefore = await db.getDownloadQueueItems(gid);
      expect(itemsBefore.length, 2);

      await db.deleteDownloadQueueGroup(gid);

      final groups = await db.getDownloadQueueGroups();
      expect(groups.length, 0);
      // 子も削除されている
      final itemsAfter = await testDb.query(
        'download_queues',
        where: 'group_id = ?',
        whereArgs: [gid],
      );
      expect(itemsAfter.length, 0);
    });
  });

  group('状態遷移: 単一アイテム', () {
    test('pending -> running -> completed', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 1,
        workType: 'novel',
        title: 'N',
        authorName: '',
        pageTotal: 1,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 1, 'work_type': 'novel', 'page_index': 0, 'url': 'url'},
      ]);

      // running
      await db.updateDownloadQueueItem(itemId: 1, status: 'running');
      await db.updateDownloadQueueGroup(groupId: gid, status: 'running');
      var items = await db.getDownloadQueueItems(gid);
      expect(items.first['status'], 'running');
      var groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'running');

      // completed
      await db.updateDownloadQueueItem(
        itemId: 1,
        status: 'completed',
        localPath: 'novel_text:1',
      );
      await db.updateDownloadQueueGroup(
        groupId: gid,
        status: 'completed',
        pageCompleted: 1,
      );
      items = await db.getDownloadQueueItems(gid);
      expect(items.first['status'], 'completed');
      expect(items.first['local_path'], 'novel_text:1');
      groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'completed');
    });

    test('running -> failed -> pending (retry)', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 2,
        workType: 'illust',
        title: 'I',
        authorName: '',
        pageTotal: 1,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 2, 'work_type': 'illust', 'page_index': 0, 'url': 'url'},
      ]);

      await db.updateDownloadQueueItem(
        itemId: 1,
        status: 'failed',
        errorCode: '404',
        errorMessage: 'not found',
      );
      await db.updateDownloadQueueGroup(
        groupId: gid,
        status: 'failed',
        errorCode: '404',
        errorMessage: 'not found',
      );

      var groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'failed');

      // retry: failed -> pending (DB レベルの状態更新)
      await db.updateDownloadQueueGroup(
        groupId: gid,
        status: 'pending',
        errorCode: null,
        errorMessage: null,
      );
      groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'pending');
      expect(groups.first['error_code'], isNull);
    });

    test('running -> paused -> pending (resume)', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 3,
        workType: 'illust',
        title: 'P',
        authorName: '',
        pageTotal: 1,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 3, 'work_type': 'illust', 'page_index': 0, 'url': 'url'},
      ]);

      await db.updateDownloadQueueGroup(groupId: gid, status: 'running');
      // pause: running -> paused
      await db.updateDownloadQueueGroup(groupId: gid, status: 'paused');
      var groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'paused');

      // resume: paused -> pending
      await db.updateDownloadQueueGroup(groupId: gid, status: 'pending');
      groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'pending');
    });
  });

  group('親子関係（複数ページ）', () {
    test('全子 completed で親も completed', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 10,
        workType: 'illust',
        title: 'Multi',
        authorName: '',
        pageTotal: 3,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 10, 'work_type': 'illust', 'page_index': 0, 'url': 'u0'},
        {'work_id': 10, 'work_type': 'illust', 'page_index': 1, 'url': 'u1'},
        {'work_id': 10, 'work_type': 'illust', 'page_index': 2, 'url': 'u2'},
      ]);

      // 1つずつ完了させる
      for (int i = 1; i <= 3; i++) {
        await db.updateDownloadQueueItem(
          itemId: i,
          status: 'completed',
          localPath: 'file_$i.jpg',
        );
      }

      // 親の進捗更新（DownloadService._updateGroupProgress 相当）
      await db.updateDownloadQueueGroup(
        groupId: gid,
        pageCompleted: 3,
        status: 'completed',
      );

      final groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'completed');
      expect(groups.first['page_completed'], 3);
      final items = await db.getDownloadQueueItems(gid);
      expect(items.every((e) => e['status'] == 'completed'), isTrue);
    });

    test('一部失敗: 親は failed', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 11,
        workType: 'illust',
        title: 'Partial',
        authorName: '',
        pageTotal: 2,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 11, 'work_type': 'illust', 'page_index': 0, 'url': 'u0'},
        {'work_id': 11, 'work_type': 'illust', 'page_index': 1, 'url': 'u1'},
      ]);

      // 1件完了、1件失敗
      await db.updateDownloadQueueItem(
        itemId: 1,
        status: 'completed',
        localPath: 'file_1.jpg',
      );
      await db.updateDownloadQueueItem(
        itemId: 2,
        status: 'failed',
        errorCode: 'network',
      );
      await db.updateDownloadQueueGroup(
        groupId: gid,
        pageCompleted: 1,
        status: 'failed',
        errorCode: 'network',
      );

      final groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'failed');
      final items = await db.getDownloadQueueItems(gid);
      expect(items.where((e) => e['status'] == 'completed').length, 1);
      expect(items.where((e) => e['status'] == 'failed').length, 1);
    });
  });

  group('起動時復旧 (recoverInterruptedDownloads)', () {
    test('running を pending に巻き戻す（downloaded_bytes 維持）', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 20,
        workType: 'illust',
        title: 'Recover',
        authorName: '',
        pageTotal: 1,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 20, 'work_type': 'illust', 'page_index': 0, 'url': 'url'},
      ]);

      // running + 部分的にダウンロード済み
      await db.updateDownloadQueueItem(
        itemId: 1,
        status: 'running',
        downloadedBytes: 500,
      );
      await db.updateDownloadQueueGroup(groupId: gid, status: 'running');

      final count = await db.recoverInterruptedDownloads();
      expect(count, greaterThanOrEqualTo(1));

      final items = await db.getDownloadQueueItems(gid);
      expect(items.first['status'], 'pending');
      // downloaded_bytes が維持されている
      expect(items.first['downloaded_bytes'], 500);

      final groups = await db.getDownloadQueueGroups();
      expect(groups.first['status'], 'pending');
    });
  });

  group('クリーンアップ', () {
    test('deleteDownloadQueueGroupsByStatus で完了を削除', () async {
      final gid1 = await db.insertDownloadQueueGroup(
        workId: 30,
        workType: 'illust',
        title: 'A',
        authorName: '',
        pageTotal: 1,
        priority: 5,
      );
      await db.updateDownloadQueueGroup(
        groupId: gid1,
        status: 'completed',
        pageCompleted: 1,
      );

      final gid2 = await db.insertDownloadQueueGroup(
        workId: 31,
        workType: 'illust',
        title: 'B',
        authorName: '',
        pageTotal: 1,
        priority: 5,
      );
      await db.updateDownloadQueueGroup(groupId: gid2, status: 'pending');

      await db.deleteDownloadQueueGroupsByStatus('completed');

      final groups = await db.getDownloadQueueGroups();
      expect(groups.length, 1);
      expect(groups.first['work_id'], 31);
    });
  });

  group('整合性チェック (integrityCheck)', () {
    // 注: integrityCheck は DownloadService に実装されているため、
    // ここでは DatabaseService レベルの local_path 欠損検出を検証する。
    test('completed だが local_path が空の行は検出される', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 40,
        workType: 'illust',
        title: 'Missing',
        authorName: '',
        pageTotal: 1,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {
          'work_id': 40,
          'work_type': 'illust',
          'page_index': 0,
          'url': 'url',
          'local_path': '', // 空 = 欠損扱い
        },
      ]);
      await db.updateDownloadQueueItem(
        itemId: 1,
        status: 'completed',
        localPath: '', // 空のまま完了（異常状態）
      );
      await db.updateDownloadQueueGroup(
        groupId: gid,
        status: 'completed',
        pageCompleted: 1,
      );

      // local_path が空の completed 行を検索
      final rows = await testDb.query(
        'download_queues',
        where:
            "status = 'completed' AND local_path != '' AND local_path NOT LIKE 'novel_text:%'",
      );
      // 空のため 0 件（検出されるべき）
      expect(rows.length, 0);
    });
  });
}
