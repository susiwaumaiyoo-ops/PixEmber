import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart' as palette_generator;
import '../illust_model.dart';
import '../widgets/ugoira_player.dart';
import '../widgets/zoomable_image.dart';
import '../widgets/folder_selection_bottom_sheet.dart';
import 'author_profile_screen.dart';
import 'full_screen_image_page.dart';

import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';
import '../widgets/pixiv_image.dart';

class IllustDetailScreen extends StatefulWidget {
  final Illust illust;
  final ValueChanged<String>? onTagTap;
  final ValueChanged<bool>? onBookmarkChanged;

  const IllustDetailScreen({
    super.key,
    required this.illust,
    this.onTagTap,
    this.onBookmarkChanged,
  });

  @override
  State<IllustDetailScreen> createState() => _IllustDetailScreenState();
}

class _IllustDetailScreenState extends State<IllustDetailScreen> {
  late bool _isBookmarked;
  int _bookmarkCountOffset = 0;
  bool _isToggling = false;

  List<Illust> _relatedIllusts = [];
  bool _isLoadingRelated = true;
  bool _hasRelatedError = false;

  palette_generator.PaletteGenerator? _paletteGenerator;
  bool _isZooming = false;
  int _currentPage = 0; // 複数枚イラストの現在ページ（0始まり）。ページ数表示バグ修正用

  final String host = ''; // ローカルAPI結合のため空文字ダミーで保持

  @override
  void initState() {
    super.initState();
    _isBookmarked = widget.illust.isBookmarked;
    _fetchRelatedIllusts();
    _recordHistory();
    _generatePalette();
  }

  Future<void> _generatePalette() async {
    final previewUrl = widget.illust.urls.preview;
    if (previewUrl == null || previewUrl.isEmpty) return;
    try {
      final palette =
          await palette_generator.PaletteGenerator.fromImageProvider(
            NetworkImage(previewUrl),
            maximumColorCount: 10,
          ).timeout(const Duration(seconds: 5));
      if (mounted) {
        setState(() {
          _paletteGenerator = palette;
        });
      }
    } catch (e) {
      debugPrint('パレット抽出に失敗しました: $e');
    }
  }

