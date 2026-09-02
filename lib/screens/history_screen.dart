import 'package:flutter/material.dart';
import 'novel_detail_screen.dart';
import 'illust_detail_screen.dart';
import 'statistics_screen.dart';
import '../widgets/pixiv_image.dart';
import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';

/// 閲覧履歴画面
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final DatabaseService _databaseService = DatabaseService();

  List<Map<String, dynamic>> _historyList = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await _databaseService.getHistoryList();
      if (mounted) {
        setState(() {
          _historyList = history;
          _isLoading = false;
        });
      }
      // 旧データ（サムネイル・作者名欠損）を一覧読み込み時に一度だけAPI補完する。
      // カードごとの FutureBuilder は使わない。失敗時はプレースホルダのまま残す。
      await _completeLegacyHistory(history);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 欠損メタデータを持つ履歴行のみ API で補完し、DB とメモリ上のリストを更新する。
  ///
  /// 旧実装は行ごとに `await` していたため、10〜20件で 10〜20秒かかっていた。
  /// 並列化（同時実行数を制限）して高速化する。
  Future<void> _completeLegacyHistory(
    List<Map<String, dynamic>> history,
  ) async {
    final targets = history.where((item) {
      final url = item['url'] as String?;
      final author = item['author_name'] as String?;
      return (url == null || url.isEmpty) || (author == null || author.isEmpty);
    }).toList();
    if (targets.isEmpty) return;

    final api = PixivApiService();
    var updated = false;

    // 同時実行数を 4 に制限した並列補完
    const maxConcurrent = 4;
    final List<Future<void>> tasks = [];
    var index = 0;
    Future<void> runNext() async {
      while (index < targets.length) {
        final item = targets[index++];
        final workId = item['work_id'] as int? ?? 0;
        // work_id 不明の行はスキップ（return だと残り全件の補完が止まる）。
        if (workId == 0) continue;
        final type = item['type'] as String? ?? 'illust';
        try {
          String title;
          String authorName;
          String url;
          if (type == 'novel') {
            final novel = await api.getNovelById(workId);
            title = novel.title;
            authorName = novel.author.name;
            url = novel.coverUrl;
          } else {
            final illust = await api.getIllustById(workId);
            title = illust.title;
            authorName = illust.author.name;
            url = illust.urls.preview ?? illust.urls.original ?? '';
          }
          await _databaseService.updateHistoryMeta(
            workId: workId,
            title: title,
            authorName: authorName,
            url: url,
          );
          updated = true;
        } catch (_) {
          // 取得失敗時は既存データを削除せずそのまま残す
        }
      }
      return;
    }

    for (var i = 0; i < maxConcurrent && i < targets.length; i++) {
      tasks.add(runNext());
    }
    await Future.wait(tasks);

    if (updated && mounted) {
      final refreshed = await _databaseService.getHistoryList();
      if (!mounted) return;
      setState(() {
        _historyList = refreshed;
      });
    }
  }

  Future<void> _navigateToDetail(Map<String, dynamic> item) async {
    // history テーブルの実カラム名は 'type'（旧コードは 'work_type' を参照していた）
    final workType = item['type'] ?? 'illust';
    final workId = item['work_id'] ?? 0;
    if (workId == 0) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('この作品のIDを取得できませんでした')));
      }
      return;
    }
    try {
      if (workType == 'novel') {
        // Novel オブジェクトを取得
        final novel = await PixivApiService().getNovelById(workId);
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => NovelDetailScreen(novel: novel),
            ),
          );
        }
      } else {
        // イラスト/マンガ/うごイラ
        final illust = await PixivApiService().getIllustById(workId);
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => IllustDetailScreen(illust: illust),
            ),
          );
        }
      }
    } on RateLimitException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('アクセスが一時的に制限されています。しばらくしてから再度お試しください')),
        );
      }
    } on Exception catch (e) {
      // 真に削除された小説（404/見つかりませんでした）のみ遅延削除。
      // エンドポイント不存在・通信失敗・認証失敗・レート制限等は削除しない。
      final isGone =
          workType == 'novel' &&
          DatabaseService.isGenuineNovelMissing(e.toString());
      if (isGone) {
        await _databaseService.removeInvalidNovel(
          workId,
          errorMessage: e.toString(),
        );
      }
      if (mounted) {
        final label = workType == 'novel' ? '小説' : 'イラスト';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isGone
                  ? '$labelは削除されたか、データが古いため履歴から削除しました'
                  : '$labelの詳細を取得できませんでした',
            ),
          ),
        );
      }
    } catch (e) {
      // その他のエラー時は簡易表示
      if (mounted) {
        final label = workType == 'novel' ? '小説' : 'イラスト';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$labelの詳細を取得できませんでした: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('閲覧履歴'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: '閲覧統計',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const StatisticsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _historyList.isEmpty
          ? const Center(
              child: Text('閲覧履歴はありません', style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8.0),
              itemCount: _historyList.length,
              itemBuilder: (context, index) {
                final item = _historyList[index];
                final thumbUrl = item['url'] as String? ?? '';
                final authorName = item['author_name'] as String? ?? '';
                final workType = item['type'] as String? ?? 'illust';
                final typeLabel = workType == 'novel'
                    ? '小説'
                    : (workType == 'ugoira' ? 'うごイラ' : 'イラスト');
                return Card(
                  color: const Color(0xFF1E1E1E),
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  child: InkWell(
                    onTap: () => _navigateToDetail(item),
                    child: Padding(
                      padding: const EdgeInsets.all(10.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // サムネイル（なければプレースホルダー）
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 64,
                              height: 90,
                              child: thumbUrl.isNotEmpty
                                  ? PixivImage(
                                      url: thumbUrl,
                                      fit: BoxFit.cover,
                                      isThumbnail: true,
                                      cacheWidth:
                                          (64 *
                                                  MediaQuery.devicePixelRatioOf(
                                                    context,
                                                  ))
                                              .round(),
                                      errorWidget: const Icon(
                                        Icons.image,
                                        color: Colors.grey,
                                      ),
                                    )
                                  : Container(
                                      color: Colors.black,
                                      child: const Icon(
                                        Icons.image,
                                        color: Colors.grey,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item['title'] ?? '無題',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  authorName.isNotEmpty ? authorName : '作者不明',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.pinkAccent.withValues(
                                      alpha: 0.18,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    typeLabel,
                                    style: const TextStyle(
                                      color: Colors.pinkAccent,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
