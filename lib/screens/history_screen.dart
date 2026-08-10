import 'package:flutter/material.dart';
import 'novel_detail_screen.dart';
import 'illust_detail_screen.dart';
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _navigateToDetail(Map<String, dynamic> item) async {
    final workType = item['work_type'] ?? 'illust';
    final workId = item['work_id'] ?? 0;
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
    } catch (e) {
      // エラー時は簡易表示
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
                final workType = item['work_type'] as String? ?? 'illust';
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
