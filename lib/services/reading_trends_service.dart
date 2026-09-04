// 読書傾向集計サービス（感動機能パック Phase B）。
//
// history / usage_sessions / novels.tags_json を集計して、読書傾向の深い
// 可視化に必要なデータを算出する:
// - 曜日 × 時間帯 ヒートマップ（7×24）
// - 月別のトップタグ推移
// - 作者集中度（ドーナツ用）
// - スティーク（N日連続、途切れそうな警告）
// - 今年の読書サマリ
// - 発掘率（初見作者比率）
//
// 設計:
// - 集計はすべて純粋関数（[now] 注入・DB/UI 無し）で単体テスト可能。
// - Isolate.run は「Illegal argument in isolate message」回避方針により
//   使用せず、O(n) の軽い集計をメイン Isolate で直接実行する。
// - 日付はすべてローカル時間（端末の表示単位）。
// - サーバー送信なし。端末ローカルデータの読み取りのみ。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// 集計期間。[days] が null の場合「全期間」。
enum TrendPeriod {
  d30('30日', 30),
  d90('90日', 90),
  year('1年', 365),
  all('全期間', null);

  const TrendPeriod(this.label, this.days);

  final String label;
  final int? days;
}

/// [dt] が期間内か（開始は含む、[now] まで）。
bool isInPeriod(DateTime dt, TrendPeriod period, DateTime now) {
  final days = period.days;
  if (days == null) return true;
  final start = now.subtract(Duration(days: days));
  return !dt.isBefore(start) && !dt.isAfter(now);
}

DateTime? _parseLocal(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    return DateTime.parse(s).toLocal();
  } catch (_) {
    return null;
  }
}

