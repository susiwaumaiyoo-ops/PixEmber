import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../novel_model.dart';
import 'author_profile_screen.dart';
import 'novel_reader_screen.dart';
import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';
import '../widgets/pixiv_image.dart';

class NovelDetailScreen extends StatefulWidget {
  final Novel novel;
  final ValueChanged<String>? onTagTap;
  final ValueChanged<bool>? onBookmarkChanged;

  const NovelDetailScreen({
    super.key,
    required this.novel,
    this.onTagTap,
    this.onBookmarkChanged,
  });

  @override
  State<NovelDetailScreen> createState() => _NovelDetailScreenState();
}

class _NovelDetailScreenState extends State<NovelDetailScreen> {
  late bool _isBookmarked;
  int _bookmarkCountOffset = 0;
  bool _isToggling = false;
  double? _readingProgress;

  @override
  void initState() {
    print('📍 [DEBUG Detail] initState 開始: ${widget.novel.title}');
    super.initState();
    _isBookmarked = widget.novel.isBookmarked;
    _loadReadingProgress();
    _recordHistory();
    print('📍 [DEBUG Detail] initState 終了');
  }

  Future<void> _recordHistory() async {
    print('📍 [DEBUG Detail] _recordHistory 開始 (SQLite書き込み前)');
    try {
      final db = DatabaseService();
      await db.insertOrUpdateHistory(
        workId: widget.novel.id,
        title: widget.novel.title,
        authorName: widget.novel.author.name,
        previewUrl: widget.novel.coverUrl,
        type: 'novel',
      );
      print('📍 [DEBUG Detail] _recordHistory 終了 (SQLite書き込み成功)');
    } catch (e) {
      print("⚠️ [History Save Error] 履歴の保存に失敗しました（処理は続行します）: $e");
    }
  }

