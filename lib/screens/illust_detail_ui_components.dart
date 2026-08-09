import 'package:flutter/material.dart';
import '../illust_model.dart';
import '../widgets/ugoira_player.dart';
import '../widgets/zoomable_image.dart';
import '../widgets/folder_selection_bottom_sheet.dart';
import 'author_profile_screen.dart';
import 'full_screen_image_page.dart';
import 'illust_detail_state.dart';

class IllustDetailUIComponents {
  // ==========================================
  // メインビルド
  // ==========================================

  Widget build(BuildContext context, IllustDetailState state) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          state.illust.title,
          style: const TextStyle(color: Colors.white),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_border, color: Colors.white),
            onPressed: () => state.handler.toggleBookmark(state),
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined, color: Colors.white),
            onPressed: () => state.handler.downloadIllust(state),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: () => _showMoreOptions(context, state),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => _openFullScreenImage(context, state),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 画像ビューア
              _buildImageViewer(context, state, screenWidth),
              // メタ情報エリア
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: _buildMetaDetails(context, screenWidth, state),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================
  // 画像ビューア
  // ==========================================

  Widget _buildImageViewer(
    BuildContext context,
    IllustDetailState state,
    double screenWidth,
  ) {
    if (state.illust.type == 'ugoira') {
      return SizedBox(
        height: 300,
        child: UgoiraPlayer(illustId: state.illust.id),
      );
    }

    return SizedBox(
      height: 300,
      child: ZoomableImage(
        url: state.illust.urls.original ?? '',
        isLargeScreen: screenWidth > 900,
        maxHeight: 300,
      ),
    );
  }

  // ==========================================
  // メタ情報エリア
  // ==========================================

  Widget _buildMetaDetails(
    BuildContext context,
    double screenWidth,
    IllustDetailState state,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          state.illust.title,
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
                    AuthorProfileScreen(userId: state.illust.author.id),
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
                    child: state.illust.author.avatar != null
                        ? Image.network(
                            state.illust.author.avatar!,
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.illust.author.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${state.illust.totalBookmarks} ブックマーク',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.volume_off, color: Colors.grey),
                  onPressed: () => state.handler.muteAuthor(state),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),

        // タグ
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: state.illust.tags.map((tag) {
            return InkWell(
              onTap: () => state.onTagTap?.call(tag),
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

        // 関連作品セクション
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
        _buildRelatedSection(state),
      ],
    );
  }

  // ==========================================
  // 関連作品セクション
  // ==========================================

  Widget _buildRelatedSection(IllustDetailState state) {
    if (state.isLoadingRelated) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: CircularProgressIndicator(color: Colors.pinkAccent),
        ),
      );
    }

    if (state.hasRelatedError) {
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

    if (state.relatedIllusts.isEmpty) {
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
        itemCount: state.relatedIllusts.length,
        itemBuilder: (context, index) {
          final relIllust = state.relatedIllusts[index];
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
                        onTagTap: state.onTagTap,
                        onBookmarkChanged: state.onBookmarkChanged,
                      ),
                    ),
                  );
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (previewUrl != null)
                      Image.network(
                        previewUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: Colors.grey[800],
                            child: const Icon(
                              Icons.broken_image,
                              color: Colors.grey,
                            ),
                          );
                        },
                      )
                    else
                      Container(
                        color: Colors.grey[800],
                        child: const Icon(
                          Icons.broken_image,
                          color: Colors.grey,
                        ),
                      ),
                    if (previewUrl != null)
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.7),
                            ],
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

  // ==========================================
  // ヘルパーメソッド
  // ==========================================

  void _showMoreOptions(BuildContext context, IllustDetailState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF222222),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.folder, color: Colors.white),
                title: const Text(
                  'フォルダに追加',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showFolderSelectionBottomSheet(context, state);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share, color: Colors.white),
                title: const Text('共有', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  // TODO: 共有機能実装
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline, color: Colors.white),
                title: const Text('情報', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  // TODO: 情報表示機能実装
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFolderSelectionBottomSheet(
    BuildContext context,
    IllustDetailState state,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF222222),
      builder: (context) {
        return SafeArea(
          child: FolderSelectionBottomSheet(
            itemId: state.illust.id,
            title: state.illust.title,
            authorName: state.illust.author.name,
            previewUrl: state.illust.urls.preview ?? '',
            type: 'illust',
          ),
        );
      },
    );
  }

  void _openFullScreenImage(BuildContext context, IllustDetailState state) {
    final List<PageImage> images = [];
    if (state.illust.pageCount > 1 && state.illust.metaPages.isNotEmpty) {
      images.addAll(state.illust.metaPages);
    } else {
      images.add(
        PageImage(
          page: 1,
          preview: state.illust.urls.preview,
          original: state.illust.urls.original,
          rawPreview: state.illust.urls.rawPreview,
          rawOriginal: state.illust.urls.rawOriginal,
        ),
      );
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            FullScreenImagePage(images: images, initialIndex: 0),
      ),
    );
  }
}
