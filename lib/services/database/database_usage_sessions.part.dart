part of 'database_service.dart';

/// 利用時間トラッキング（usage_sessions）CRUD
/// Phase 6c: DatabaseService から分離（ロジック変更なし）。
abstract class DatabaseServiceUsageSessions extends DatabaseServiceTts {
  // ==========================================================================
  // 利用時間トラッキング（usage_sessions）CRUD
  // ==========================================================================

  /// 利用セッション断片を1行保存する（Phase 4: UsageTrackingService から使用）。
  Future<int> insertUsageSession({
    required String workType,
    required int workId,
    required DateTime startedAt,
    required DateTime endedAt,
    required int durationSeconds,
  }) async {
    final db = await database;
    return await db.insert('usage_sessions', {
      'work_type': workType,
      'work_id': workId,
      'started_at': startedAt.toIso8601String(),
      'ended_at': endedAt.toIso8601String(),
      'duration_seconds': durationSeconds,
    });
  }

  /// 利用セッションを全件取得（新しい順）。集計は computeUsageStatsMap で行う。
  Future<List<Map<String, dynamic>>> getUsageSessions() async {
    final db = await database;
    return await db.query('usage_sessions', orderBy: 'started_at DESC');
  }

  /// 利用セッションを全削除（プライバシー用の完全削除から使用）。
  Future<int> deleteAllUsageSessions() async {
    final db = await database;
    return await db.delete('usage_sessions');
  }
}