/// 曜日（月曜始まり）× 時間帯 のヒートマップ（純粋関数）。
///
/// 戻り値は長さ168の配列: index = weekday * 24 + hour
/// （weekday: 0=月 .. 6=日）。期間内のセッション数を集計する。
List<int> computeWeekdayHourHeatmap(
  List<Map<String, dynamic>> usageRows, {
  required TrendPeriod period,
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final counts = List<int>.filled(7 * 24, 0);
  for (final row in usageRows) {
    final dt = _parseLocal(row['started_at'] as String?);
    if (dt == null || !isInPeriod(dt, period, n)) continue;
    counts[(dt.weekday - 1) * 24 + dt.hour]++;
  }
  return counts;
}

/// 月別のトップタグ推移（純粋関数）。
///
/// `[{year, month, tags: [{name, count}]}]` を古い順に返し、データのない
/// 月を省略し、最大 [maxMonths] までを返す。
List<Map<String, dynamic>> computeMonthlyTagEvolution(
  List<Map<String, dynamic>> historyRows,
  Map<int, List<String>> tagsByWork, {
  required TrendPeriod period,
  DateTime? now,
  int topN = 3,
  int maxMonths = 12,
}) {
  final n = now ?? DateTime.now();
  final days = period.days;
  final DateTime start = days == null
      ? DateTime(n.year, n.month - (maxMonths - 1))
      : n.subtract(Duration(days: days));
  final Map<int, Map<String, int>> byMonth = {};
  for (final row in historyRows) {
    final dt = _parseLocal(row['created_at'] as String?);
    if (dt == null || dt.isBefore(start)) continue;
    if (!dt.isBefore(n.add(const Duration(days: 1)))) continue;
    final id = (row['work_id'] as int?) ?? 0;
    final tags = tagsByWork[id] ?? const <String>[];
    if (tags.isEmpty) continue;
    final monthKey = dt.year * 12 + (dt.month - 1);
    final m = byMonth.putIfAbsent(monthKey, () => <String, int>{});
    for (final t in tags) {
      m[t] = (m[t] ?? 0) + 1;
    }
  }
  final months = byMonth.keys.toList()..sort();
  final result = <Map<String, dynamic>>[];
  final monthStart = months.length > maxMonths ? months.length - maxMonths : 0;
  for (final key in months.sublist(monthStart)) {
    final year = key ~/ 12;
    final month = key % 12 + 1;
    final top = byMonth[key]!.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    result.add({
      'year': year,
      'month': month,
      'tags': top
          .take(topN)
          .map((e) => {'name': e.key, 'count': e.value})
          .toList(),
    });
  }
  return result;
}

/// 作者集中度（純粋関数・ドーナツ用）。
///
/// `{top: [{name, count}], totalAuthors, totalRows, topShare}` を返し、
/// [topShare] は上位 [topN] の行割合（0.0〜1.0）。
Map<String, dynamic> computeAuthorConcentration(
  List<Map<String, dynamic>> historyRows, {
  int topN = 5,
}) {
  final counts = <String, int>{};
  var totalRows = 0;
  for (final row in historyRows) {
    final author = (row['author_name'] as String?) ?? '';
    if (author.isEmpty) continue;
    counts[author] = (counts[author] ?? 0) + 1;
    totalRows++;
  }
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final top = sorted
      .take(topN)
      .map((e) => {'name': e.key, 'count': e.value})
      .toList();
  var topCount = 0;
  for (final e in top) {
    topCount += (e['count'] as int?) ?? 0;
  }
  return {
    'top': top,
    'totalAuthors': counts.length,
    'totalRows': totalRows,
    'topShare': totalRows == 0 ? 0.0 : topCount / totalRows,
  };
}

/// 読書スティーク（連続日数、純粋関数）。
///
/// [activeDays] は閲覧・読書があった日（日付のみ）の集合。
/// `{current, longest, atRisk}` を返す:
/// - current: 本日を含む連続日数。本日の記録がない場合は昨日までの
///   連続日数を返し [atRisk]=true（途切れそう）、途切れていれば 0。
/// - longest: 全記録中最長の連続日数。
Map<String, dynamic> computeReadingStreak(
  Iterable<DateTime> activeDays, {
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final days = activeDays.map((d) => DateTime(d.year, d.month, d.day)).toSet();

  var current = 0;
  var atRisk = false;
  var cursor = today;
  if (!days.contains(cursor)) {
    cursor = today.subtract(const Duration(days: 1));
    atRisk = true;
  }
  while (days.contains(cursor)) {
    current++;
    cursor = cursor.subtract(const Duration(days: 1));
  }

  var longest = days.isEmpty ? 0 : 1;
  if (days.isNotEmpty) {
    final sorted = days.toList()..sort();
    var run = 1;
    for (var i = 1; i < sorted.length; i++) {
      run = sorted[i].difference(sorted[i - 1]).inDays == 1 ? run + 1 : 1;
      if (run > longest) longest = run;
    }
  }

  return {
    'current': current,
    'longest': longest,
    'atRisk': atRisk && current > 0,
  };
}

/// 今年の読書サマリ（小説のみ、純粋関数）。
///
/// `{workCount, totalChars, totalSeconds}` を返す。[workCount] は今年
/// 読んだ小説作品の distinct 数、[totalChars] はそれらの text_length 合計、
/// [totalSeconds] は今年の小説利用秒数合計。
Map<String, dynamic> computeAnnualSummary(
  List<Map<String, dynamic>> usageRows,
  Map<int, int> textLengthByWork, {
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final works = <int>{};
  var totalSeconds = 0;
  for (final row in usageRows) {
    final wt = (row['work_type'] as String?) ?? '';
    if (wt != 'novel') continue;
    final dur = (row['duration_seconds'] as int?) ?? 0;
    if (dur <= 0) continue;
    final dt = _parseLocal(row['started_at'] as String?);
    if (dt == null || dt.year != n.year) continue;
    final id = (row['work_id'] as int?) ?? 0;
    if (id <= 0) continue;
    works.add(id);
    totalSeconds += dur;
  }
  var totalChars = 0;
  for (final id in works) {
    totalChars += textLengthByWork[id] ?? 0;
  }
  return {
    'workCount': works.length,
    'totalChars': totalChars,
    'totalSeconds': totalSeconds,
  };
}

/// 発掘率（初見作者比率、純粋関数）。
///
/// [period] 内に出た作者のうち、期間前に履歴のない（初見）作者の比率。
/// `{totalAuthors, newAuthors, rate}` を返す。
Map<String, dynamic> computeDiscoveryRate(
  List<Map<String, dynamic>> historyRows, {
  required TrendPeriod period,
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final days = period.days;
  final DateTime start = days == null
      ? DateTime(2000)
      : n.subtract(Duration(days: days));
  final inPeriodAuthors = <String>{};
  final beforeAuthors = <String>{};
  for (final row in historyRows) {
    final author = (row['author_name'] as String?) ?? '';
    if (author.isEmpty) continue;
    final dt = _parseLocal(row['created_at'] as String?);
    if (dt == null) continue;
    if (!dt.isBefore(start) && !dt.isAfter(n)) {
      inPeriodAuthors.add(author);
    } else if (dt.isBefore(start)) {
      beforeAuthors.add(author);
    }
  }
  var newAuthors = 0;
  for (final a in inPeriodAuthors) {
    if (!beforeAuthors.contains(a)) newAuthors++;
  }
  final total = inPeriodAuthors.length;
  return {
    'totalAuthors': total,
    'newAuthors': newAuthors,
    'rate': total == 0 ? 0.0 : newAuthors / total,
  };
}

/// 文字数フォーマット: 「9999文字」/「1.2万字」/「1.23万字」/「35.6万字」。
String formatCharCount(int chars) {
  if (chars <= 0) return '0文字';
  if (chars < 10000) return '$chars文字';
  var s = (chars / 10000).toStringAsFixed(1);
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  return '$s万字';
}

/// 時間フォーマット: 「1分未満」/「10分」/「1時間」/「1時間30分」。
String formatHoursMinutes(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h <= 0) return m > 0 ? '$m分' : '1分未満';
  return m > 0 ? '$h時間$m分' : '$h時間';
}

/// 期間ごとの読書傾向集計の全結果。
class ReadingTrendsBundle {
  final TrendPeriod period;
  final List<int> heatmap;
  final List<Map<String, dynamic>> monthlyTags;
  final Map<String, dynamic> authorConcentration;
  final Map<String, dynamic> streak;
  final Map<String, dynamic> annualSummary;
  final Map<String, dynamic> discoveryRate;
  final bool hasAnyData;

  const ReadingTrendsBundle({
    required this.period,
    required this.heatmap,
    required this.monthlyTags,
    required this.authorConcentration,
    required this.streak,
    required this.annualSummary,
    required this.discoveryRate,
    required this.hasAnyData,
  });
}

/// 読書傾向サービス（シングルトン）。DB アクセスはここに閉じ込める。
class ReadingTrendsService {
  static final ReadingTrendsService _instance =
      ReadingTrendsService._internal();
  factory ReadingTrendsService() => _instance;
  ReadingTrendsService._internal();

  /// 全傾向を取得・集計する。失敗時は hasAnyData=false の空バンドルを
  /// 返し、UI は空状態を表示する。
  Future<ReadingTrendsBundle> fetch(TrendPeriod period) async {
    try {
      final n = DateTime.now();
      final db = DatabaseService();
      final history = await db.getHistoryList();
      final usage = await db.getUsageSessions();
      final rawDb = await db.database;
      final tagRows = await rawDb.rawQuery(
        'SELECT id, tags_json FROM novels '
        'UNION ALL SELECT id, tags_json FROM illusts',
      );
      final tagsByWork = <int, List<String>>{};
      for (final r in tagRows) {
        final id = (r['id'] as int?) ?? 0;
        if (id <= 0) continue;
        final tags = _parseTags(r['tags_json'] as String?);
        if (tags.isNotEmpty) tagsByWork[id] = tags;
      }
      final lenRows = await rawDb.rawQuery(
        'SELECT id, text_length FROM novels',
      );
      final textLengthByWork = <int, int>{};
      for (final r in lenRows) {
        final id = (r['id'] as int?) ?? 0;
        final len = (r['text_length'] as int?) ?? 0;
        if (id > 0 && len > 0) textLengthByWork[id] = len;
      }

      final inPeriodHistory = history.where((h) {
        final dt = _parseLocal(h['created_at'] as String?);
        return dt != null && isInPeriod(dt, period, n);
      }).toList();

      final Set<DateTime> activeDays = {};
      for (final r in usage) {
        final dt = _parseLocal(r['started_at'] as String?);
        if (dt != null) activeDays.add(DateTime(dt.year, dt.month, dt.day));
      }
      for (final r in history) {
        final dt = _parseLocal(r['created_at'] as String?);
        if (dt != null) activeDays.add(DateTime(dt.year, dt.month, dt.day));
      }

      return ReadingTrendsBundle(
        period: period,
        heatmap: computeWeekdayHourHeatmap(usage, period: period, now: n),
        monthlyTags: computeMonthlyTagEvolution(
          history,
          tagsByWork,
          period: period,
          now: n,
        ),
        authorConcentration: computeAuthorConcentration(inPeriodHistory),
        streak: computeReadingStreak(activeDays, now: n),
        annualSummary: computeAnnualSummary(usage, textLengthByWork, now: n),
        discoveryRate: computeDiscoveryRate(history, period: period, now: n),
        hasAnyData: history.isNotEmpty || usage.isNotEmpty,
      );
    } catch (e) {
      debugPrint('読書傾向の取得に失敗（空状態を表示）: $e');
      return ReadingTrendsBundle(
        period: period,
        heatmap: List<int>.filled(7 * 24, 0),
        monthlyTags: const [],
        authorConcentration: const {
          'top': <Map<String, dynamic>>[],
          'totalAuthors': 0,
          'totalRows': 0,
          'topShare': 0.0,
        },
        streak: const {'current': 0, 'longest': 0, 'atRisk': false},
        annualSummary: const {
          'workCount': 0,
          'totalChars': 0,
          'totalSeconds': 0,
        },
        discoveryRate: const {'totalAuthors': 0, 'newAuthors': 0, 'rate': 0.0},
        hasAnyData: false,
      );
    }
  }

  /// tags_json（JSON 文字列配列）を解析する。失敗時はカンマ区切りとして扱う。
  static List<String> _parseTags(String? json) {
    if (json == null || json.trim().isEmpty) return const [];
    try {
      final v = jsonDecode(json);
      if (v is List) return v.whereType<String>().toList();
    } catch (_) {}
    return json
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
}
