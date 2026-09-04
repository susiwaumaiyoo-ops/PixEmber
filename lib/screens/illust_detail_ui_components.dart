import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import '../services/similar_works_service.dart';
import '../utils/datetime_format.dart';
import '../widgets/pixiv_image.dart';
import '../widgets/ugoira_player.dart';
import '../widgets/zoomable_image.dart';
import '../widgets/folder_selection_bottom_sheet.dart';
import 'author_profile_screen.dart';
import 'full_screen_image_page.dart';
import 'illust_detail_state.dart';
import 'novel_detail_screen.dart';

const double kTabletBreakpoint = 600.0;

class IllustDetailUIComponents {
  // ==========================================
  // メインビルド
  // ==========================================

  Widget build(BuildContext context, IllustDetailState state) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= kTabletBreakpoint;
    if (isTablet) {
      return _buildTabletLayout(context, state);
    }
    return _buildPhoneLayout(context, state);
  }

  // スマホレイアウト（従来の縦積みUIを維持）
  Widget _buildPhoneLayout(BuildContext context, IllustDetailState state) {
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
            icon: Icon(
              state.isBookmarked ? Icons.bookmark : Icons.bookmark_border,
              color: Colors.white,
            ),
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

  // タブレットレイアウト（幅 > kTabletBreakpoint: 左右分割）
  // タブレットレイアウト（幅 > kTabletBreakpoint: 左右分割）
  Widget _buildTabletLayout(BuildContext context, IllustDetailState state) {
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
            icon: Icon(
              state.isBookmarked ? Icons.bookmark : Icons.bookmark_border,
              color: Colors.white,
            ),
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
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左ペイン (flex:6) 画像専用
          Expanded(
            flex: 6,
            child: Container(
              color: Colors.black26,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return _buildTabletImageViewer(
                    context,
                    state,
                    constraints.maxHeight,
                    constraints.maxWidth,
                  );
                },
              ),
            ),
          ),
          // ペイン間の区切り線 (1px)
          Container(width: 1, color: Colors.white.withValues(alpha: 0.1)),
          // 右ペイン (flex:4) 縦スクロール
          Expanded(
            flex: 4,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                24,
                MediaQuery.of(context).padding.top + 20,
                24,
                24,
              ),
              child: _buildMetaDetailsRight(context, state),
            ),
          ),
        ],
      ),
    );
  }

  // 作者アイコン + 作者名ブロック（左ペイン / スマホ共通）
  Widget _buildAuthorBlock(BuildContext context, IllustDetailState state) {
    return InkWell(
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
                    ? PixivImage(
                        url: state.illust.author.avatar!,
                        fit: BoxFit.cover,
                        isThumbnail: true,
                        errorWidget: const Icon(
                          Icons.person,
                          color: Colors.grey,
                        ),
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
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
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
    );
  }

  // タブレット用画像ビューア（1枚絵=縦センター / 複数絵=縦スクロール / ugoira=中央）
  Widget _buildTabletImageViewer(
    BuildContext context,
    IllustDetailState state,
    double availableHeight,
    double availableWidth,
  ) {
    final cacheWidth = (availableWidth * MediaQuery.devicePixelRatioOf(context))
        .round();

    if (state.illust.type == 'ugoira') {
      return Center(child: UgoiraPlayer(illustId: state.illust.id));
    }

    final images = state.illust.metaPages.isNotEmpty
        ? state.illust.metaPages
        : [
            PageImage(
              page: 1,
              preview: state.illust.urls.preview,
              original: state.illust.urls.original,
            ),
          ];

    // 複数絵: 上から順に縦並びスクロール（全ページがスクロールで見える）
    if (images.length > 1) {
      return Stack(
        children: [
          SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                for (int i = 0; i < images.length; i++) ...[
                  Center(
                    child: ZoomableImage(
                      url:
                          images[i].original ??
                          state.illust.urls.original ??
                          '',
                      isLargeScreen: true,
                      maxHeight: double.infinity,
                      cacheWidth: cacheWidth,
                    ),
                  ),
                  if (i < images.length - 1) const SizedBox(height: 8),
                ],
              ],
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: _buildFullscreenButton(context, state),
          ),
        ],
      );
    }

    // 1枚絵: 左ペイン内で縦センター配置
    return Stack(
      children: [
        Center(
          child: ZoomableImage(
            url: images.first.original ?? state.illust.urls.original ?? '',
            isLargeScreen: true,
            maxHeight: availableHeight,
            cacheWidth: cacheWidth,
          ),
        ),
        Positioned(
          top: 16,
          right: 16,
          child: _buildFullscreenButton(context, state),
        ),
      ],
    );
  }

  // 右ペイン: タイトル + 作者 + キャプション + タグ + 統計 + ブックマーク + 関連作品
  Widget _buildMetaDetailsRight(BuildContext context, IllustDetailState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. タイトル
        Text(
          state.illust.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        // 2. 作者アイコン + 作者名
        _buildAuthorBlock(context, state),
        const SizedBox(height: 16),
        if (state.illust.caption.isNotEmpty) ...[
          Text(
            state.illust.caption,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
        ],
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: state.illust.tags.map((tag) {
            return InkWell(
              onTap: () => state.onTagTap?.call(tag),
              onLongPress: () =>
                  state.handler.showSubscriptionDialog(context, tag),
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
        const SizedBox(height: 16),
        Row(
          children: [
            const Icon(
              Icons.remove_red_eye_outlined,
              color: Colors.grey,
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(
              '${state.illust.totalView}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(width: 16),
            const Icon(Icons.favorite_border, color: Colors.grey, size: 16),
            const SizedBox(width: 4),
            Text(
              '${state.illust.totalBookmarks}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(width: 16),
            const Icon(Icons.calendar_today, color: Colors.grey, size: 16),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                DateTimeFormat.formatReadable(state.illust.createDate),
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: state.isToggling
                ? null
                : () => state.handler.toggleBookmark(state),
            icon: Icon(
              state.isBookmarked ? Icons.favorite : Icons.favorite_border,
            ),
            label: Text(state.isBookmarked ? 'ブックマーク済み' : 'ブックマーク'),
          ),
        ),
        const Divider(color: Colors.grey, height: 32),
        _buildSimilarSection(context, state),
        const Divider(color: Colors.grey, height: 32),
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

    return Stack(
      children: [
        SizedBox(
          height: 300,
          child: ZoomableImage(
            url: state.illust.urls.original ?? '',
            isLargeScreen: screenWidth > 900,
            maxHeight: 300,
          ),
        ),
        Positioned(
          top: 16,
          right: 16,
          child: _buildFullscreenButton(context, state),
        ),
      ],
    );
  }

  // 全画面表示ボタン（半透明・円形、右上配置）
  Widget _buildFullscreenButton(BuildContext context, IllustDetailState state) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openFullScreenImage(context, state),
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
            color: Colors.black45,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.fullscreen, color: Colors.white, size: 22),
        ),
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

        _buildAuthorBlock(context, state),
        const SizedBox(height: 8),

        // タグ
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: state.illust.tags.map((tag) {
            return InkWell(
              onTap: () => state.onTagTap?.call(tag),
              onLongPress: () =>
                  state.handler.showSubscriptionDialog(context, tag),
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

        // 似た作品（Phase D）
        _buildSimilarSection(context, state),
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
  // 似た作品セクション（Phase D）
  // ==========================================

  /// 「似た作品」セクション（読み込み中は非表示、候補なしは空状態）。
  Widget _buildSimilarSection(BuildContext context, IllustDetailState state) {
    final similar = state.similar;
    if (state.isLoadingSimilar || similar == null) {
      return const SizedBox.shrink();
    }
    final works = similar.works;
    if (works.isEmpty) {
      final msg = similar.modelReady
          ? '似た作品が見つかりませんでした（データ不足またはオフライン）'
          : 'AIモデル未導入のため、似た作品が見つかりませんでした。';
      return SizedBox(
        height: 60,
        child: Center(
          child: Text(
            msg,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.auto_awesome, color: Colors.pinkAccent, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '似た作品',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (!similar.modelReady)
              const Text(
                '(タグベース)',
                style: TextStyle(color: Colors.grey, fontSize: 11),
              ),
            TextButton(
              onPressed: () => _showSimilarWorksScreen(context, state),
              child: const Text(
                'もっと見る',
                style: TextStyle(color: Colors.pinkAccent, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: works.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) =>
                _buildSimilarCard(context, state, works[index]),
          ),
        ),
        if (similar.sameSeries.isNotEmpty)
          ..._buildSimilarLabeledRow(
            '同じシリーズ',
            similar.sameSeries,
            context,
            state,
          ),
        if (similar.sameAuthor.isNotEmpty)
          ..._buildSimilarLabeledRow(
            '同じ作者',
            similar.sameAuthor,
            context,
            state,
          ),
      ],
    );
  }

  /// 同一シリーズ / 同一作者のラベル付きミニ行。
  List<Widget> _buildSimilarLabeledRow(
    String label,
    List<SimilarWork> works,
    BuildContext context,
    IllustDetailState state,
  ) {
    return [
      const SizedBox(height: 12),
      Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
      const SizedBox(height: 4),
      SizedBox(
        height: 110,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: works.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, index) =>
              _buildSimilarCard(context, state, works[index]),
        ),
      ),
    ];
  }

  /// 「似た作品」個別カード（カバー + タイトル + 似た理由）。
  Widget _buildSimilarCard(
    BuildContext context,
    IllustDetailState state,
    SimilarWork work,
  ) {
    return GestureDetector(
      onTap: () => _openSimilarWork(context, state, work),
      child: SizedBox(
        width: 110,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Card(
                color: const Color(0xFF222222),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: _buildSimilarCover(work),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _similarTitle(work),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
            Text(
              work.reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.pinkAccent, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimilarCover(SimilarWork work) {
    final url = _similarCoverUrl(work);
    if (url == null) {
      return Container(
        color: Colors.grey[800],
        child: const Icon(Icons.broken_image, color: Colors.grey),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        PixivImage(
          url: url,
          fit: BoxFit.cover,
          isThumbnail: true,
          errorWidget: Container(
            color: Colors.grey[800],
            child: const Icon(Icons.broken_image, color: Colors.grey),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.5)],
            ),
          ),
        ),
      ],
    );
  }

  /// 候補行からカバーURLを抽出（DB行 / API行の両形式に対応）。
  String? _similarCoverUrl(SimilarWork work) {
    final row = work.row;
    final imageUrls = row['image_urls'];
    if (imageUrls is Map) {
      final u = imageUrls['medium'] ?? imageUrls['large'];
      if (u is String && u.isNotEmpty) return u;
    }
    final cover = row['cover_url'];
    if (cover is String && cover.isNotEmpty) return cover;
    return null;
  }

  String _similarTitle(SimilarWork work) {
    final title = work.row['title'];
    if (title is String && title.isNotEmpty) return title;
    return '作品 #${work.workId}';
  }

  /// 「似た作品」全一覧画面（軸タブ付き）へ遷移。
  void _showSimilarWorksScreen(BuildContext context, IllustDetailState state) {
    final similar = state.similar;
    if (similar == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SimilarWorksScreen(
          baseTitle: state.illust.title,
          result: similar,
          onOpen: (w) => _openSimilarWork(context, state, w),
        ),
      ),
    );
  }

  /// 候補の詳細画面へ遷移（小説→小説詳細 / イラスト→イラスト詳細）。
  void _openSimilarWork(
    BuildContext context,
    IllustDetailState state,
    SimilarWork work,
  ) {
    try {
      if (work.type == 'novel') {
        final novel = Novel.fromJson(Map<String, dynamic>.from(work.row));
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
        );
        return;
      }
      final row = Map<String, dynamic>.from(work.row);
      // ローカルDB行は cover_url から API形式の image_urls を補完する。
      if (row['image_urls'] == null) {
        final cover = row['cover_url'];
        if (cover is String && cover.isNotEmpty) {
          row['image_urls'] = {'medium': cover, 'large': cover};
        }
      }
      final illust = Illust.fromJson(row);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => IllustDetailScreen(
            illust: illust,
            onTagTap: state.onTagTap,
            onBookmarkChanged: state.onBookmarkChanged,
          ),
        ),
      );
    } catch (_) {
      // 行構造が不正な場合は遷移をスキップ。
    }
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
                      PixivImage(
                        url: previewUrl,
                        fit: BoxFit.cover,
                        isThumbnail: true,
                        errorWidget: Container(
                          color: Colors.grey[800],
                          child: const Icon(
                            Icons.broken_image,
                            color: Colors.grey,
                          ),
                        ),
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
                  _shareArtwork(context, state);
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline, color: Colors.white),
                title: const Text('情報', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _showArtworkInfo(context, state);
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

  void _shareArtwork(BuildContext context, IllustDetailState state) {
    final url = 'https://www.pixiv.net/artworks/${state.illust.id}';
    Clipboard.setData(ClipboardData(text: url));
    if (state.context != null) {
      ScaffoldMessenger.of(
        state.context!,
      ).showSnackBar(SnackBar(content: Text('作品URLをコピーしました: $url')));
    }
  }

  void _showArtworkInfo(BuildContext context, IllustDetailState state) {
    final illust = state.illust;
    final tagsText = illust.tags.isNotEmpty
        ? illust.tags.map((t) => '#$t').join('  ')
        : '—';
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF222222),
        title: Text(
          illust.title,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _infoRow('作品ID', '${illust.id}'),
              _infoRow(
                '投稿日時',
                DateTimeFormat.formatReadable(illust.createDate),
              ),
              _infoRow('画像サイズ', '${illust.width} × ${illust.height}'),
              _infoRow('ブックマーク数', '${illust.totalBookmarks}'),
              _infoRow('閲覧数', '${illust.totalView}'),
              _infoRow('タグ', tagsText),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              '閉じる',
              style: TextStyle(color: Colors.pinkAccent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
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
