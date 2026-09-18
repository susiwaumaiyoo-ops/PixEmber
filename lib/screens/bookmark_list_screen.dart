import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import '../services/pixiv_api_service.dart';
import '../services/database_service.dart';
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
      final db = DatabaseService();
      final List<Novel> loaded = [];
      for (final idStr in ids) {
        final id = int.tryParse(idStr);
        if (id == null) continue;

        // 1. DB に完全な Novel スナップショットがあればそれを使う（API 不要）
        final cached = await db.getNovelMeta(id);
        if (cached != null) {
          loaded.add(cached);
          continue;
        }

        // 2. 旧データ（メタ欠損）は一覧読み込み時に一度だけ API 補完して永続化する
        try {
          final novel = await _api.getNovelById(id);
          await db.saveNovel(novel);
          await prefs.setString('novel_title_$id', novel.title);
          await prefs.setString('novel_author_$id', novel.author.name);
          await prefs.setString('novel_cover_$id', novel.coverUrl);
          await prefs.setInt('novel_page_count_$id', novel.pageCount);
          await prefs.setInt('novel_text_length_$id', novel.textLength);
          loaded.add(novel);
        } catch (e) {
          // 3. 取得失敗時は削除せず、保存済み情報のみのプレースホルダを表示
          loaded.add(
            Novel(
              id: id,
              title: prefs.getString('novel_title_$id') ?? '無題',
              caption: '',
              author: Author(
                id: 0,
                name: prefs.getString('novel_author_$id') ?? '不明',
                account: '',
              ),
              tags: [],
              coverUrl: prefs.getString('novel_cover_$id') ?? '',
              createDate: '',
              textCount: prefs.getInt('novel_text_length_$id') ?? 0,
              wordCount: 0,
              textLength: prefs.getInt('novel_text_length_$id') ?? 0,
              pageCount: prefs.getInt('novel_page_count_$id') ?? 0,
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
    final colorScheme = Theme.of(context).colorScheme;
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
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _novels.isEmpty
          ? Center(
              child: Text(
                'しおりはありません。',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8.0),
              itemCount: _novels.length,
              itemBuilder: (context, index) {
                final novel = _novels[index];
                return Card(
                  color: colorScheme.surfaceContainerHigh,
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  child: ListTile(
                    leading: Container(
                      width: 54,
                      height: 81,
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: novel.coverUrl.isNotEmpty
                          ? PixivImage(
                              url: novel.coverUrl,
                              fit: BoxFit.cover,
                              isThumbnail: true,
                            )
                          : Icon(
                              Icons.book,
                              color: colorScheme.onSurfaceVariant,
                            ),
                    ),
                    title: Text(
                      novel.title,
                      style: TextStyle(
                        color: colorScheme.onSurface,
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
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              '📄 ${novel.pageCount}P  |  '
                              '✍️ ${novel.textLength}文字',
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
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
                      icon: Icon(
                        Icons.delete_outline,
                        color: colorScheme.error,
                      ),
                      onPressed: () => _confirmDelete(novel),
                      tooltip: 'しおりを削除',
                    ),
                    onTap: () async {
                      // タップ時に最新の完全メタデータを取得して検証する。
                      // 404（削除済み/データが古い）の場合は一覧から遅延削除して通知。
                      final id = novel.id;
                      if (id <= 0) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('この作品のIDを取得できませんでした')),
                        );
                        return;
                      }
                      final scaffold = ScaffoldMessenger.of(context);
                      Novel? fullNovel;
                      try {
                        fullNovel = await _api.getNovelById(id);
                        await DatabaseService().saveNovel(fullNovel);
                      } on RateLimitException {
                        if (!mounted) return;
                        scaffold.showSnackBar(
                          const SnackBar(
                            content: Text(
                              'アクセスが一時的に制限されています。しばらくしてから再度お試しください',
                            ),
                          ),
                        );
                        return;
                      } on Exception catch (e) {
                        // 真に削除された小説（404/見つかりませんでした）のみ一覧から削除。
                        final isGone =
                            DatabaseServiceIntegrity.isGenuineNovelMissing(
                              e.toString(),
                            );
                        if (isGone) {
                          await DatabaseService().removeInvalidNovel(
                            id,
                            errorMessage: e.toString(),
                          );
                          _novels.removeWhere((n) => n.id == id);
                        }
                        if (!mounted) return;
                        scaffold.showSnackBar(
                          SnackBar(
                            content: Text(
                              isGone
                                  ? 'この小説は削除されたか、データが古いため一覧から削除しました'
                                  : '作品情報の取得に失敗しました。通信状況を確認してください',
                            ),
                          ),
                        );
                        return;
                      } catch (e) {
                        if (!mounted) return;
                        scaffold.showSnackBar(
                          SnackBar(content: Text('作品情報の取得に失敗しました: $e')),
                        );
                        return;
                      }
                      if (!mounted) return;
                      final ctx = context;
                      if (!ctx.mounted) return;
                      await Navigator.push(
                        ctx,
                        MaterialPageRoute(
                          builder: (context) =>
                              NovelDetailScreen(novel: fullNovel!),
                        ),
                      );
                      if (!mounted) return;
                      _loadBookmarks();
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
    final colorScheme = Theme.of(context).colorScheme;
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
            color: colorScheme.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bookmark, size: 9, color: colorScheme.primary),
              const SizedBox(width: 2),
              Text(
                '${progress.toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
