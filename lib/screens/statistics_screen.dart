import 'dart:isolate';
import 'package:flutter/material.dart';
import '../services/database_service.dart';

/// 日別閲覧数の1要素。
class DailyViewCount {
  final DateTime date;
  final int count;

  DailyViewCount({required this.date, required this.count});
}

/// ラベル付きカウント（作者等の集計用）。
class LabelCount {
  final String label;
  final int count;

  LabelCount({required this.label, required this.count});
}

/// 閲覧統計の集計結果を保持するデータクラス。
///
/// DB から取得した生の履歴リストをメイン Isolate 側で [StatisticsData.fromComputeMap]
/// により変換して生成する。Isolate 越境時はプリミティブ/Map/List のみを使う。
class StatisticsData {
  final int totalCount;
  final int illustCount;
  final int novelCount;
  final int unknownTypeCount;
  final int todayCount;
  final int last7DaysCount;
  final int last30DaysCount;
  final List<DailyViewCount> dailyCounts;
  final List<LabelCount> topTags;
  final List<LabelCount> topAuthors;

  const StatisticsData({
    required this.totalCount,
    required this.illustCount,
    required this.novelCount,
    required this.unknownTypeCount,
    required this.todayCount,
    required this.last7DaysCount,
    required this.last30DaysCount,
    required this.dailyCounts,
    required this.topTags,
    required this.topAuthors,
  });

  /// Isolate から返された生 Map を型付けデータへ変換する。
  factory StatisticsData.fromComputeMap(Map<String, dynamic> m) {
    final dailyRaw = (m['daily'] as List<dynamic>?) ?? [];
    final daily = dailyRaw.map((e) {
      final map = e as Map<String, dynamic>;
      final parts = (map['date'] as String).split('-');
      final dt = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
      return DailyViewCount(date: dt, count: (map['count'] as int?) ?? 0);
    }).toList();

    final authorsRaw = (m['authors'] as List<dynamic>?) ?? [];
    final authors = authorsRaw.map((e) {
      final map = e as Map<String, dynamic>;
      return LabelCount(
        label: (map['name'] as String?) ?? '',
        count: (map['count'] as int?) ?? 0,
      );
    }).toList();

    // history テーブルには tags カラムが存在しないため常に空。
    final tagsRaw = (m['tags'] as List<dynamic>?) ?? [];
    final tags = tagsRaw.map((e) {
      final map = e as Map<String, dynamic>;
      return LabelCount(
        label: (map['name'] as String?) ?? '',
        count: (map['count'] as int?) ?? 0,
      );
    }).toList();

    return StatisticsData(
      totalCount: (m['total'] as int?) ?? 0,
      illustCount: (m['illust'] as int?) ?? 0,
      novelCount: (m['novel'] as int?) ?? 0,
      unknownTypeCount: (m['unknown'] as int?) ?? 0,
      todayCount: (m['today'] as int?) ?? 0,
      last7DaysCount: (m['last7'] as int?) ?? 0,
      last30DaysCount: (m['last30'] as int?) ?? 0,
      dailyCounts: daily,
      topTags: tags,
      topAuthors: authors,
    );
  }
}

