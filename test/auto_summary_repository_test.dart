// Phase 9-B2/B2-4+5: AutoSummaryRepository の永続化・復元・stale 畳み込みの回帰。
//
// in-memory sqflite_ffi に auto_summary_runs/items（DB v26 スキーマ）を作り、
// §6-C「画面再接続／再起動復元」の要件を検証する:
// - saveSnapshot → loadLatest/loadRun で items 件数（保存済/未処理）が復元される
// - reconcileStaleRunning: 非 final run を error へ畳み、processing を waiting に戻す
//   （saved は再生成対象にしない＝そのまま）
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/auto_summary_repository.dart';
import 'package:pixiv_viewer/services/auto_summary_snapshot.dart';
import 'package:pixiv_viewer/services/database_service.dart';

const String _createRuns = '''
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
''';

const String _createItems = '''
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
''';

AutoSummarySnapshot _snap({
  required String runId,
  required AutoSummaryPhase phase,
  required List<AutoSummaryItem> items,
  int updatedAt = 1000,
}) {
  return AutoSummarySnapshot(
    runId: runId,
    startedAtMillis: 1,
    updatedAtMillis: updatedAt,
    phase: phase,
    items: items,
  );
}

AutoSummaryItem _item(int id, AutoSummaryItemStatus status) => AutoSummaryItem(
  workId: id,
  tags: const ['百合'],
  title: '作品$id',
  status: status,
);

void main() {
  late DatabaseService db;
  late Database testDb;
  late AutoSummaryRepository repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = DatabaseService();
    testDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 26,
        onCreate: (d, v) async {
          await d.execute(_createRuns);
          await d.execute(_createItems);
        },
      ),
    );
    db.setTestDatabase(testDb);
    repo = AutoSummaryRepository(dbService: db);
  });

  tearDown(() async {
    await testDb.close();
    await db.restartDatabase();
  });

  test('saveSnapshot → loadLatest で保存済件数と未処理キューが復元される', () async {
    await repo.saveSnapshot(
      _snap(
        runId: 'r1',
        phase: AutoSummaryPhase.fetchingBody,
        items: [
          _item(1, AutoSummaryItemStatus.saved),
          _item(2, AutoSummaryItemStatus.saved),
          _item(3, AutoSummaryItemStatus.waiting),
          _item(4, AutoSummaryItemStatus.waiting),
        ],
      ),
    );
    final restored = await repo.loadLatest();
    expect(restored, isNotNull);
    expect(restored!.runId, 'r1');
    // 件数は items から導出される（二重計上しない）。
    expect(restored.savedCount, 2);
    expect(restored.waitingCount, 2);
    expect(restored.targetCount, 4);
    expect(restored.phase, AutoSummaryPhase.fetchingBody);
  });

  test('loadRun: 未知の runId は null', () async {
    expect(await repo.loadRun('nope'), isNull);
  });

  test('loadLatest は updated_at 最大の run を返す', () async {
    await repo.saveSnapshot(
      _snap(
        runId: 'old',
        phase: AutoSummaryPhase.completed,
        items: [_item(1, AutoSummaryItemStatus.saved)],
        updatedAt: 100,
      ),
    );
    await repo.saveSnapshot(
      _snap(
        runId: 'new',
        phase: AutoSummaryPhase.fetchingBody,
        items: [_item(2, AutoSummaryItemStatus.waiting)],
        updatedAt: 999,
      ),
    );
    final latest = await repo.loadLatest();
    expect(latest!.runId, 'new');
  });

  test(
    'reconcileStaleRunning: 非 final run を error へ畳み processing→waiting、saved は維持',
    () async {
      await repo.saveSnapshot(
        _snap(
        runId: 'stale',
        phase: AutoSummaryPhase.fetchingBody, // is_final=0 で保存される
          items: [
            _item(1, AutoSummaryItemStatus.saved),
            _item(2, AutoSummaryItemStatus.processing),
            _item(3, AutoSummaryItemStatus.waiting),
          ],
          updatedAt: 500,
        ),
      );

      final folded = await repo.reconcileStaleRunning();
      expect(folded, 1);

      final restored = await repo.loadRun('stale');
      expect(restored!.phase, AutoSummaryPhase.error);
      // processing だった 2 番は waiting に戻り、saved の 1 番はそのまま（再生成しない）。
      final statuses = {for (final it in restored.items) it.workId: it.status};
      expect(statuses[1], AutoSummaryItemStatus.saved);
      expect(statuses[2], AutoSummaryItemStatus.waiting);
      expect(statuses[3], AutoSummaryItemStatus.waiting);
    },
  );

  test('reconcileStaleRunning: final run（完了）は何もしない', () async {
    await repo.saveSnapshot(
      _snap(
        runId: 'done',
        phase: AutoSummaryPhase.completed, // is_final=1
        items: [_item(1, AutoSummaryItemStatus.saved)],
        updatedAt: 500,
      ),
    );
    final folded = await repo.reconcileStaleRunning();
    expect(folded, 0);
    final restored = await repo.loadRun('done');
    expect(restored!.phase, AutoSummaryPhase.completed);
  });

  test('saveSnapshot は items を丸ごと差し替え（前回状態が残らない）', () async {
    await repo.saveSnapshot(
      _snap(
        runId: 'r2',
        phase: AutoSummaryPhase.fetchingBody,
        items: [
          _item(1, AutoSummaryItemStatus.saved),
          _item(2, AutoSummaryItemStatus.waiting),
        ],
      ),
    );
    await repo.saveSnapshot(
      _snap(
        runId: 'r2',
        phase: AutoSummaryPhase.fetchingBody,
        items: [_item(1, AutoSummaryItemStatus.saved)],
        updatedAt: 2000,
      ),
    );
    final restored = await repo.loadRun('r2');
    expect(restored!.targetCount, 1);
    final rows = await testDb.query(
      'auto_summary_items',
      where: "run_id = 'r2'",
    );
    expect(rows, hasLength(1));
  });
}
