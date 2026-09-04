// 読書速度推定サービス（感動機能パック Phase A）。
//
// usage_sessions（DB v19）の novel セッションと novels.text_length から
// 個人の読書速度（字/分）を推定し、「読了目安 / あとXX分」を計算する
// 純粋関数群を提供する。
//
// 設計:
// - 集計ロジックはすべて純粋関数として分離し、DB/UI 無しでテスト可能。
// - 外れ値は中央値ベースの比率で除外（つけっぱなし・居眠り等の極端値を無視）。
// - データ不足時は日本語平均 550字/分 を使用し isEstimated=true で「推定値」明示。
// - サーバー送信なし。端末ローカルデータの読み取りのみ。

import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// データ不足時のフォールバック: 日本語平均読書速度（字/分）。
const double kDefaultCharsPerMinute = 550.0;

/// 速度サンプルとして採用する1作品あたりの最低累計読書秒数。
/// これ未満は「開いただけ」のノイズとして除外する。
const int kMinWorkSecondsForSpeed = 30;

/// 1作品ぶんの累計読書統計（純粋関数の入力）。
class WorkReadingStat {
  final int workId;
  final int textLength;
  final int totalSeconds;

  const WorkReadingStat({
    required this.workId,
    required this.textLength,
    required this.totalSeconds,
  });
}

/// 読書速度推移の1点（週次・字/分）。
class ReadingSpeedPoint {
  final DateTime weekStart;
  final double charsPerMinute;

  const ReadingSpeedPoint({
    required this.weekStart,
    required this.charsPerMinute,
  });
}

/// 個人速度の推定結果。
class ReadingSpeedResult {
  /// 使用する速度（字/分）。
  final double charsPerMinute;

  /// true = 個人データ不足により平均値を使用した「推定値」。
  final bool isEstimated;

  /// 採用されたサンプル（作品）数。
  final int sampleCount;

  const ReadingSpeedResult({
    required this.charsPerMinute,
    required this.isEstimated,
    required this.sampleCount,
  });
}

/// 中央値（空リストは null）。
double? medianOf(List<double> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2.0;
}

/// 中央値ベースの外れ値除外。
///
/// 中央値の 0.25倍〜4倍 の範囲に残る値だけを採用する。
/// 全て除外されてしまった場合は元リストを返す（安全側フォールバック）。
List<double> removeSpeedOutliers(List<double> cpms) {
  final med = medianOf(cpms);
  if (med == null || med <= 0) return const [];
  final kept = cpms
      .where((c) => c >= med * 0.25 && c <= med * 4.0)
      .toList(growable: false);
  return kept.isEmpty ? cpms : kept;
}

/// 作品別統計から個人の読書速度（字/分）を算出する。有効サンプル0なら null。
///
/// 各作品の速度 = textLength * 60 / totalSeconds。
/// 中央値ベースで外れ値を除外したうえで平均し、50〜5000字/分 にクランプする。
double? computeCharsPerMinute(List<WorkReadingStat> stats) {
  final cpms = <double>[];
  for (final s in stats) {
    if (s.textLength <= 0 || s.totalSeconds < kMinWorkSecondsForSpeed) continue;
    cpms.add(s.textLength * 60.0 / s.totalSeconds);
  }
  final kept = removeSpeedOutliers(cpms);
  if (kept.isEmpty) return null;
  final avg = kept.reduce((a, b) => a + b) / kept.length;
  if (!avg.isFinite || avg <= 0) return null;
  return avg.clamp(50.0, 5000.0);
}

/// usage_sessions の行を作品別に集計する（純粋関数）。
///
/// [sessionRows] は started_at DESC 順を想定し、新しい順に最大 [workLimit]
/// 作品を採用する。novel 以外・duration<=0・text_length 不明の作品は除外。
List<WorkReadingStat> aggregateWorkStats(
  List<Map<String, dynamic>> sessionRows,
  Map<int, int> textLengthByWork, {
  int workLimit = 20,
}) {
  final Map<int, int> secondsByWork = {};
  final List<int> order = [];
  for (final row in sessionRows) {
    if ((row['work_type'] as String? ?? '') != 'novel') continue;
    final dur = (row['duration_seconds'] as int?) ?? 0;
    if (dur <= 0) continue;
    final id = (row['work_id'] as int?) ?? 0;
    if (id <= 0) continue;
    if (!secondsByWork.containsKey(id)) order.add(id);
    secondsByWork[id] = (secondsByWork[id] ?? 0) + dur;
  }
  final result = <WorkReadingStat>[];
  for (final id in order.take(workLimit)) {
    final len = textLengthByWork[id] ?? 0;
    if (len <= 0) continue;
    result.add(
      WorkReadingStat(
        workId: id,
        textLength: len,
        totalSeconds: secondsByWork[id]!,
      ),
    );
  }
  return result;
}

/// 残り時間の分数（純粋関数）。
///
/// - remainingChars <= 0 なら 0
/// - charsPerMinute <= 0 なら既定値で計算
/// - 残りがある限り最低1分（切り上げ）
int estimateRemainingMinutes(int remainingChars, double charsPerMinute) {
  if (remainingChars <= 0) return 0;
  final cpm = charsPerMinute > 0 ? charsPerMinute : kDefaultCharsPerMinute;
  final minutes = (remainingChars / cpm).ceil();
  return minutes < 1 ? 1 : minutes;
}

