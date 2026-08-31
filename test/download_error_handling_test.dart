// ダウンロードエラーハンドリングのユニットテスト。
//
// 検証内容:
// 1. classifyDownloadError が具体エラーコードを返す（汎用的な 'unknown' にならない）
// 2. buildDownloadErrorMessage が例外型名・スタックトレース先頭を含む（500文字制限）
// 3. 回帰: クエリ結果 Map を読み取り専用として扱っても
//    UnsupportedError('read-only') にならず DB 更新まで完結する

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/download_service.dart';
import 'package:pixiv_viewer/services/pixiv_api_http.dart';

void main() {
  group('classifyDownloadError', () {
    test('Pixiv 例外はステータスコードで分類される', () {
      expect(classifyDownloadError(PixivAuthException('x')), 'auth_401');
      expect(
        classifyDownloadError(PixivForbiddenException('x')),
        'forbidden_403',
      );
      expect(
        classifyDownloadError(PixivNotFoundException('x')),
        'not_found_404',
      );
      expect(
        classifyDownloadError(PixivRateLimitException('x')),
        'rate_limit_429',
      );
    });

    test('ネットワーク系例外は network_error', () {
      expect(
        classifyDownloadError(SocketException('timeout')),
        'network_error',
      );
      expect(
        classifyDownloadError(TimeoutException('no response')),
        'network_error',
      );
      expect(
        classifyDownloadError(http.ClientException('bad gateway')),
        'network_error',
      );
    });

    test('UnsupportedError は unsupported_error（旧実装では unknown だった）', () {
      // 実機で発生した "unknown - Unsupported operation: read-only" の再現
      final e = UnsupportedError('read-only');
      expect(e.toString(), contains('read-only'));
      expect(classifyDownloadError(e), 'unsupported_error');
      expect(classifyDownloadError(e), isNot('unknown'));
    });

    test('ファイル系例外は file_error', () {
      expect(
        classifyDownloadError(FileSystemException('rename failed', '/a/b')),
        'file_error',
      );
      // 実機で発生した PathNotFoundException（errno 2）と同じ形
      // SDK 署名: PathNotFoundException(String? path, OSError osError, [String? message])
      final pnf = PathNotFoundException(
        '/a/b',
        OSError('errno = 2', 2),
        'Cannot rename file',
      );
      expect(classifyDownloadError(pnf), 'file_error');
    });

    test('未知の型は型名（小文字）を返す（unknown にはならない）', () {
      expect(classifyDownloadError(StateError('broken')), 'stateerror');
      // 独自例外型は型名がそのまま分類コードになる
      expect(
        classifyDownloadError(_CustomTestException('generic')),
        '_customtestexception',
      );
    });
  });

  group('buildDownloadErrorMessage', () {
    test('例外型名・メッセージ・スタック先頭を含む', () {
      StackTrace st = StackTrace.empty;
      try {
        throw UnsupportedError('read-only');
      } catch (e, st2) {
        st = st2;
        final msg = buildDownloadErrorMessage(e, st);
        expect(msg, contains('UnsupportedError'));
        expect(msg, contains('read-only'));
        // スタックトレース先頭（#0 行）が含まれる
        expect(msg, contains('#0'));
        expect(msg, contains('download_error_handling_test.dart'));
      }
    });

    test('500文字に切り詰められる', () {
      final longMsg = 'x' * 2000;
      final msg = buildDownloadErrorMessage(
        Exception(longMsg),
        StackTrace.empty,
      );
      expect(msg.length, lessThanOrEqualTo(500));
    });

    test('短いメッセージはそのまま（型名プレフィックス付き）', () {
      final msg = buildDownloadErrorMessage(Exception('abc'), StackTrace.empty);
      expect(msg, contains('Exception: Exception: abc'));
      expect(msg.length, lessThanOrEqualTo(500));
    });
  });

  group('クエリ結果 read-only 回帰（sqflite_common_ffi）', () {
    late DatabaseService db;
    late Database testDb;

    setUpAll(() {
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

    test('原因再現: 読み取り専用 Map への代入は UnsupportedError を送出する', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 42,
        workType: 'novel',
        title: 'T',
        authorName: 'A',
        pageTotal: 1,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 42, 'work_type': 'novel', 'page_index': 0, 'url': ''},
      ]);

      // _acquireNextPendingItem と同じ rawQuery
      final rows = await testDb.rawQuery('''
        SELECT dq.*
        FROM download_queues dq
        INNER JOIN download_queue_groups dg ON dq.group_id = dg.id
        WHERE dq.status = 'pending' AND dg.status IN ('pending', 'running')
        ORDER BY dg.priority DESC, dg.created_at ASC, dq.page_index ASC
        LIMIT 1
      ''');
      expect(rows, isNotEmpty);

      // 実機（Android）の rawQuery 結果は読み取り専用 Map を返す。
      // FFI 環境は可変になるため、unmodifiable で読み取り専用をシミュレートする。
      final readOnlyRow = Map<String, Object?>.unmodifiable(rows.first);
      expect(
        () => readOnlyRow['local_path'] = 'novel_text:42',
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('修正パターン: 読み取り専用 Map を扱っても read-only エラーなし', () async {
      final gid = await db.insertDownloadQueueGroup(
        workId: 42,
        workType: 'novel',
        title: 'T',
        authorName: 'A',
        pageTotal: 1,
        priority: 5,
      );
      await db.insertDownloadQueueItems(gid, [
        {'work_id': 42, 'work_type': 'novel', 'page_index': 0, 'url': ''},
      ]);

      // _acquireNextPendingItem と同じ取得クエリ
      final rows = await testDb.rawQuery('''
        SELECT dq.*
        FROM download_queues dq
        INNER JOIN download_queue_groups dg ON dq.group_id = dg.id
        WHERE dq.status = 'pending' AND dg.status IN ('pending', 'running')
        ORDER BY dg.priority DESC, dg.created_at ASC, dq.page_index ASC
        LIMIT 1
      ''');
      final item = Map<String, Object?>.unmodifiable(rows.first);
      final itemId = item['id'] as int;

      // 修正後の _downloadItem/_downloadNovelItem と同じパターン:
      // Map は読み取って、localPath はローカル変数に格納し、
      // DB への反映は db.update()（updateDownloadQueueItem）で行う。
      String localPath;
      final workId = item['work_id'] as int;
      localPath = 'novel_text:$workId';
      await db.updateDownloadQueueItem(itemId: itemId, localPath: localPath);
      await db.updateDownloadQueueItem(
        itemId: itemId,
        status: 'completed',
        localPath: localPath,
      );

      // DB には反映される
      final items = await db.getDownloadQueueItems(gid);
      expect(items, hasLength(1));
      expect(items.first['local_path'], 'novel_text:42');
      expect(items.first['status'], 'completed');

      // 元のクエリ結果 Map は無変更（読み取り専用でも安全）
      expect(item['local_path'], '');
    });
  });
}

class _CustomTestException implements Exception {
  _CustomTestException(this.message);
  final String message;
  @override
  String toString() => message;
}