/// Isolate 内で実行する集計関数（トップレベル関数）。
///
/// - `DatabaseService` / `sqflite` は一切呼ばない。
/// - `Illust` / `Novel` インスタンスも扱わない。
/// - 引数・戻り値は `List<Map<String, dynamic>>` / `Map` / プリミティブのみ。
Map<String, dynamic> _computeStatistics(List<Map<String, dynamic>> rows) {
  int total = rows.length;
  int illust = 0;
  int novel = 0;
  int unknown = 0;

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  int todayCount = 0;
  int last7 = 0;
  int last30 = 0;

  // 過去30日分の日別マップを初期化（欠損日は 0 のまま）。
  final Map<String, int> dailyMap = {};
  for (int i = 29; i >= 0; i--) {
    final d = today.subtract(Duration(days: i));
    dailyMap['${d.year}-${d.month}-${d.day}'] = 0;
  }

  final Map<String, int> authorCounts = {};

  for (final row in rows) {
    final type = (row['type'] as String?) ?? '';
    if (type == 'novel') {
      novel++;
    } else if (type == 'illust' || type == 'ugoira') {
      illust++;
    } else {
      unknown++;
    }

    final createdAt = row['created_at'] as String?;
    DateTime? dt;
    if (createdAt != null && createdAt.isNotEmpty) {
      try {
        dt = DateTime.parse(createdAt).toLocal();
      } catch (_) {
        dt = null;
      }
    }
    if (dt != null) {
      final day = DateTime(dt.year, dt.month, dt.day);
      final diff = today.difference(day).inDays;
      if (diff == 0) todayCount++;
      if (diff >= 0 && diff < 7) last7++;
      if (diff >= 0 && diff < 30) {
        last30++;
        final key = '${day.year}-${day.month}-${day.day}';
        if (dailyMap.containsKey(key)) {
          dailyMap[key] = dailyMap[key]! + 1;
        }
      }
    }

    // history テーブルには tags カラムがないためタグ集計は行わない。
    final author = (row['author_name'] as String?) ?? '';
    if (author.isNotEmpty) {
      authorCounts[author] = (authorCounts[author] ?? 0) + 1;
    }
  }

  final authorsSorted = authorCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final topAuthors = authorsSorted
      .take(10)
      .map((e) => {'name': e.key, 'count': e.value})
      .toList();

  final daily = dailyMap.entries
      .map((e) => {'date': e.key, 'count': e.value})
      .toList();

  return {
    'total': total,
    'illust': illust,
    'novel': novel,
    'unknown': unknown,
    'today': todayCount,
    'last7': last7,
    'last30': last30,
    'daily': daily,
    'authors': topAuthors,
    'tags': <Map<String, dynamic>>[],
  };
}