  Future<void> _recordHistory() async {
    try {
      final db = DatabaseService();
      await db.insertOrUpdateHistory(
        workId: widget.illust.id,
        title: widget.illust.title,
        authorName: widget.illust.author.name,
        previewUrl: widget.illust.urls.preview ?? '',
        type: 'illust',
      );
    } catch (e) {
      debugPrint('閲覧履歴の追加に失敗しました: $e');
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
                  await db.addSubscribedTag(tag, 'illust');
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

  Future<void> _fetchRelatedIllusts() async {
    try {
      final api = PixivApiService();
      final results = await api.getIllustRelated(widget.illust.id);
      if (mounted) {
        setState(() {
          _relatedIllusts = results;
          _isLoadingRelated = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingRelated = false;
          _hasRelatedError = true;
        });
      }
    }
  }

  Future<void> _toggleBookmark() async {
    if (_isToggling) return;
    setState(() => _isToggling = true);

    final toAdd = !_isBookmarked;
    final api = PixivApiService();
    final success = await api.toggleBookmark(widget.illust.id, false, toAdd);

    if (!mounted) return;

    if (success) {
      setState(() {
        _isBookmarked = toAdd;
        _bookmarkCountOffset += toAdd ? 1 : -1;
        if (widget.onBookmarkChanged != null) {
          widget.onBookmarkChanged!(toAdd);
        }
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
    setState(() => _isToggling = false);
  }

  Future<void> _muteAuthor() async {
    try {
      final db = DatabaseService();
      await db.insertOrUpdateMute(
        muteType: 'user',
        value: widget.illust.author.id.toString(),
        label: widget.illust.author.name,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${widget.illust.author.name} さんをミュートしました。'),
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
    final images = widget.illust.metaPages.isNotEmpty
        ? widget.illust.metaPages
        : [
            PageImage(
              page: 1,
              preview: widget.illust.urls.preview,
              original: widget.illust.urls.original,
            ),
          ];

    final Color dominantColor =
        _paletteGenerator?.dominantColor?.color ??
        _paletteGenerator?.vibrantColor?.color ??
        const Color(0xFF1E1E1E);

    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth > 700;
    final isLargeScreenForImage = screenWidth > 600;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.illust.title),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        actions: [
          GestureDetector(
            onLongPress: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: Colors.transparent,
                isScrollControlled: true,
                builder: (context) => FolderSelectionBottomSheet(
                  itemId: widget.illust.id,
                  type: 'illust',
                  title: widget.illust.title,
                  authorName: widget.illust.author.name,
                  previewUrl: widget.illust.urls.preview ?? '',
                ),
              );
            },
            child: IconButton(
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
              tooltip: 'ブックマーク (長押しでフォルダ分類)',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.fullscreen),
            tooltip: '全画面表示',
            onPressed: () {
              final fullImages = widget.illust.metaPages.isNotEmpty
                  ? widget.illust.metaPages
                  : [
                      PageImage(
                        page: 1,
                        preview: widget.illust.urls.preview,
                        original: widget.illust.urls.original,
                      ),
                    ];
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => FullScreenImagePage(
                    images: fullImages,
                    initialIndex: _currentPage,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 800),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [dominantColor.withValues(alpha: 0.7), Colors.black],
            stops: const [0.0, 0.6],
          ),
        ),
        child: SafeArea(
          top: false,
          child: isTablet
              ? Row(
                  children: [
                    // 左ペイン (幅60% 固定エリア、スクロールなし)
                    Expanded(
                      flex: 6,
                      child: Container(
                        color: Colors.black26,
                        child: Stack(
                          children: [
                            if (widget.illust.type == 'ugoira')
                              Center(
                                child: UgoiraPlayer(illustId: widget.illust.id),
                              )
                            else if (images.length == 1)
                              Center(
                                child: ZoomableImage(
                                  url:
                                      images[0].original ??
                                      widget.illust.urls.original ??
                                      '',
                                  isLargeScreen: true,
                                  maxHeight: double.infinity,
                                ),
                              )
                            else
                              PageView.builder(
                                physics: _isZooming
                                    ? const NeverScrollableScrollPhysics()
                                    : const ClampingScrollPhysics(),
                                itemCount: images.length,
                                onPageChanged: (index) {
                                  setState(() {
                                    _currentPage = index;
                                  });
                                },
                                itemBuilder: (context, idx) {
                                  final pageImg = images[idx];
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Center(
                                        child: ZoomableImage(
                                          url: pageImg.original ?? '',
                                          isLargeScreen: true,
                                          maxHeight: double.infinity,
                                          onZoomChanged: (zooming) {
                                            setState(() {
                                              _isZooming = zooming;
                                            });
                                          },
                                        ),
                                      ),
                                      Positioned(
                                        top: kToolbarHeight + 10,
                                        right: 16,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(
                                              alpha: 0.7,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Text(
                                            '${_currentPage + 1} / ${images.length}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                    // 右ペイン (幅40% 縦スクロール可能)
                    Expanded(
                      flex: 4,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.3),
                          border: const Border(
                            left: BorderSide(color: Colors.white10, width: 0.5),
                          ),
                        ),
                        child: SingleChildScrollView(
                          padding: EdgeInsets.only(
                            top: MediaQuery.of(context).padding.top + 20,
                            left: 16,
                            right: 16,
                            bottom: 16,
                          ),
                          child: _buildMetaDetails(context, screenWidth, host),
                        ),
                      ),
                    ),
                  ],
                )
              : SingleChildScrollView(
                  physics: _isZooming
                      ? const NeverScrollableScrollPhysics()
                      : const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. 画像縦並び表示 (スマホ表示時、InteractiveViewer)
                      Builder(
                        builder: (context) {
                          // うごイラの場合、再生プレイヤーを表示
                          if (widget.illust.type == 'ugoira') {
                            return Padding(
                              padding: const EdgeInsets.only(
                                top: kToolbarHeight + 30,
                                bottom: 12,
                              ),
                              child: Center(
                                child: Container(
                                  constraints: BoxConstraints(
                                    maxWidth: isLargeScreenForImage
                                        ? 600
                                        : double.infinity,
                                  ),
                                  child: UgoiraPlayer(
                                    illustId: widget.illust.id,
                                  ),
                                ),
                              ),
                            );
                          }

                          // 通常のイラスト/マンガの場合
                          final screenHeight = MediaQuery.of(
                            context,
                          ).size.height;
                          final maxHeight = screenHeight * 0.7;

                          return ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: images.length,
                            itemBuilder: (context, idx) {
                              final pageImg = images[idx];
                              final originalUrl = pageImg.original;

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4.0,
                                ),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    const Center(
                                      child: CircularProgressIndicator(
                                        color: Colors.pinkAccent,
                                      ),
                                    ),
                                    if (originalUrl != null)
                                      ZoomableImage(
                                        url: originalUrl,
                                        isLargeScreen: isLargeScreenForImage,
                                        maxHeight: maxHeight,
                                        onZoomChanged: (zooming) {
                                          setState(() {
                                            _isZooming = zooming;
                                          });
                                        },
                                      ),
                                    if (images.length > 1)
                                      Positioned(
                                        top: 8,
                                        right: 8,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(
                                              alpha: 0.7,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Text(
                                            '${idx + 1} / ${images.length}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),

                      // 2. 詳細メタ情報エリア (スマホ表示用)
                      Container(
                        color: Colors.black.withValues(alpha: 0.5),
                        padding: const EdgeInsets.all(16.0),
                        child: _buildMetaDetails(context, screenWidth, host),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  // メタ情報エリアの共通切り出し
  Widget _buildMetaDetails(
    BuildContext context,
    double screenWidth,
    String host,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.illust.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),

        // 作者情報
        InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    AuthorProfileScreen(userId: widget.illust.author.id),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.transparent,
                  child: ClipOval(
                    child: widget.illust.author.avatar != null
                        ? PixivImage(
                            url: widget.illust.author.avatar!,
                            fit: BoxFit.cover,
                            width: 40,
                            height: 40,
                            errorWidget: const Icon(
                              Icons.person,
                              color: Colors.grey,
                            ),
                          )
                        : const Icon(Icons.person, color: Colors.grey),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.illust.author.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '@${widget.illust.author.account}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: const Color(0xFF1C1C1C),
                        title: const Text(
                          '作者をミュート',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                        content: Text(
                          '${widget.illust.author.name} さんをミュートしますか？\n今後この作者の作品は検索結果やおすすめに表示されなくなります。',
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
                    'ミュート',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(color: Colors.grey, height: 24),

        // 閲覧数とブックマーク数
        Row(
          children: [
            const Icon(
              Icons.remove_red_eye_outlined,
              size: 16,
              color: Colors.grey,
            ),
            const SizedBox(width: 4),
            Text(
              '${widget.illust.totalView}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(width: 16),
            const Icon(Icons.favorite, size: 16, color: Colors.pinkAccent),
            const SizedBox(width: 4),
            Text(
              '${widget.illust.totalBookmarks + _bookmarkCountOffset}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Spacer(),
            Text(
              _formatDate(widget.illust.createDate),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // キャプション
        if (widget.illust.caption.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF222222),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _cleanHTML(widget.illust.caption),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // タグリスト
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
          children: widget.illust.tags.map((tag) {
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
                side: const BorderSide(color: Colors.pinkAccent, width: 0.5),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              ),
            );
          }).toList(),
        ),
        const Divider(color: Colors.grey, height: 32),

        // 3. 関連作品セクション
        const Row(
          children: [
            Icon(Icons.auto_awesome, color: Colors.pinkAccent, size: 18),
            SizedBox(width: 8),
            Text(
              '関連作品 (無限ディグり)',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildRelatedSection(),
      ],
    );
  }

  // 関連作品セクションのビルド
  Widget _buildRelatedSection() {
    if (_isLoadingRelated) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: CircularProgressIndicator(color: Colors.pinkAccent),
        ),
      );
    }

    if (_hasRelatedError) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: Text(
            '関連作品の読み込みに失敗しました。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      );
    }

    if (_relatedIllusts.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: Text(
            '関連作品がありません。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      );
    }

    return SizedBox(
      height: 150,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _relatedIllusts.length,
        itemBuilder: (context, index) {
          final relIllust = _relatedIllusts[index];
          final previewUrl = relIllust.urls.preview;

          return Container(
            width: 110,
            margin: const EdgeInsets.only(right: 12.0),
            child: Card(
              color: const Color(0xFF222222),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: InkWell(
                onTap: () async {
                  // 無限に関連作品に遷移 (Push)
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => IllustDetailScreen(
                        illust: relIllust,
                        onTagTap: widget.onTagTap,
                        onBookmarkChanged: (newVal) {
                          setState(() {
                            relIllust.isBookmarked = newVal;
                          });
                        },
                      ),
                    ),
                  );
                  // 戻ってきたら再描画
                  if (!mounted) return;
                  setState(() {});
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: previewUrl != null
                          ? PixivImage(
                              url: previewUrl,
                              fit: BoxFit.cover,
                              isThumbnail: true,
                              errorWidget: const Icon(
                                Icons.broken_image,
                                color: Colors.grey,
                              ),
                            )
                          : const Icon(Icons.image, color: Colors.grey),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Text(
                        relIllust.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
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
