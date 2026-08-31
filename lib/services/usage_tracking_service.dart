// 利用時間トラッキングサービス（Phase 4）。
//
// 「いつ・どの種類の作品を・どれだけの時間」閲覧したかを端末ローカルの
// usage_sessions テーブル（DB v19）に記録する。
//
// 設計:
// - セッションはメモリ上で開始し、画面破棄時に1行として永続化する。
// - アプリがバックグラウンドへ移行する際は main.dart の
//   WidgetsBindingObserver から checkpointAll() が呼ばれ、そこまでの
//   経過分を確定保存した上で計測を継続する（復帰後の時間が失われない）。
// - フォアグラウンド復帰時は discardBackgroundTime() でバックグラウンド中の
//   経過時間を計測から除外する。
// - 集計（computeUsageStatsMap）は純粋関数として分離し単体テスト可能にする。
// - サーバー送信は一切行わない。Google Drive バックアップ対象外
//   （プライバシー上の端末ローカルデータのため）。
// - 記録対象: 小説リーダー画面（work_type='novel'=読書時間）、
//   イラスト詳細画面（work_type='illust'=閲覧時間）。
//   小説詳細画面はリーダーとの二重計上になるため対象外。

import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// 日別利用時間の1要素。
class DailyUsage {
  final DateTime date;
  final int seconds;

  DailyUsage({required this.date, required this.seconds});
}

/// 利用時間統計の集計結果（統計画面表示用）。
class UsageStats {
  final int totalSeconds;
  final int todaySeconds;
  final int last7DaysSeconds;
  final int last30DaysSeconds;
  final int novel30DaysSeconds;
  final int illust30DaysSeconds;
  final int sessionCount30Days;
  final List<DailyUsage> daily;

  const UsageStats({
    required this.totalSeconds,
    required this.todaySeconds,
    required this.last7DaysSeconds,
    required this.last30DaysSeconds,
    required this.novel30DaysSeconds,
    required this.illust30DaysSeconds,
    required this.sessionCount30Days,
    required this.daily,
  });

  /// Isolate から返された生 Map を型付けデータへ変換する。
  factory UsageStats.fromComputeMap(Map<String, dynamic> m) {
    final dailyRaw = (m['daily'] as List<dynamic>?) ?? [];
    final daily = dailyRaw.map((e) {
      final map = e as Map<String, dynamic>;
      final parts = (map['date'] as String).split('-');
      return DailyUsage(
        date: DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        ),
        seconds: (map['seconds'] as int?) ?? 0,
      );
    }).toList();
    return UsageStats(
      totalSeconds: (m['total'] as int?) ?? 0,
      todaySeconds: (m['today'] as int?) ?? 0,
      last7DaysSeconds: (m['last7'] as int?) ?? 0,
      last30DaysSeconds: (m['last30'] as int?) ?? 0,
      novel30DaysSeconds: (m['novel30'] as int?) ?? 0,
      illust30DaysSeconds: (m['illust30'] as int?) ?? 0,
      sessionCount30Days: (m['sessions30'] as int?) ?? 0,
      daily: daily,
    );
  }
}

/// 純粋関数: usage_sessions の行リストから利用時間統計を算出する。
///
/// UI/DB に依存せず、統計画面の Isolate.run から呼ばれる。
/// 日付バケットは started_at をローカル日として扱う。
/// 不正な行（duration 0・日付解析不能）は無視される。
Map<String, dynamic> computeUsageStatsMap(
  List<Map<String, dynamic>> rows, {
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);

  int total = 0;
  int todaySec = 0;
  int last7 = 0;
  int last30 = 0;
  int novel30 = 0;
  int illust30 = 0;
  int sessions30 = 0;

  // 過去30日分の日別マップを初期化（欠損日は 0 のまま）。
  final Map<String, int> dailyMap = {};
  for (int i = 29; i >= 0; i--) {
    final d = today.subtract(Duration(days: i));
    dailyMap['${d.year}-${d.month}-${d.day}'] = 0;
  }

  for (final row in rows) {
    final dur = (row['duration_seconds'] as int?) ?? 0;
    if (dur <= 0) continue;
    final startedAt = row['started_at'] as String?;
    if (startedAt == null || startedAt.isEmpty) continue;
    DateTime? dt;
    try {
      dt = DateTime.parse(startedAt).toLocal();
    } catch (_) {
      dt = null;
    }
    if (dt == null) continue;

    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    total += dur;
    if (diff == 0) todaySec += dur;
    if (diff >= 0 && diff < 7) last7 += dur;
    if (diff >= 0 && diff < 30) {
      last30 += dur;
      sessions30++;
      final type = (row['work_type'] as String?) ?? '';
      if (type == 'novel') novel30 += dur;
      if (type == 'illust') illust30 += dur;
      final key = '${day.year}-${day.month}-${day.day}';
      if (dailyMap.containsKey(key)) {
        dailyMap[key] = dailyMap[key]! + dur;
      }
    }
  }

  final daily = dailyMap.entries
      .map((e) => {'date': e.key, 'seconds': e.value})
      .toList();

  return {
    'total': total,
    'today': todaySec,
    'last7': last7,
    'last30': last30,
    'novel30': novel30,
    'illust30': illust30,
    'sessions30': sessions30,
    'daily': daily,
  };
}

