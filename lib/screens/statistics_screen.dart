import 'package:flutter/material.dart';
import '../services/database_service.dart';
import '../services/reading_speed_service.dart';
import '../services/usage_tracking_service.dart';

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

/// 閲覧履歴の集計関数（トップレベルの純粋関数）。
///
/// - `DatabaseService` / `sqflite` は一切呼ばない。
/// - `Illust` / `Novel` インスタンスも扱わない。
/// - 引数・戻り値は `List<Map<String, dynamic>>` / `Map` / プリミティブのみ。
/// - Widget / BuildContext / Binding 等の送信不可オブジェクトを参照しないため、
///   メイン Isolate で直接呼び出せる（Isolate.run 不要）。
Map<String, dynamic> computeStatistics(
  List<Map<String, dynamic>> rows, {
  DateTime? now,
}) {
  int total = rows.length;
  int illust = 0;
  int novel = 0;
  int unknown = 0;

  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);

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
  UsageStats? _usage;
  // 読書速度（Phase A）
  List<ReadingSpeedPoint> _speedHistory = const [];
  ReadingSpeedResult? _speedResult;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 履歴・利用時間を取得し、集計（純粋関数）をメイン Isolate で実行する。
  ///
  /// 集計は O(n) の軽い処理のため Isolate を介さず直接呼び出す。
  /// 以前 Isolate.run を用いていたが、クロージャが Widget / Binding 系の
  /// 送信不可オブジェクトを参照して「Illegal argument in isolate
  /// message」を投じる不具合があった。
  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final history = await DatabaseService().getHistoryList();
      final raw = computeStatistics(history);
      // 利用時間（Phase 4）: usage_sessions から集計。
      final usageRows = await DatabaseService().getUsageSessions();
      final usageRaw = computeUsageStatsMap(usageRows);
      // 読書速度（Phase A）: 失敗しても他の統計表示は止めない。
      List<ReadingSpeedPoint> speedHistory = const [];
      ReadingSpeedResult? speedResult;
      try {
        final speedService = ReadingSpeedService();
        speedHistory = await speedService.getSpeedHistory();
        speedResult = await speedService.getPersonalSpeed();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _data = StatisticsData.fromComputeMap(raw);
        _usage = UsageStats.fromComputeMap(usageRaw);
        _speedHistory = speedHistory;
        _speedResult = speedResult;
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
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '利用時間データを削除',
            onPressed: _confirmDeleteUsageData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _buildError()
          : _data == null ||
                (_data!.totalCount == 0 &&
                    (_usage == null || _usage!.totalSeconds == 0))
          ? const Center(
              child: Text('閲覧履歴がありません', style: TextStyle(color: Colors.grey)),
            )
          : RefreshIndicator(onRefresh: _load, child: _buildContent()),
    );
  }

  Widget _buildError() {
    // 長いエラーメッセージ（スタックトレース等）でも溢れないよう、
    // 縦方向にスクロール可能にし、mainAxisSize: min で収まるサイズにする。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 40),
          const Icon(Icons.error_outline, color: Colors.grey, size: 48),
          const SizedBox(height: 16),
          SelectableText(
            '統計の読み込みに失敗しました\n$_error',
            style: const TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _load, child: const Text('再読み込み')),
          const SizedBox(height: 40),
        ],
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
        if (_usage != null) ...[
          _buildUsageCard(_usage!),
          const SizedBox(height: 12),
        ],
        _buildReadingSpeedCard(),
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

  /// G. 読書速度の推移（Phase A: 字/分の折れ線）。
  Widget _buildReadingSpeedCard() {
    final result = _speedResult;
    final points = _speedHistory;
    return _sectionCard(
      title: '読書速度',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (result != null)
            Text(
              '現在の推定速度: 約${result.charsPerMinute.round()}字/分'
              '${result.isEstimated ? '（推定値: データ不足のため平均速度）' : ''}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          const SizedBox(height: 12),
          if (points.length < 2)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'あと数冊読むと、ここに読書速度の推移が表示されます',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            )
          else ...[
            const Text(
              '週別の読書速度（字/分）',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: CustomPaint(
                painter: _LineChartPainter(
                  points.map((p) => p.charsPerMinute).toList(),
                ),
                child: Container(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// F. 読書・閲覧時間（Phase 4: usage_sessions 集計）。
  Widget _buildUsageCard(UsageStats usage) {
    final dailyMinutes = usage.daily
        .map((e) => (e.seconds / 60).round())
        .toList();
    return _sectionCard(
      title: '読書・閲覧時間',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildUsageSummaryGrid(usage),
          const SizedBox(height: 12),
          Text(
            '過去30日: 小説 ${_formatDuration(usage.novel30DaysSeconds)} / '
            'イラスト ${_formatDuration(usage.illust30DaysSeconds)}'
            '（${usage.sessionCount30Days} セッション）',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 12),
          const Text(
            '過去30日の日別利用時間（分）',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 160,
            child: CustomPaint(
              painter: _BarChartPainter(dailyMinutes),
              child: Container(),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '※ 利用時間は端末内にのみ保存され、サーバー送信・'
            'Google Drive バックアップの対象外です。',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// 利用時間サマリー（2列グリッド）。
  Widget _buildUsageSummaryGrid(UsageStats usage) {
    final entries = <(String, String)>[
      ('総利用時間', _formatDuration(usage.totalSeconds)),
      ('今日', _formatDuration(usage.todaySeconds)),
      ('過去7日', _formatDuration(usage.last7DaysSeconds)),
      ('過去30日', _formatDuration(usage.last30DaysSeconds)),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: entries
          .map(
            (e) => SizedBox(
              width: (MediaQuery.of(context).size.width - 48) / 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.$2,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    e.$1,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  /// 秒数を「N時間M分」「M分」「S秒」形式に整形する。
  String _formatDuration(int seconds) {
    if (seconds <= 0) return '0分';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return m > 0 ? '$h時間$m分' : '$h時間';
    if (m > 0) return '$m分';
    return '$seconds秒';
  }

  /// プライバシー: 利用時間データ全削除の確認ダイアログ。
  Future<void> _confirmDeleteUsageData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('利用時間データを削除'),
        content: const Text('記録された読書・閲覧時間をすべて削除します。\nこの操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await UsageTrackingService().deleteAll();
    if (mounted) _load();
  }

  /// B. 過去30日の日別閲覧数（CustomPainter による簡易棒グラフ）
  Widget _buildDailyChartCard(StatisticsData data) {
    final values = data.dailyCounts.map((e) => e.count).toList();
    return Card(
      color: const Color(0xFF1E1E1E),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                // count == 0 のセグメントは幅を持たせず描画しない。
                // Expanded(flex: 0) はアサーション違反でクラッシュするため。
                .where((s) => s.count > 0)
                .map(
                  (s) => Expanded(
                    flex: s.count,
                    child: Container(height: 20, color: s.color),
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
          mainAxisSize: MainAxisSize.min,
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

/// 週別読書速度の簡易折れ線グラフ（Phase A）。`CustomPainter` で描画する。
class _LineChartPainter extends CustomPainter {
  final List<double> values;

  _LineChartPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV) <= 0 ? 1.0 : (maxV - minV);

    // ベースライン
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      Paint()..color = Colors.grey.withValues(alpha: 0.3),
    );

    final stepX = size.width / (values.length - 1);
    Offset pointAt(int i) {
      final t = (values[i] - minV) / range;
      return Offset(i * stepX, (size.height - 8) - t * (size.height - 16));
    }

    final path = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (int i = 1; i < values.length; i++) {
      path.lineTo(pointAt(i).dx, pointAt(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.pinkAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    final dotPaint = Paint()..color = Colors.pinkAccent;
    for (int i = 0; i < values.length; i++) {
      canvas.drawCircle(pointAt(i), 2.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter old) => old.values != values;
}