  // 購読（サブスクリプション）ダイアログを表示し登録を行う
  void _showSubscriptionDialog(String tag) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF222222),
          title: Text(
            'タグ「$tag」の購読登録',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'このタグを購読登録しますか？\n登録すると、ローカルデータベースに保存され、バックグラウンド同期や新着チェックの対象になります。',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  final db = DatabaseService();
                  await db.addSubscribedTag(tag, 'novel');
                  _showSuccessSnackBar('「$tag」を購読登録しました！');
                } catch (e) {
                  _showErrorSnackBar('購読登録に失敗しました: $e');
                }
              },
              child: const Text(
                '購読する',
                style: TextStyle(
                  color: Colors.pinkAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showSuccessSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green.shade800,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _loadReadingProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final progress = prefs.getDouble('novel_progress_${widget.novel.id}');
      if (progress != null && progress > 0.0) {
        if (!mounted) return;
        setState(() {
          _readingProgress = progress;
        });
      }
    } catch (e) {
      debugPrint('進捗の取得に失敗しました: $e');
    }
  }

  /// しおり（読書進捗）削除の確認ダイアログを表示
  Future<void> _confirmDeleteBookmark() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('しおりを削除'),
        content: const Text('保存されている読書進捗（しおり）を削除しますか？'),
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
    if (confirmed == true && mounted) {
      await _deleteBookmark();
    }
  }

  /// しおり関連の SharedPreferences キーをすべて削除する
  Future<void> _deleteBookmark() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('novel_progress_${widget.novel.id}');
      await prefs.remove('novel_page_${widget.novel.id}');
      await prefs.remove('novel_offset_${widget.novel.id}');
      if (!mounted) return;
      setState(() {
        _readingProgress = null;
      });
    } catch (e) {
      debugPrint('しおりの削除に失敗しました: $e');
    }
  }

  Future<void> _toggleBookmark() async {
    if (_isToggling) return;
    setState(() => _isToggling = true);

    final toAdd = !_isBookmarked;
    final api = PixivApiService();
    final success = await api.toggleBookmark(widget.novel.id, true, toAdd);

    if (!mounted) return;

    if (success) {
      setState(() {
        _isBookmarked = toAdd;
        _bookmarkCountOffset += toAdd ? 1 : -1;
        widget.onBookmarkChanged?.call(toAdd);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(toAdd ? 'ブックマークに追加しました' : 'ブックマークを解除しました'),
          duration: const Duration(seconds: 1),
        ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('通信に失敗しました。再度お試しください。')));
    }
    if (!mounted) return;
    setState(() => _isToggling = false);
  }

  Future<void> _muteAuthor() async {
    try {
      final db = DatabaseService();
      await db.insertOrUpdateMute(
        muteType: 'user',
        value: widget.novel.author.id.toString(),
        label: widget.novel.author.name,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${widget.novel.author.name} さんをミュートしました。'),
          duration: const Duration(seconds: 2),
        ),
      );
      Navigator.pop(context, true); // ミュート成功として前の画面に戻り再ロードを促す
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラーが発生しました: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    print('📍 [DEBUG Detail] build 開始');
    final String caption = widget.novel.caption;
    final Widget result = Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('小説詳細'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: _isToggling
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.pinkAccent,
                    ),
                  )
                : Icon(
                    _isBookmarked ? Icons.favorite : Icons.favorite_border,
                    color: _isBookmarked ? Colors.pinkAccent : Colors.white,
                  ),
            onPressed: _toggleBookmark,
            tooltip: 'ブックマーク',
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 1. 小説カバーと簡易紹介
            Container(
              padding: const EdgeInsets.all(20.0),
              color: const Color(0xFF1E1E1E),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 90,
                    height: 125,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: widget.novel.coverUrl.isNotEmpty
                        ? PixivImage(
                            url: widget.novel.coverUrl,
                            fit: BoxFit.cover,
                            isThumbnail: true,
                            errorWidget: const Icon(
                              Icons.book,
                              size: 40,
                              color: Colors.grey,
                            ),
                          )
                        : const Icon(Icons.book, size: 40, color: Colors.grey),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.novel.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => AuthorProfileScreen(
                                  userId: widget.novel.author.id,
                                ),
                              ),
                            );
                          },
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 12,
                                backgroundImage:
                                    widget.novel.author.avatar != null &&
                                            widget.novel.author.avatar!.isNotEmpty
                                        ? NetworkImage(
                                            widget.novel.author.avatar!,
                                            headers: const {
                                              'Referer': 'https://app-api.pixiv.net/',
                                            },
                                          )
                                        : null,
                                child: (widget.novel.author.avatar == null ||
                                        widget.novel.author.avatar!.isEmpty)
                                    ? const Icon(Icons.person, size: 12)
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.novel.author.name,
                                  style: const TextStyle(
                                    color: Colors.pinkAccent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '📄 ${widget.novel.pageCount}P  |  ✍️ ${widget.novel.textLength}文字',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        if (_readingProgress != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(
                                Icons.bookmark_added,
                                size: 14,
                                color: Colors.green,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '読書進捗: ${((_readingProgress ?? 0.0) * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(
                                  color: Colors.green,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 16,
                                  color: Colors.grey,
                                ),
                                tooltip: 'しおりを削除',
                                onPressed: () => _confirmDeleteBookmark(),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: () async {
                            final res = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    NovelReaderScreen(novel: widget.novel),
                              ),
                            );
                            if (!mounted) return;
                            if (res == true) {
                              _loadReadingProgress();
                            }
                          },
                          icon: const Icon(Icons.chrome_reader_mode, size: 16),
                          label: Text(
                            _readingProgress != null ? '続きから読む' : '小説を読む',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.pinkAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 2. 詳細メタ情報
            Container(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ミュートボタン
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: const Color(0xFF1C1C1C),
                              title: const Text(
                                '作者をミュート',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                              content: Text(
                                '${widget.novel.author.name} さんをミュートしますか？\n今後この作者の作品は表示されなくなります。',
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 13,
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text(
                                    'キャンセル',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _muteAuthor();
                                  },
                                  child: const Text(
                                    'ミュートする',
                                    style: TextStyle(color: Colors.redAccent),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(
                          Icons.block,
                          size: 14,
                          color: Colors.redAccent,
                        ),
                        label: const Text(
                          '作者をミュート',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.redAccent.withValues(
                            alpha: 0.1,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // あらすじ
                  if (caption.isNotEmpty) ...[
                    const Text(
                      '📖 あらすじ',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _cleanHTML(caption),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // 統計情報
                  Row(
                    children: [
                      const Icon(
                        Icons.remove_red_eye_outlined,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.novel.totalView}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Icon(
                        Icons.favorite,
                        size: 16,
                        color: Colors.pinkAccent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.novel.totalBookmarks + _bookmarkCountOffset}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatDate(widget.novel.createDate),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.grey, height: 32),

                  // タグ
                  const Text(
                    '🏷️ タグ一覧 (タップで検索 / 長押しで自動同期・購読登録)',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8.0,
                    runSpacing: 4.0,
                    children: widget.novel.tags.map((tag) {
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          widget.onTagTap?.call(tag);
                        },
                        onLongPress: () {
                          _showSubscriptionDialog(tag);
                        },
                        child: Chip(
                          label: Text(
                            tag,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.pinkAccent,
                            ),
                          ),
                          backgroundColor: Colors.pink.withValues(alpha: 0.1),
                          side: const BorderSide(
                            color: Colors.pinkAccent,
                            width: 0.5,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    print('📍 [DEBUG Detail] build 終了');
    return result;
  }

  String _cleanHTML(String htmlString) {
    return htmlString.replaceAll(RegExp(r'<[^>]*>'), '');
  }

  String _formatDate(String isoDate) {
    try {
      final dateTime = DateTime.parse(isoDate);
      return '${dateTime.year}/${dateTime.month.toString().padLeft(2, '0')}/${dateTime.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return isoDate;
    }
  }
}
