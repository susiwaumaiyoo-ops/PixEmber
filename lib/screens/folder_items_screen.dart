import 'package:flutter/material.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';
import 'illust_detail_screen.dart';
import 'novel_detail_screen.dart';

class FolderItemsScreen extends StatefulWidget {
  final int folderId;
  final String folderName;

  const FolderItemsScreen({
    super.key,
    required this.folderId,
    required this.folderName,
  });

  @override
  State<FolderItemsScreen> createState() => _FolderItemsScreenState();
}

class _FolderItemsScreenState extends State<FolderItemsScreen> {
  final DatabaseService _dbService = DatabaseService();
  final PixivApiService _pixivApiService = PixivApiService();
  List<dynamic> _items = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchItems();
  }

  Future<void> _fetchItems() async {
    try {
      setState(() => _isLoading = true);
      final items = await _dbService.getFolderItems(folderId: widget.folderId);
      if (mounted) {
        setState(() {
          _items = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _removeItem(int itemId, int workId, String type) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('分類の削除'),
        content: const Text(
          'このフォルダ分類を解除しますか？\n(このフォルダからのみ除外され、本体のブックマークは維持されます)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('解除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    if (!mounted) return;

    try {
      await _dbService.removeFolderItem(
        folderId: widget.folderId,
        workId: workId,
        type: type,
      );
      _fetchItems();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラー: $e')));
      }
    }
  }

  void _onItemTap(dynamic item) async {
    final itemId = item['item_id'];
    final type = item['type'].toString();

    if (type == 'illust') {
      setState(() => _isLoading = true);
      try {
        final result = await _pixivApiService.getRecommend(offset: 0);
        final list = result.items;
        final target = list.where((i) => i.id == itemId).firstOrNull;
        if (target != null) {
          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => IllustDetailScreen(
                illust: target,
                onTagTap: (tag) {},
                onBookmarkChanged: (bookmarked) {
                  _fetchItems();
                },
              ),
            ),
          );
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() => _isLoading = false);
    } else if (type == 'novel') {
      final pseudoNovel = Novel(
        id: itemId,
        title: item['title'] ?? '無題',
        caption: '',
        author: Author(id: 0, name: item['author_name'] ?? '作者', account: ''),
        tags: [],
        coverUrl: item['preview_url'] ?? '',
        pageCount: 1,
        textCount: 0,
        wordCount: 0,
        textLength: 0,
        createDate: '',
        totalView: 0,
        totalBookmarks: 0,
        isBookmarked: true,
      );
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => NovelDetailScreen(
            novel: pseudoNovel,
            onTagTap: (tag) {},
            onBookmarkChanged: (bookmarked) => _fetchItems(),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folderName),
        backgroundColor: Colors.black87,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.pinkAccent),
            )
          : _error != null
          ? Center(
              child: Text(
                'エラー: $_error',
                style: const TextStyle(color: Colors.grey),
              ),
            )
          : _items.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.bookmarks, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'このフォルダには作品が登録されていません。',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '詳細画面でお気に入り（ハート）を長押しして登録できます。',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _items.length,
              itemBuilder: (context, idx) {
                final item = _items[idx];
                return Card(
                  color: const Color(0xFF1E1E1E),
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    leading: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child:
                          item['preview_url'] != null &&
                              item['preview_url'].toString().isNotEmpty
                          ? Image.network(
                              item['preview_url'],
                              fit: BoxFit.cover,
                            )
                          : Icon(
                              item['type'] == 'novel'
                                  ? Icons.book
                                  : Icons.image,
                              color: Colors.grey,
                            ),
                    ),
                    title: Text(
                      item['title'] ?? '無題',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${item['author_name'] ?? '作者'}\n[${item['type'] == 'novel' ? '小説' : 'イラスト'}]',
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.bookmark_remove,
                        color: Colors.redAccent,
                      ),
                      onPressed: () => _removeItem(
                        item['id'],
                        item['work_id'] is int
                            ? item['work_id'] as int
                            : int.tryParse(item['work_id'].toString()) ?? 0,
                        item['type'].toString(),
                      ),
                    ),
                    onTap: () => _onItemTap(item),
                  ),
                );
              },
            ),
    );
  }
}
