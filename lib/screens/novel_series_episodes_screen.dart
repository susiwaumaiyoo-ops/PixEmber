import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../illust_model.dart' show Author;
import '../novel_model.dart';
import '../services/pixiv_api_service.dart';
import '../services/reading_speed_service.dart';
import '../widgets/pixiv_image.dart';
import 'novel_detail_screen.dart';

class NovelSeriesEpisodesScreen extends StatefulWidget {
  final NovelSeriesInfo series;
  final String? coverUrl;
  final Author? author;
  final int? episodeCount;

  const NovelSeriesEpisodesScreen({
    super.key,
    required this.series,
    this.coverUrl,
    this.author,
    this.episodeCount,
  });

  @override
  State<NovelSeriesEpisodesScreen> createState() =>
      _NovelSeriesEpisodesScreenState();
}

class _NovelSeriesEpisodesScreenState extends State<NovelSeriesEpisodesScreen> {
  final PixivApiService _api = PixivApiService();
  List<Novel> _episodes = [];
  bool _isLoading = false;
  String? _errorMessage;
  // シリーズ読了時間（Phase A）。算出不可（オフライン等）なら null で非表示。
  String? _seriesTimeLabel;
  String? _seriesUnreadLabel;
  // ディープリンク等でタイトルが空の場合、取得後に最初の話のシリーズ名で補完
  late String _seriesTitle;

  @override
  void initState() {
    super.initState();
    _seriesTitle = widget.series.title;
    _fetchEpisodes();
  }

  Future<void> _fetchEpisodes() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final list = await _api.getNovelSeries(widget.series.id);
      // タイトルが未指定なら最初の話のシリーズ情報から補完
      if (_seriesTitle.isEmpty &&
          list.isNotEmpty &&
          list.first.series != null) {
        _seriesTitle = list.first.series!.title;
      }
      setState(() {
        _episodes = list;
        _isLoading = false;
      });
      // シリーズ全体の読了時間をバックグラウンドで算出（Phase A）。
      // 失敗しても一覧表示には影響させない。
      _loadSeriesStats(list);
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  /// 全話の合計読了時間と未読分の残り時間を算出する（Phase A）。
  ///
  /// getNovelSeriesAll で全話を取得して合計する。取得失敗（オフライン等）時は
  /// 読み込み済みリストで代替し、それも無理ならラベルは null（非表示）のまま。
  /// 未読分は prefs の `novel_progress_<id>`（0〜100%）から算出する。
  Future<void> _loadSeriesStats(List<Novel> fallback) async {
    try {
      var all = fallback;
      try {
        final full = await _api.getNovelSeriesAll(widget.series.id);
        if (full.isNotEmpty) all = full;
      } catch (_) {
        // オフライン・API失敗: 取得済みリストで代替
      }
      if (all.isEmpty) return;
      final speed = await ReadingSpeedService().getPersonalSpeed();
      final prefs = await SharedPreferences.getInstance();
      var totalChars = 0;
      var unreadChars = 0;
      for (final n in all) {
        final chars = n.textLength;
        if (chars <= 0) continue;
        totalChars += chars;
        final progress = prefs.getDouble('novel_progress_${n.id}') ?? 0.0;
        unreadChars += (chars * (1.0 - (progress / 100.0).clamp(0.0, 1.0)))
            .round();
      }
      if (totalChars <= 0 || !mounted) return;
      setState(() {
        _seriesTimeLabel = formatReadingTime(
          estimateRemainingMinutes(totalChars, speed.charsPerMinute),
        );
        _seriesUnreadLabel = unreadChars > 0
            ? formatReadingTime(
                estimateRemainingMinutes(unreadChars, speed.charsPerMinute),
              )
            : null;
      });
    } catch (e) {
      debugPrint('シリーズ読了時間の算出に失敗（無視）: $e');
    }
  }

  // 年齢制限（R-18）は x_restrict フィールドで判定（0=全年齢, 1=R-18, 2=R-18G）
  bool _isR18(Novel novel) => novel.xRestrict >= 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_seriesTitle)),
      body: Column(
        children: [
          // シリーズ概要ヘッダー
          Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 90,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: widget.coverUrl != null && widget.coverUrl!.isNotEmpty
                      ? PixivImage(
                          url: widget.coverUrl!,
                          isThumbnail: true,
                          fit: BoxFit.cover,
                        )
                      : const Icon(Icons.book, color: Colors.grey),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.series.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      if (widget.author != null)
                        Text(
                          '✍️ ${widget.author!.name}',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        '全 ${widget.episodeCount ?? _episodes.length} 話',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      // 読了時間サマリー（Phase A / 算出できた場合のみ表示）
                      if (_seriesTimeLabel != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '⏱ 全話合計 $_seriesTimeLabel',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        if (_seriesUnreadLabel != null)
                          Text(
                            '未読分 $_seriesUnreadLabel',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.grey),
          // エピソード一覧
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.pinkAccent),
                  )
                : _errorMessage != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _fetchEpisodes,
                            child: const Text('再試行'),
                          ),
                        ],
                      ),
                    ),
                  )
                : _episodes.isEmpty
                ? const Center(
                    child: Text(
                      'エピソードが見つかりませんでした。',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8.0),
                    itemCount: _episodes.length,
                    itemBuilder: (context, index) {
                      final novel = _episodes[index];
                      final isR18 = _isR18(novel);
                      return Card(
                        color: const Color(0xFF1E1E1E),
                        margin: const EdgeInsets.symmetric(vertical: 4.0),
                        child: ListTile(
                          leading: SizedBox(
                            width: 54,
                            height: 81,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: novel.coverUrl.isNotEmpty
                                      ? PixivImage(
                                          url: novel.coverUrl,
                                          fit: BoxFit.cover,
                                          isThumbnail: true,
                                        )
                                      : const Icon(
                                          Icons.book,
                                          color: Colors.grey,
                                        ),
                                ),
                                if (isR18)
                                  Positioned(
                                    top: 4,
                                    left: 4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.redAccent.withValues(
                                          alpha: 0.9,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        'R18',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 8,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          title: Text(
                            '${index + 1}. ${novel.title}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              // 文字数 / ページ数 / 年齢制限
                              Wrap(
                                spacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (isR18)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.redAccent.withValues(
                                          alpha: 0.15,
                                        ),
                                        borderRadius: BorderRadius.circular(3),
                                        border: Border.all(
                                          color: Colors.redAccent.withValues(
                                            alpha: 0.4,
                                          ),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: const Text(
                                        'R-18',
                                        style: TextStyle(
                                          color: Colors.redAccent,
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  Text(
                                    '📄 ${novel.pageCount}P',
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 11,
                                    ),
                                  ),
                                  Text(
                                    '✍️ ${novel.textLength}文字',
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              // タグ一覧
                              if (novel.tags.isNotEmpty)
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 2,
                                  children: novel.tags.map((tag) {
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.pinkAccent.withValues(
                                          alpha: 0.15,
                                        ),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: Text(
                                        tag,
                                        style: const TextStyle(
                                          fontSize: 9,
                                          color: Colors.pinkAccent,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                            ],
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    NovelDetailScreen(novel: novel),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