/// 閲覧統計画面。
///
/// 既存の履歴データを読み取り専用で集計し、閲覧傾向を可視化する。
/// DB スキーマ・バージョン(16) は変更せず、ネットワーク通信も行わない。
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  StatisticsData? _data;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// メイン Isolate で履歴を取得し、重い集計のみ Isolate.run に委譲する。
  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final history = await DatabaseService().getHistoryList();
      // 可変コピーを作り、プリミティブ/Map のみのリストとして Isolate に渡す。
      final rows = List<Map<String, dynamic>>.from(history);
      final raw = await Isolate.run<Map<String, dynamic>>(
        () => _computeStatistics(rows),
      );
      if (!mounted) return;
      setState(() {
        _data = StatisticsData.fromComputeMap(raw);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('閲覧統計'),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _buildError()
          : _data == null || _data!.totalCount == 0
          ? const Center(
              child: Text('閲覧履歴がありません', style: TextStyle(color: Colors.grey)),
            )
          : RefreshIndicator(onRefresh: _load, child: _buildContent()),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.grey, size: 48),
            const SizedBox(height: 16),
            Text(
              '統計の読み込みに失敗しました\n$_error',
              style: const TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _load, child: const Text('再読み込み')),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final data = _data!;
    return ListView(
      padding: const EdgeInsets.all(12.0),
      children: [
        _buildSummaryCard(data),
        const SizedBox(height: 12),
        _buildDailyChartCard(data),
        const SizedBox(height: 12),
        _buildRatioCard(data),
        const SizedBox(height: 12),
        _buildTagCard(data),
        const SizedBox(height: 12),
        _buildAuthorCard(data),
        const SizedBox(height: 12),
      ],
    );
  }

  /// A. サマリーカード
  Widget _buildSummaryCard(StatisticsData data) {
    final items = [
      _SummaryItem(label: '総閲覧数', value: data.totalCount),
      _SummaryItem(label: 'イラスト', value: data.illustCount),
      _SummaryItem(label: '小説', value: data.novelCount),
      _SummaryItem(label: '今日', value: data.todayCount),
      _SummaryItem(label: '過去7日', value: data.last7DaysCount),
      _SummaryItem(label: '過去30日', value: data.last30DaysCount),
    ];
    return Card(
      color: const Color(0xFF1E1E1E),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: items
              .map(
                (e) => SizedBox(
                  width: (MediaQuery.of(context).size.width - 48) / 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.value.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 22,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        e.label,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  /// B. 過去30日の日別閲覧数（CustomPainter による簡易棒グラフ）
  Widget _buildDailyChartCard(StatisticsData data) {
    final values = data.dailyCounts.map((e) => e.count).toList();
    return Card(
      color: const Color(0xFF1E1E1E),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '過去30日の日別閲覧数',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 160,
              child: CustomPaint(
                painter: _BarChartPainter(values),
                child: Container(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// C. イラスト / 小説の比率（横方向の比率バー）
  Widget _buildRatioCard(StatisticsData data) {
    final total = data.illustCount + data.novelCount + data.unknownTypeCount;
    if (total == 0) {
      return _sectionCard(
        title: 'イラスト / 小説の比率',
        body: const Text('データがありません', style: TextStyle(color: Colors.grey)),
      );
    }
    final segments = [
      _RatioSegment(
        label: 'イラスト',
        count: data.illustCount,
        color: Colors.pinkAccent,
      ),
      _RatioSegment(
        label: '小説',
        count: data.novelCount,
        color: Colors.tealAccent,
      ),
      _RatioSegment(
        label: '不明',
        count: data.unknownTypeCount,
        color: Colors.grey,
      ),
    ];
    return _sectionCard(
      title: 'イラスト / 小説の比率',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: segments
                .map(
                  (s) => Expanded(
                    flex: s.count,
                    child: Container(
                      height: 20,
                      color: s.count == 0 ? Colors.transparent : s.color,
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: segments
                .map(
                  (s) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 10, height: 10, color: s.color),
                      const SizedBox(width: 4),
                      Text(
                        '${s.label}: ${s.count} '
                        '(${(s.count / total * 100).toStringAsFixed(1)}%)',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  /// D. よく見たタグ TOP10（history には tags カラムがないため非表示）
  Widget _buildTagCard(StatisticsData data) {
    if (data.topTags.isEmpty) {
      return _sectionCard(
        title: 'よく見たタグ TOP10',
        body: const Text('タグ情報がありません', style: TextStyle(color: Colors.grey)),
      );
    }
    return _buildRankCard('よく見たタグ TOP10', data.topTags);
  }

  /// E. よく見た作者 TOP10
  Widget _buildAuthorCard(StatisticsData data) {
    if (data.topAuthors.isEmpty) {
      return _sectionCard(
        title: 'よく見た作者 TOP10',
        body: const Text('作者情報がありません', style: TextStyle(color: Colors.grey)),
      );
    }
    return _buildRankCard('よく見た作者 TOP10', data.topAuthors);
  }

  Widget _buildRankCard(String title, List<LabelCount> items) {
    return _sectionCard(
      title: title,
      body: Column(
        children: items.asMap().entries.map((entry) {
          final rank = entry.key + 1;
          final item = entry.value;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '$rank',
                    style: const TextStyle(
                      color: Colors.pinkAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    item.label,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${item.count} 回',
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _sectionCard({required String title, required Widget body}) {
    return Card(
      color: const Color(0xFF1E1E1E),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 12),
            body,
          ],
        ),
      ),
    );
  }
}

class _SummaryItem {
  final String label;
  final int value;
  _SummaryItem({required this.label, required this.value});
}

class _RatioSegment {
  final String label;
  final int count;
  final Color color;
  _RatioSegment({
    required this.label,
    required this.count,
    required this.color,
  });
}

/// 日別閲覧数の簡易棒グラフ。`CustomPainter` で描画する。
class _BarChartPainter extends CustomPainter {
  final List<int> values;

  _BarChartPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxVal = values.reduce((a, b) => a > b ? a : b);
    final maxH = maxVal == 0 ? 1 : maxVal.toDouble();
    final count = values.length;
    const gap = 2.0;
    final barW = (size.width - gap * (count - 1)) / count;

    // ベースライン
    final basePaint = Paint()..color = Colors.grey.withValues(alpha: 0.3);
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      basePaint,
    );

    final paint = Paint()..color = Colors.pinkAccent;
    for (int i = 0; i < count; i++) {
      final h = (values[i] / maxH) * (size.height - 4);
      final x = i * (barW + gap);
      final y = size.height - h;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barW, h),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter old) => old.values != values;
}
