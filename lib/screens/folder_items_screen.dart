import 'package:flutter/material.dart';
import '../theme/app_spacing.dart';
import '../widgets/design_system/app_state_view.dart';
import '../widgets/pixiv_image.dart';
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
    final colorScheme = Theme.of(context).colorScheme;
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
            style: ElevatedButton.styleFrom(backgroundColor: colorScheme.error),
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
    final itemId = item['work_id'] is int
        ? item['work_id'] as int
        : int.tryParse(item['work_id']?.toString() ?? '') ?? 0;
    final type = item['type'].toString();

    if (type == 'illust') {
      setState(() => _isLoading = true);
      try {
        final target = await _pixivApiService.getIllustById(itemId);
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
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.folderName)),
      body: _isLoading
          ? const AppStateView(type: AppStateViewType.loading)
          : _error != null
          ? AppStateView(type: AppStateViewType.error, message: 'エラー: $_error')
          : _items.isEmpty
          ? const AppStateView(
              type: AppStateViewType.empty,
              icon: Icons.bookmarks,
              title: 'このフォルダには作品が登録されていません。',
              message: '詳細画面でお気に入り（ハート）を長押しして登録できます。',
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              itemCount: _items.length,
              itemBuilder: (context, idx) {
                final item = _items[idx];
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  child: ListTile(
                    leading: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child:
                          item['preview_url'] != null &&
                              item['preview_url'].toString().isNotEmpty
                          ? PixivImage(
                              url: item['preview_url'].toString(),
                              fit: BoxFit.cover,
                              isThumbnail: true,
                              errorWidget: Icon(
                                Icons.broken_image,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            )
                          : Icon(
                              item['type'] == 'novel'
                                  ? Icons.book
                                  : Icons.image,
                              color: colorScheme.onSurfaceVariant,
                            ),
                    ),
                    title: Text(
                      item['title'] ?? '無題',
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${item['author_name'] ?? '作者'}\n[${item['type'] == 'novel' ? '小説' : 'イラスト'}]',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.bookmark_remove,
                        color: colorScheme.error,
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
