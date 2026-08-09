import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import '../services/pixiv_api_service.dart';
import '../widgets/pixiv_image.dart';
import 'novel_detail_screen.dart';

class BookmarkListScreen extends StatefulWidget {
  const BookmarkListScreen({super.key});

  @override
  State<BookmarkListScreen> createState() => _BookmarkListScreenState();
}

class _BookmarkListScreenState extends State<BookmarkListScreen> {
  final PixivApiService _api = PixivApiService();
  List<Novel> _novels = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
  }

  // 保存されたしおりID一覧から実データを取得（オフライン時は保存情報で代用）
  Future<void> _loadBookmarks() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList('novel_bookmark_ids') ?? [];
      final List<Novel> loaded = [];
      for (final idStr in ids) {
        final id = int.tryParse(idStr);
        if (id == null) continue;
        final title = prefs.getString('novel_title_$id') ?? '無題';
        final author = prefs.getString('novel_author_$id') ?? '不明';
        try {
          loaded.add(await _api.getNovelById(id));
        } catch (e) {
          // オフライン/未ログイン等は保存情報のみで表示
          loaded.add(
            Novel(
              id: id,
              title: title,
              caption: '',
              author: Author(id: 0, name: author, account: ''),
              tags: [],
              coverUrl: '',
              createDate: '',
              textCount: 0,
              wordCount: 0,
              textLength: 0,
              pageCount: 0,
              totalBookmarks: 0,
              totalView: 0,
              isBookmarked: false,
            ),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _novels = loaded;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteBookmark(Novel novel) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList('novel_bookmark_ids') ?? [];
      ids.remove(novel.id.toString());
      await prefs.setStringList('novel_bookmark_ids', ids);
      await prefs.remove('novel_progress_${novel.id}');
      await prefs.remove('novel_page_${novel.id}');
      await prefs.remove('novel_offset_${novel.id}');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('しおりを削除しました')));
      _loadBookmarks();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('削除に失敗: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('しおり一覧'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadBookmarks,
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.pinkAccent),
            )
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _novels.isEmpty
          ? const Center(
              child: Text('しおりはありません。', style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8.0),
              itemCount: _novels.length,
              itemBuilder: (context, index) {
                final novel = _novels[index];
                return Card(
                  color: const Color(0xFF1E1E1E),
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  child: ListTile(
                    leading: Container(
                      width: 54,
                      height: 81,
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
                          : const Icon(Icons.book, color: Colors.grey),
                    ),
                    title: Text(
                      novel.title,
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
                        Text(
                          '✍️ ${novel.author.name}',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              '📄 ${novel.pageCount}P  |  '
                              '✍️ ${novel.textLength}文字',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 11,
                              ),
                            ),
                            const Spacer(),
                            _BookmarkProgress(id: novel.id),
                          ],
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.redAccent,
                      ),
                      onPressed: () => _confirmDelete(novel),
                      tooltip: 'しおりを削除',
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => NovelDetailScreen(novel: novel),
                        ),
                      ).then((_) {
                        if (!mounted) return;
                        _loadBookmarks();
                      });
                    },
                  ),
                );
              },
            ),
    );
  }

  Future<void> _confirmDelete(Novel novel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('しおりを削除'),
        content: const Text('このしおり（読書進捗）を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteBookmark(novel);
    }
  }
}

// しおり進捗（パーセント保存値）を表示する軽量ウィジェット
class _BookmarkProgress extends StatelessWidget {
  final int id;
  const _BookmarkProgress({required this.id});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<double?>(
      future: SharedPreferences.getInstance().then(
        (prefs) => prefs.getDouble('novel_progress_$id'),
      ),
      builder: (context, snapshot) {
        final progress = snapshot.data;
        if (progress == null || progress <= 0.0) {
          return const SizedBox.shrink();
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.pink.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bookmark, size: 9, color: Colors.pinkAccent),
              const SizedBox(width: 2),
              Text(
                '${progress.toStringAsFixed(0)}%',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Colors.pinkAccent,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
