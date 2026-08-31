// Phase 4 利用時間トラッキングのユニットテスト。
//
// 対象:
// - 純粋関数: computeUsageStatsMap（期間別集計・日別バケット・不正行の除外）
// - UsageStats.fromComputeMap（Isolate 越境 Map → 型付きデータ変換）
// - UsageTrackingService セッション管理（注入時計・チェックポイント・復帰除外）
// - usage_sessions（DB v19）CRUD（sqflite_ffi インメモリDB）
//
// 実DBファイル・ネットワーク・ファイルシステムには依存しない。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/usage_tracking_service.dart';

void main() {
  // ========================================================================
  // 純粋関数: computeUsageStatsMap
  // ========================================================================
  group('computeUsageStatsMap', () {
    final now = DateTime(2026, 8, 29, 12, 0, 0);

    Map<String, dynamic> row({
      String type = 'novel',
      DateTime? startedAt,
      int duration = 600,
    }) => <String, dynamic>{
      'work_type': type,
      'work_id': 1,
      'started_at': (startedAt ?? now).toIso8601String(),
      'duration_seconds': duration,
    };

    test('空リストは全て0・日別は当日を末尾に30日分0埋め', () {
      final m = computeUsageStatsMap([], now: now);
      expect(m['total'], 0);
      expect(m['today'], 0);
      expect(m['last7'], 0);
      expect(m['last30'], 0);
      expect(m['sessions30'], 0);
      final daily = (m['daily'] as List).cast<Map<String, dynamic>>();
      expect(daily.length, 30);
      expect(daily.last['date'], '2026-8-29');
      expect(daily.last['seconds'], 0);
      expect(daily.first['date'], '2026-7-31');
    });

    test('今日の小説セッションは全期間バケットに加算される', () {
      final m = computeUsageStatsMap([
        row(startedAt: DateTime(2026, 8, 29, 9, 0, 0), duration: 600),
      ], now: now);
      expect(m['total'], 600);
      expect(m['today'], 600);
      expect(m['last7'], 600);
      expect(m['last30'], 600);
      expect(m['novel30'], 600);
      expect(m['illust30'], 0);
      expect(m['sessions30'], 1);
      final daily = (m['daily'] as List).cast<Map<String, dynamic>>();
      expect(daily.last['seconds'], 600);
    });

    test('illust は illust30 にのみ種別加算される', () {
      final m = computeUsageStatsMap([
        row(type: 'illust', startedAt: DateTime(2026, 8, 28), duration: 120),
      ], now: now);
      expect(m['illust30'], 120);
      expect(m['novel30'], 0);
      // 昨日なので「今日」には加算されない
      expect(m['today'], 0);
      expect(m['last30'], 120);
    });

    test('31日前のセッションは last30 に含まれない（total のみ）', () {
      final m = computeUsageStatsMap([
        row(startedAt: DateTime(2026, 7, 28), duration: 100),
      ], now: now);
      expect(m['total'], 100);
      expect(m['last30'], 0);
      expect(m['sessions30'], 0);
    });

    test('8日前は last7 に含まれず last30 には含まれる', () {
      final m = computeUsageStatsMap([
        row(startedAt: DateTime(2026, 8, 21), duration: 60),
      ], now: now);
      expect(m['last7'], 0);
      expect(m['last30'], 60);
    });

    test('不正な行（空日付・解析不能・duration 0・日付欠落）は無視される', () {
      final m = computeUsageStatsMap([
        {'work_type': 'novel', 'started_at': '', 'duration_seconds': 100},
        {
          'work_type': 'novel',
          'started_at': 'invalid-date',
          'duration_seconds': 100,
        },
        {
          'work_type': 'novel',
          'started_at': DateTime(2026, 8, 29, 9).toIso8601String(),
          'duration_seconds': 0,
        },
        {'work_type': 'novel', 'duration_seconds': 100}, // started_at 欠落
      ], now: now);
      expect(m['total'], 0);
      expect(m['today'], 0);
      expect(m['sessions30'], 0);
    });

    test('UsageStats.fromComputeMap は Map を型付きデータへ変換する', () {
      final m = computeUsageStatsMap([
        row(startedAt: DateTime(2026, 8, 29, 9), duration: 600),
      ], now: now);
      final stats = UsageStats.fromComputeMap(m);
      expect(stats.totalSeconds, 600);
      expect(stats.todaySeconds, 600);
      expect(stats.novel30DaysSeconds, 600);
      expect(stats.illust30DaysSeconds, 0);
      expect(stats.sessionCount30Days, 1);
      expect(stats.daily.length, 30);
      expect(stats.daily.last.date, DateTime(2026, 8, 29));
      expect(stats.daily.last.seconds, 600);
      expect(stats.daily.first.seconds, 0);
    });
  });

  // ========================================================================
  // UsageTrackingService セッション管理（注入時計 + インメモリDB）
  // ========================================================================
  group('UsageTrackingService セッション管理', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    late DatabaseService db;
    late Database testDb;
    late UsageTrackingService service;
    late DateTime fakeNow;

    setUp(() async {
      db = DatabaseService();
      testDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 19,
          onCreate: (d, v) async {
            // v19 の usage_sessions と同一スキーマ
            await d.execute('''
              CREATE TABLE IF NOT EXISTS usage_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                work_type TEXT NOT NULL,
                work_id INTEGER NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT NOT NULL,
                duration_seconds INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
      db.setTestDatabase(testDb);
      service = UsageTrackingService();
      service.debugResetForTest();
      fakeNow = DateTime(2026, 8, 29, 10, 0, 0);
      service.clock = () => fakeNow;
    });

    tearDown(() async {
      service.debugResetForTest();
      await testDb.close();
      await db.restartDatabase();
    });

    test('endSession は経過秒数を計算して1行保存する', () async {
      final h = service.startSession(workId: 123, workType: 'novel');
      expect(service.activeSessionCount, 1);
      fakeNow = fakeNow.add(const Duration(seconds: 65));
      await service.endSession(h);
      expect(service.activeSessionCount, 0);
      final rows = await db.getUsageSessions();
      expect(rows, hasLength(1));
      expect(rows.first['work_type'], 'novel');
      expect(rows.first['work_id'], 123);
      expect(rows.first['duration_seconds'], 65);
    });

    test('3秒未満の断片はノイズとして保存されない', () async {
      final h = service.startSession(workId: 1, workType: 'illust');
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      await service.endSession(h);
      expect(await db.getUsageSessions(), isEmpty);
    });

    test('二重 endSession は2回目が no-op', () async {
      final h = service.startSession(workId: 1, workType: 'novel');
      fakeNow = fakeNow.add(const Duration(minutes: 1));
      await service.endSession(h);
      await service.endSession(h);
      expect(await db.getUsageSessions(), hasLength(1));
    });

    test('checkpointAll は経過分を保存しつつセッションを継続させる', () async {
      final h = service.startSession(workId: 7, workType: 'novel');
      fakeNow = fakeNow.add(const Duration(minutes: 10));
      await service.checkpointAll();
      var rows = await db.getUsageSessions();
      expect(rows, hasLength(1));
      expect(rows.first['duration_seconds'], 600);
      expect(service.activeSessionCount, 1);
      // 復帰後さらに5分読んで終了（継続分のみ記録される）
      fakeNow = fakeNow.add(const Duration(minutes: 5));
      await service.endSession(h);
      rows = await db.getUsageSessions();
      expect(rows, hasLength(2));
      // ORDER BY started_at DESC → 新しい方（復帰後の断片）が先頭
      expect(rows.first['duration_seconds'], 300);
    });

    test('discardBackgroundTime はバックグラウンド中の時間を除外する', () async {
      final h = service.startSession(workId: 7, workType: 'novel');
      fakeNow = fakeNow.add(const Duration(minutes: 3));
      await service.checkpointAll();
      // バックグラウンド2時間（計測対象外）
      fakeNow = fakeNow.add(const Duration(hours: 2));
      service.discardBackgroundTime();
      // 復帰後1分読んで終了
      fakeNow = fakeNow.add(const Duration(minutes: 1));
      await service.endSession(h);
      final rows = await db.getUsageSessions();
      expect(rows, hasLength(2));
      expect(rows.first['duration_seconds'], 60);
    });

    test('複数画面の同時セッションは独立して記録される', () async {
      final h1 = service.startSession(workId: 1, workType: 'novel');
      fakeNow = fakeNow.add(const Duration(seconds: 30));
      final h2 = service.startSession(workId: 2, workType: 'illust');
      fakeNow = fakeNow.add(const Duration(minutes: 2));
      await service.endSession(h1); // 10:00開始 → 150秒
      fakeNow = fakeNow.add(const Duration(seconds: 20));
      await service.endSession(h2); // 10:00:30開始 → 140秒
      final rows = await db.getUsageSessions();
      expect(rows, hasLength(2));
      // ORDER BY started_at DESC → h2（10:00:30開始）が先頭
      expect(rows.first['work_type'], 'illust');
      expect(rows.first['duration_seconds'], 140);
      expect(rows.last['duration_seconds'], 150);
    });

    test('deleteAll は全利用セッションを削除する（プライバシー）', () async {
      final h = service.startSession(workId: 9, workType: 'novel');
      fakeNow = fakeNow.add(const Duration(minutes: 1));
      await service.endSession(h);
      expect(await db.getUsageSessions(), hasLength(1));
      await service.deleteAll();
      expect(await db.getUsageSessions(), isEmpty);
    });
  });

  // ========================================================================
  // usage_sessions CRUD（DB v19）
  // ========================================================================
  group('usage_sessions CRUD（DB v19）', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    late DatabaseService db;
    late Database testDb;

    setUp(() async {
      db = DatabaseService();
      testDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 19,
          onCreate: (d, v) async {
            // v19 の usage_sessions と同一スキーマ
            await d.execute('''
              CREATE TABLE IF NOT EXISTS usage_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                work_type TEXT NOT NULL,
                work_id INTEGER NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT NOT NULL,
                duration_seconds INTEGER NOT NULL
              )
            ''');
            await d.execute(
              'CREATE INDEX IF NOT EXISTS idx_usage_sessions_started_at '
              'ON usage_sessions(started_at)',
            );
          },
        ),
      );
      db.setTestDatabase(testDb);
    });

    tearDown(() async {
      await testDb.close();
      await db.restartDatabase();
    });

    test(
      'insertUsageSession / getUsageSessions / deleteAllUsageSessions',
      () async {
        final id = await db.insertUsageSession(
          workType: 'novel',
          workId: 42,
          startedAt: DateTime(2026, 8, 28, 10, 0, 0),
          endedAt: DateTime(2026, 8, 28, 10, 5, 0),
          durationSeconds: 300,
        );
        expect(id, greaterThan(0));
        await db.insertUsageSession(
          workType: 'illust',
          workId: 99,
          startedAt: DateTime(2026, 8, 29, 10, 0, 0),
          endedAt: DateTime(2026, 8, 29, 10, 2, 0),
          durationSeconds: 120,
        );
        final rows = await db.getUsageSessions();
        expect(rows, hasLength(2));
        // ORDER BY started_at DESC → 新しい方が先頭
        expect(rows.first['work_type'], 'illust');
        expect(rows.first['work_id'], 99);
        expect(rows.first['duration_seconds'], 120);
        expect(rows.last['duration_seconds'], 300);
        expect(await db.deleteAllUsageSessions(), 2);
        expect(await db.getUsageSessions(), isEmpty);
      },
    );
  });
}