/// 表示用フォーマット（純粋関数）: 分 → 「約XX分」「約X時間XX分」。
String formatReadingTime(int minutes) {
  if (minutes <= 0) return '1分以内';
  if (minutes < 60) return '約$minutes分';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '約$h時間' : '約$h時間$m分';
}

/// 週次（月曜始まり・ローカル日付）の読書速度推移点を算出する（純粋関数）。
///
/// 週ごとに対象作品の text_length 合計 ÷ 小説読書秒数合計 で字/分を出す。
/// 秒数が [kMinWorkSecondsForSpeed] 未満の週はノイズとしてスキップする。
List<ReadingSpeedPoint> computeWeeklySpeedPoints(
  List<Map<String, dynamic>> sessionRows,
  Map<int, int> textLengthByWork,
) {
  final Map<DateTime, Map<int, int>> weekWorkSeconds = {};
  final Map<DateTime, int> weekTotalSeconds = {};
  for (final row in sessionRows) {
    if ((row['work_type'] as String? ?? '') != 'novel') continue;
    final dur = (row['duration_seconds'] as int?) ?? 0;
    if (dur <= 0) continue;
    final id = (row['work_id'] as int?) ?? 0;
    if (id <= 0) continue;
    final startedAt = row['started_at'] as String?;
    if (startedAt == null || startedAt.isEmpty) continue;
    DateTime dt;
    try {
      dt = DateTime.parse(startedAt).toLocal();
    } catch (_) {
      continue;
    }
    final monday = DateTime(
      dt.year,
      dt.month,
      dt.day,
    ).subtract(Duration(days: dt.weekday - 1));
    weekTotalSeconds[monday] = (weekTotalSeconds[monday] ?? 0) + dur;
    final perWork = weekWorkSeconds.putIfAbsent(monday, () => <int, int>{});
    perWork[id] = (perWork[id] ?? 0) + dur;
  }
  final points = <ReadingSpeedPoint>[];
  final weeks = weekTotalSeconds.keys.toList()..sort();
  for (final week in weeks) {
    final total = weekTotalSeconds[week]!;
    if (total < kMinWorkSecondsForSpeed) continue;
    final perWork = weekWorkSeconds[week]!;
    var chars = 0;
    for (final id in perWork.keys) {
      chars += textLengthByWork[id] ?? 0;
    }
    if (chars <= 0) continue;
    points.add(
      ReadingSpeedPoint(weekStart: week, charsPerMinute: chars * 60.0 / total),
    );
  }
  return points;
}

/// 読書速度サービス（シングルトン）。DB アクセスはここに閉じ込める。
class ReadingSpeedService {
  static final ReadingSpeedService _instance = ReadingSpeedService._internal();
  factory ReadingSpeedService() => _instance;
  ReadingSpeedService._internal();

  /// 個人の読書速度。データ不足・失敗時は既定値（isEstimated=true）を返す。
  Future<ReadingSpeedResult> getPersonalSpeed({int workLimit = 20}) async {
    try {
      final stats = await _collectWorkStats(workLimit: workLimit);
      final cpm = computeCharsPerMinute(stats);
      if (cpm == null) {
        return const ReadingSpeedResult(
          charsPerMinute: kDefaultCharsPerMinute,
          isEstimated: true,
          sampleCount: 0,
        );
      }
      return ReadingSpeedResult(
        charsPerMinute: cpm,
        isEstimated: false,
        sampleCount: stats.length,
      );
    } catch (e) {
      debugPrint('読書速度の取得に失敗（既定値を使用）: $e');
      return const ReadingSpeedResult(
        charsPerMinute: kDefaultCharsPerMinute,
        isEstimated: true,
        sampleCount: 0,
      );
    }
  }

  /// 統計画面用: 週次の読書速度推移（字/分）。失敗時は空リスト。
  Future<List<ReadingSpeedPoint>> getSpeedHistory() async {
    try {
      final db = DatabaseService();
      final rows = await db.getUsageSessions();
      final lengths = await _textLengthMap();
      return computeWeeklySpeedPoints(rows, lengths);
    } catch (e) {
      debugPrint('読書速度推移の取得に失敗（無視）: $e');
      return const [];
    }
  }

  Future<Map<int, int>> _textLengthMap() async {
    final db = await DatabaseService().database;
    final rows = await db.rawQuery('SELECT id, text_length FROM novels');
    final map = <int, int>{};
    for (final r in rows) {
      final id = (r['id'] as int?) ?? 0;
      final len = (r['text_length'] as int?) ?? 0;
      if (id > 0 && len > 0) map[id] = len;
    }
    return map;
  }

  Future<List<WorkReadingStat>> _collectWorkStats({
    required int workLimit,
  }) async {
    final db = DatabaseService();
    final rows = await db.getUsageSessions();
    final lengths = await _textLengthMap();
    return aggregateWorkStats(rows, lengths, workLimit: workLimit);
  }
}
