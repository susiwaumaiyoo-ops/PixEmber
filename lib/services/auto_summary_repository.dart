// Phase 9-B: 自動要約の実行状態・作品キューの永続化リポジトリ。
//
// 責務（§6-C）:
// - run 単位のスナップショット（正本の一部）を auto_summary_runs に保存。
// - 作品単位の状態遷移を auto_summary_items に保存（本文は保存しない）。
// - 画面を閉じて戻ったとき・OS 終了後に最新 run を復元して再接続できるようにする。
// - stale な running（is_final=0 かつプロセス生存と照合できないもの）を
//   中断扱い（error）へ畳むための走査を提供する。
//
// DB 依存は DatabaseService 経由（テストでは in-memory sqflite を注入）。

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'auto_summary_snapshot.dart';
import 'database_service.dart';

/// 自動要約の永続化担当。
class AutoSummaryRepository {
  AutoSummaryRepository({DatabaseService? dbService})
    : _db = dbService ?? DatabaseService();

  final DatabaseService _db;
  Future<Database> get _database => _db.database;

  /// スナップショットを run + items として保存する（upsert 的）。
  /// 本文・思考・トークン列は保存しない（進捗 DB へ本文を複製しない）。
  Future<void> saveSnapshot(AutoSummarySnapshot s) async {
    final db = await _database;
    final batch = db.batch();
    batch.insert('auto_summary_runs', {
      'run_id': s.runId,
      'phase': s.phase.name,
      'wait_reason': s.waitReason.name,
      'started_at_millis': s.startedAtMillis,
      'updated_at_millis': s.updatedAtMillis,
      'current_tag': s.currentTag,
      'current_work_id': s.currentWorkId,
      'current_work_title': s.currentWorkTitle,
      'model_label': s.modelLabel,
      'backend_name': s.backendName,
      'candidates_fetched': s.candidatesFetched,
      'has_more_candidates': s.hasMoreCandidates ? 1 : 0,
      'stop_reason': s.stopReason,
      'is_final': s.phase.isTerminal ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // items をまるごと差し替え（件数は items から導出する正本を常に一致させる）。
    batch.delete('auto_summary_items', where: 'run_id = ?', whereArgs: [s.runId]);
    for (final it in s.items) {
      batch.insert('auto_summary_items', {
        'run_id': s.runId,
        'work_id': it.workId,
        'tags_json': jsonEncode(it.tags),
        'title': it.title,
        'status': it.status.name,
        'error_reason': it.errorReason,
        'updated_at_millis': it.updatedAtMillis,
      });
    }
    await batch.commit(noResult: true);
  }

  /// 指定 run のスナップショットを復元する（無ければ null）。
  Future<AutoSummarySnapshot?> loadRun(String runId) async {
    final db = await _database;
    final runs = await db.query(
      'auto_summary_runs',
      where: 'run_id = ?',
      whereArgs: [runId],
      limit: 1,
    );
    if (runs.isEmpty) return null;
    final items = await db.query(
      'auto_summary_items',
      where: 'run_id = ?',
      whereArgs: [runId],
      orderBy: 'updated_at_millis ASC',
    );
    return _build(runs.first, items);
  }

  /// 直近の実行（最終・非完了を問わず updated_at 最大）を返す。
  /// 画面復帰時に「既存の実行へ再接続」の判定に使う。
  Future<AutoSummarySnapshot?> loadLatest() async {
    final db = await _database;
    final runs = await db.query(
      'auto_summary_runs',
      orderBy: 'updated_at_millis DESC',
      limit: 1,
    );
    if (runs.isEmpty) return null;
    final runId = runs.first['run_id'] as String;
    return loadRun(runId);
  }

  /// プロセス生存と照合できない running 状態の run を中断（error）へ畳む。
  /// 起動直後に一度呼ぶ。保存済み作品（status=saved）はそのまま（再生成しない）。
  /// processing だったものは waiting に戻し、再開時に未完了から処理する。
  Future<int> reconcileStaleRunning() async {
    final db = await _database;
    final stale = await db.query(
      'auto_summary_runs',
      where: 'is_final = 0',
    );
    var count = 0;
    for (final row in stale) {
      final runId = row['run_id'] as String;
      await db.update(
        'auto_summary_runs',
        {'phase': AutoSummaryPhase.error.name, 'is_final': 1},
        where: 'run_id = ?',
        whereArgs: [runId],
      );
      await db.rawUpdate(
        'UPDATE auto_summary_items SET status = ?, updated_at_millis = ? '
        'WHERE run_id = ? AND status = ?',
        [
          AutoSummaryItemStatus.waiting.name,
          DateTime.now().millisecondsSinceEpoch,
          runId,
          AutoSummaryItemStatus.processing.name,
        ],
      );
      count++;
    }
    return count;
  }

  AutoSummarySnapshot _build(Map<String, Object?> run, List<Map<String, Object?>> itemRows) {
    final items = <AutoSummaryItem>[
      for (final r in itemRows)
        AutoSummaryItem(
          workId: (r['work_id'] as num).toInt(),
          tags: (jsonDecode(r['tags_json'] as String? ?? '[]') as List<dynamic>)
              .map((e) => e.toString())
              .toList(),
          title: r['title'] as String? ?? '',
          status: AutoSummaryItemStatus.values.firstWhere(
            (e) => e.name == r['status'],
            orElse: () => AutoSummaryItemStatus.waiting,
          ),
          errorReason: r['error_reason'] as String?,
          updatedAtMillis: (r['updated_at_millis'] as num?)?.toInt() ?? 0,
        ),
    ];
    return AutoSummarySnapshot(
      runId: run['run_id'] as String,
      phase: AutoSummaryPhase.values.firstWhere(
        (e) => e.name == run['phase'],
        orElse: () => AutoSummaryPhase.disabled,
      ),
      waitReason: AutoSummaryWaitReason.values.firstWhere(
        (e) => e.name == (run['wait_reason'] as String?),
        orElse: () => AutoSummaryWaitReason.none,
      ),
      startedAtMillis: (run['started_at_millis'] as num?)?.toInt() ?? 0,
      updatedAtMillis: (run['updated_at_millis'] as num?)?.toInt() ?? 0,
      currentTag: run['current_tag'] as String?,
      currentWorkId: (run['current_work_id'] as num?)?.toInt(),
      currentWorkTitle: run['current_work_title'] as String?,
      modelLabel: run['model_label'] as String?,
      backendName: run['backend_name'] as String?,
      candidatesFetched: (run['candidates_fetched'] as num?)?.toInt() ?? 0,
      hasMoreCandidates: (run['has_more_candidates'] as num?)?.toInt() == 1,
      stopReason: run['stop_reason'] as String?,
      items: items,
    );
  }
}