/// セッションハンドル（startSession の戻り値）。
/// 不透明な識別子のみを持ち、画面はこれを endSession に渡す。
class UsageSessionHandle {
  final int seq;
  const UsageSessionHandle._(this.seq);
}

/// 進行中セッションのメモリ上表現。
class _ActiveSession {
  final int workId;
  final String workType;

  /// 計測開始時刻。checkpoint / 復帰時にリセットされる。
  DateTime startedAt;

  _ActiveSession({
    required this.workId,
    required this.workType,
    required this.startedAt,
  });
}

/// 利用時間トラッキングのセッション管理。
class UsageTrackingService {
  static final UsageTrackingService _instance =
      UsageTrackingService._internal();
  factory UsageTrackingService() => _instance;
  UsageTrackingService._internal();

  /// テスト用に時計を差し替え可能。
  DateTime Function() clock = DateTime.now;

  final Map<int, _ActiveSession> _active = {};
  int _nextSeq = 0;

  /// この秒数未満のセッション断片はノイズとして破棄する。
  static const int _minFragmentSeconds = 3;

  /// 画面の initState 相当のタイミングで呼ぶ。
  UsageSessionHandle startSession({
    required int workId,
    required String workType,
  }) {
    final seq = ++_nextSeq;
    _active[seq] = _ActiveSession(
      workId: workId,
      workType: workType,
      startedAt: clock(),
    );
    return UsageSessionHandle._(seq);
  }

  /// 画面の dispose 相当のタイミングで呼ぶ。二重呼び出しは安全（no-op）。
  Future<void> endSession(UsageSessionHandle handle) async {
    final session = _active.remove(handle.seq);
    if (session == null) return;
    await _persistFragment(session);
  }

  /// バックグラウンド移行時のチェックポイント。
  ///
  /// 経過分を1行として保存し、セッション自体は継続扱いにする
  /// （OSによる強制終了で時間が失われるのを防ぎつつ、
  /// フォアグラウンド復帰後の計測も継続できるようにする）。
  Future<void> checkpointAll() async {
    final now = clock();
    for (final session in _active.values) {
      await _persistFragment(session, end: now);
      session.startedAt = now;
    }
  }

  /// フォアグラウンド復帰時: バックグラウンド中の時間を計測から除外する。
  ///
  /// checkpointAll で startedAt が「一時停止時刻」にリセットされているため、
  /// そのままでは復帰までのバックグラウンド時間が加算されてしまう。
  /// これを防ぐため復帰時刻へ前倒しする。
  void discardBackgroundTime() {
    final now = clock();
    for (final session in _active.values) {
      session.startedAt = now;
    }
  }

  /// 統計画面用: 集計済み利用時間統計を返す。
  Future<UsageStats> getStats() async {
    final rows = await DatabaseService().getUsageSessions();
    return UsageStats.fromComputeMap(computeUsageStatsMap(rows, now: clock()));
  }

  /// プライバシー: 利用セッションを全削除する。
  Future<void> deleteAll() => DatabaseService().deleteAllUsageSessions();

  Future<void> _persistFragment(_ActiveSession session, {DateTime? end}) async {
    final endedAt = end ?? clock();
    final duration = endedAt.difference(session.startedAt).inSeconds;
    if (duration < _minFragmentSeconds) return;
    try {
      await DatabaseService().insertUsageSession(
        workType: session.workType,
        workId: session.workId,
        startedAt: session.startedAt,
        endedAt: endedAt,
        durationSeconds: duration,
      );
    } catch (e) {
      // トラッキング失敗が本体機能を壊さないよう握りつぶす。
      debugPrint('利用セッションの保存に失敗（無視）: $e');
    }
  }

  /// テスト用: 内部状態と時計をリセットする。
  @visibleForTesting
  void debugResetForTest() {
    _active.clear();
    _nextSeq = 0;
    clock = DateTime.now;
  }

  /// テスト用: 進行中セッション数。
  @visibleForTesting
  int get activeSessionCount => _active.length;
}
