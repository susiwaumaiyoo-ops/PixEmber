import 'package:flutter/material.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import '../services/database_service.dart';
import 'illust_detail_screen.dart';
import 'novel_reader_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final DatabaseService _dbService = DatabaseService();
  final ScrollController _scrollController = ScrollController();
  List<dynamic> _historyItems = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _errorMessage;
  int? _nextOffset;

  @override
  void initState() {
    super.initState();
    _fetchHistory();
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore && _nextOffset != null) {
        _loadMore();
      }
    }
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final items = await _dbService.getHistoryList(limit: 20, offset: 0);
      if (mounted) {
        setState(() {
          _historyItems = items;
          _nextOffset = items.length >= 20 ? 20 : null;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '履歴の取得に失敗しました: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_nextOffset == null) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final newItems = await _dbService.getHistoryList(
        limit: 20,
        offset: _nextOffset!,
      );
      if (mounted) {
        setState(() {
          _historyItems.addAll(newItems);
          _nextOffset = newItems.length >= 20 ? _nextOffset! + 20 : null;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  void _navigateToDetail(Map<String, dynamic> item) {
    final workId = item['work_id'] as int;
    final title = item['title'] as String;
    final authorName = item['author_name'] as String;
    final previewUrl = item['preview_url'] as String;
    final type = item['type'] as String;

    if (type == 'illust') {
      final dummyIllust = Illust(
        id: workId,
        title: title,
        caption: '閲覧履歴から表示しています。',
        author: Author(
          id: 0,
          name: authorName,
          account: 'history_user',
          avatar: '',
        ),
        tags: [],
        urls: IllustUrls(
          preview: previewUrl,
          original: previewUrl,
          rawPreview: previewUrl,
          rawOriginal: previewUrl,
        ),
        pageCount: 1,
        metaPages: [],
        width: 0,
        height: 0,
        totalView: 0,
        totalBookmarks: 0,
        createDate: '',
        type: 'illust',
        isBookmarked: false,
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => IllustDetailScreen(
            illust: dummyIllust,
            onTagTap: (tag) {},
            onBookmarkChanged: (isBookmarked) {},
          ),
        ),
      );
    } else if (type == 'novel') {
      final dummyNovel = Novel(
        id: workId,
        title: title,
        caption: '閲覧履歴から表示しています。',
        author: Author(
          id: 0,
          name: authorName,
          account: 'history_user',
          avatar: '',
        ),
        tags: [],
        coverUrl: previewUrl,
        rawCoverUrl: previewUrl,
        textCount: 0,
        wordCount: 0,
        textLength: 0,
        pageCount: 1,
        createDate: '',
        totalView: 0,
        totalBookmarks: 0,
        isBookmarked: false,
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => NovelReaderScreen(novel: dummyNovel),
        ),
      );
    }
  }

  String _formatDateTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('閲覧履歴'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchHistory,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _fetchHistory,
                    child: const Text('再試行'),
                  ),
                ],
              ),
            )
          : _historyItems.isEmpty
          ? const Center(
              child: Text(
                '閲覧履歴はありません。',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            )
          : ListView.builder(
              controller: _scrollController,
              itemCount: _historyItems.length + (_nextOffset != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _historyItems.length) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16.0),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final item = _historyItems[index];
                final type = item['type'] as String;
                final viewedAt = item['viewed_at'] as int;
                final previewUrl = item['preview_url'] ?? '';

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  elevation: 2,
                  child: ListTile(
                    onTap: () => _navigateToDetail(item),
                    leading: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        image: DecorationImage(
                          image: NetworkImage(previewUrl),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    title: Text(
                      item['title'] ?? '無題',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['author_name'] ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatDateTime(viewedAt),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    trailing: Chip(
                      label: Text(
                        type == 'illust' ? 'イラスト' : '小説',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                      backgroundColor: type == 'illust'
                          ? Colors.blue
                          : Colors.green,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
