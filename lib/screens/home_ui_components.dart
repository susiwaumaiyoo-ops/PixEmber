import 'dart:math' as math;

import 'home_screen_state.dart';
import '../services/pixiv_api_service.dart';
import '../widgets/pixiv_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'illust_detail_screen.dart';
import 'novel_detail_screen.dart';
import '../widgets/novel_list_card.dart';
import '../widgets/ugoira_thumb.dart';

/// UIコンポーネントを管理するクラス
class HomeUIComponents {
  // タブレット判定閾値: <700=1列, 700〜1099=2列, >=1100=3列
  static const double _kTabletBreakpoint = 700.0;

  final PixivViewerHomeState state;

  HomeUIComponents(this.state);

  Widget _buildSubTabButton({
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.pinkAccent.withValues(alpha: 0.3)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.pinkAccent : Colors.grey[400],
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // サブモードセレクター
  // =========================================================================
  Widget buildSubModeSelector() {
    if (state.currentIndex == PixivViewerHomeState.feelingDiscoveryIndex) {
      return const SizedBox.shrink();
    }
    final activeSubMode = state.currentIndex == PixivViewerHomeState.illustIndex
        ? state.illustSubMode
        : state.novelSubMode;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      child: Row(
        children: [
          _buildSubTabButton(
            label: 'おすすめ',
            isActive: activeSubMode == 0,
            onTap: () => state.changeSubMode(0),
          ),
          const SizedBox(width: 8),
          _buildSubTabButton(
            label: 'ランキング',
            isActive: activeSubMode == 2,
            onTap: () => state.changeSubMode(2),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // ランキングフィルターバー
  // =========================================================================
  Widget buildRankingFilterBar() {
    if (state.currentIndex == PixivViewerHomeState.feelingDiscoveryIndex) {
      return const SizedBox.shrink();
    }
    final activeSubMode = state.currentIndex == PixivViewerHomeState.illustIndex
        ? state.illustSubMode
        : state.novelSubMode;
    if (activeSubMode != 2) return const SizedBox.shrink();

    final modes = state.currentIndex == PixivViewerHomeState.illustIndex
        ? state.illustRankModes
        : state.novelRankModes;
    final selected = state.currentIndex == PixivViewerHomeState.illustIndex
        ? state.selectedIllustRankMode
        : state.selectedNovelRankMode;

    if (modes.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 42,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: modes.length,
        itemBuilder: (ctx, idx) {
          final m = modes[idx];
          final isSel = m['value'] == selected;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
            child: ChoiceChip(
              label: Text(
                m['label']?.toString() ?? '',
                style: const TextStyle(fontSize: 11),
              ),
              selected: isSel,
              selectedColor: Colors.pink.withValues(alpha: 0.3),
              checkmarkColor: Colors.pinkAccent,
              onSelected: (bool sel) {
                if (sel) state.changeRankMode(m['value']);
              },
            ),
          );
        },
      ),
    );
  }

  // =========================================================================
  // イラストグリッド
  // =========================================================================
  Widget buildIllustGrid(int crossAxisCount) {
    if (state.isLoading && state.illusts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.illusts.isEmpty) {
      return _buildEmptyState(
        icon: Icons.palette,
        message: 'イラストがありません',
        subMessage: '検索やおすすめを待っています',
      );
    }

    // 年齢制限（x_restrict）フィルタは共通純粋関数で先に適用する。
    // all=全年齢のみ(0), include_r18=すべて, r18=1のみ, r18g=2のみ
    final ageFilteredIllusts = PixivApiService.applyAgeLimitFilter(
      state.illusts,
      state.selectedAgeLimit,
      (illust) => illust.xRestrict,
    );
    final List filteredIllusts = ageFilteredIllusts.where((illust) {
      // 作品種別フィルター
      if (state.selectedWorkType != 'all' && state.selectedWorkType != 'none') {
        if (state.selectedWorkType == 'illust' && illust.type != 'illust') {
          return false;
        }
        if (state.selectedWorkType == 'illustration' &&
            illust.type != 'illust') {
          return false;
        }
        if (state.selectedWorkType == 'manga' && illust.type != 'manga') {
          return false;
        }
        if (state.selectedWorkType == 'ugoira' && illust.type != 'ugoira') {
          return false;
        }
        if (state.selectedWorkType == 'novel') return false;
      }
      return true;
    }).toList();

    if (filteredIllusts.isEmpty && state.illusts.isNotEmpty) {
      return const Center(
        child: Text(
          'フィルターに一致するイラストが見つかりませんでした。',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => state.fetchData(),
      child: GridView.builder(
        controller: state.scrollController,
        physics: const ClampingScrollPhysics(),
        // ignore: deprecated_member_use
        cacheExtent: 600.0,
        padding: const EdgeInsets.all(6.0),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 6.0,
          mainAxisSpacing: 6.0,
          childAspectRatio: 0.75,
        ),
        itemCount: filteredIllusts.length + (state.nextOffset != null ? 1 : 0),
        itemBuilder: (ctx, index) {
          if (index == filteredIllusts.length) {
            return _buildLoadMoreIndicator();
          }
          return _buildIllustGridItem(ctx, filteredIllusts[index]);
        },
      ),
    );
  }

  Widget _buildUgoiraThumb(dynamic illust, String? previewUrl) {
    int? id;
    try {
      id = illust.id as int?;
    } catch (_) {
      id = null;
    }
    if (id == null) {
      return previewUrl != null && previewUrl.isNotEmpty
          ? PixivImage(
              url: previewUrl,
              fit: BoxFit.cover,
              isThumbnail: true,
              cacheWidth: 300,
              errorWidget: Container(color: Colors.black26),
            )
          : Container(color: Colors.black26);
    }
    return UgoiraThumb(illustId: id, fallbackUrl: previewUrl);
  }

  Widget _buildIllustGridItem(BuildContext context, dynamic illust) {
    String? previewUrl;
    try {
      previewUrl =
          illust.urls?.preview ?? illust.urls?.small ?? illust.urls?.medium;
    } catch (_) {}

    return RepaintBoundary(
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: 3,
        child: InkWell(
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => IllustDetailScreen(
                  illust: illust,
                  onTagTap: state.onTagSelected,
                  onBookmarkChanged: (newVal) {
                    state.applyState(() {
                      illust.isBookmarked = newVal;
                    });
                  },
                ),
              ),
            );
            if (state.isMounted != true) return;
            state.applyState(() {});
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // プレビュー画像
              if (illust.type == 'ugoira')
                _buildUgoiraThumb(illust, previewUrl)
              else if (previewUrl != null && previewUrl.isNotEmpty)
                PixivImage(
                  url: previewUrl,
                  fit: BoxFit.cover,
                  isThumbnail: true,
                  cacheWidth: 300,
                  errorWidget: Container(color: Colors.black26),
                )
              else
                Container(color: Colors.black26),
              // ブックマーク済みハート（左上）
              if (illust.isBookmarked == true)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.pinkAccent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.favorite,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              // ブックマーク数バッジ（右下）
              if ((illust.totalBookmarks) > 0)
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.bookmark,
                          size: 12,
                          color: Colors.pinkAccent,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${illust.totalBookmarks}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // 小説リスト（NovelListCard に共通化済み）
  Widget buildNovelList() {
    if (state.isLoading && state.novels.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.novels.isEmpty) {
      return _buildEmptyState(
        icon: Icons.menu_book,
        message: '小説がありません',
        subMessage: '検索やおすすめを待っています',
      );
    }

    final screenWidth = MediaQuery.of(state.context).size.width;
    final isTablet = screenWidth >= _kTabletBreakpoint;
    // 列数: <700=1, 700以上=2（1100以上でも3列にしない）
    int crossAxisCount;
    double horiz, vert;
    if (isTablet) {
      crossAxisCount = 2;
      horiz = 32.0;
      vert = 10.0;
    } else {
      crossAxisCount = 1;
      horiz = 16.0;
      vert = 6.0;
    }

    final itemCount = state.novels.length;
    final hasNext = state.nextOffset != null;

    return RefreshIndicator(
      onRefresh: () => state.fetchData(),
      child: CustomScrollView(
        controller: state.scrollController,
        physics: const ClampingScrollPhysics(),
        // ignore: deprecated_member_use
        cacheExtent: 600.0,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: horiz, vertical: vert),
            sliver: isTablet
                ? SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 12.0,
                      mainAxisSpacing: 12.0,
                      // カバー高さいっぱい + テキスト収まる余裕（Overflow防止）
                      mainAxisExtent: 156.0,
                    ),
                    delegate: SliverChildBuilderDelegate((ctx, index) {
                      if (index >= itemCount) return const SizedBox.shrink();
                      final novel = state.novels[index];
                      return NovelListCard(
                        novel: novel,
                        onTap: () => Navigator.push(
                          ctx,
                          MaterialPageRoute(
                            builder: (_) => NovelDetailScreen(novel: novel),
                          ),
                        ),
                      );
                    }, childCount: itemCount),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate((ctx, index) {
                      if (index >= itemCount) return const SizedBox.shrink();
                      final novel = state.novels[index];
                      return NovelListCard(
                        novel: novel,
                        onTap: () => Navigator.push(
                          ctx,
                          MaterialPageRoute(
                            builder: (_) => NovelDetailScreen(novel: novel),
                          ),
                        ),
                      );
                    }, childCount: itemCount),
                  ),
          ),
          if (hasNext)
            SliverToBoxAdapter(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1400),
                child: Center(child: _buildLoadMoreIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  // =========================================================================
  // 共通ウィジェット
  // =========================================================================
  Widget _buildEmptyState({
    required IconData icon,
    required String message,
    required String subMessage,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Text(
            subMessage,
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadMoreIndicator() {
    if (state.rateLimited == true) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'アクセス制限が発生しました',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Pixivのアクセス制限（レート制限）が発生しました。\nしばらく時間を置いてから再試行してください。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: state.fetchNextPage,
                icon: const Icon(Icons.refresh),
                label: const Text('再試行'),
              ),
            ],
          ),
        ),
      );
    }
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(16.0),
        child: CircularProgressIndicator(color: Colors.pinkAccent),
      ),
    );
  }

  Widget buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 64, color: Colors.pinkAccent),
            const SizedBox(height: 16),
            Text(
              state.errorMessage?.toString() ?? 'エラーが発生しました',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: state.fetchData,
              icon: const Icon(Icons.refresh),
              label: const Text('再読み込みする'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.pinkAccent,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // 百科事典カード
  // =========================================================================
  /// B2: 百科事典カードの上にある検索バー＋ソースチップの固定高さ（≒56+44）。
  static const double _kEncyclopediaTopReserve = 100.0;

  /// 百科事典カードの自然高さの最大値（要約3行＋リンク行の全表示時）。
  static const double _kEncyclopediaCardMaxHeight = 180.0;

  Widget buildEncyclopediaCard(BuildContext context) {
    if (state.searchItem == null) return const SizedBox.shrink();
    final item = state.searchItem!;
    final String? iconUrl = item.iconUrl;

    final cardContent = Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 50,
                  height: 50,
                  color: Colors.black,
                  child: (iconUrl != null && iconUrl.isNotEmpty)
                      ? PixivImage(
                          url: iconUrl,
                          fit: BoxFit.cover,
                          isThumbnail: true,
                          cacheWidth: 150,
                          width: 50,
                          height: 50,
                          errorWidget: const Icon(
                            Icons.bookmark_border,
                            color: Colors.pinkAccent,
                          ),
                        )
                      : const Icon(
                          Icons.bookmark_border,
                          color: Colors.pinkAccent,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#${item.name}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.pinkAccent,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    if (item.wordCount != null)
                      Text(
                        '作品数: ${item.wordCount}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      )
                    else
                      const Text(
                        '作品数: 取得できません',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (item.summary.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              item.summary,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white70,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (item.dicUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: InkWell(
                onTap: () async {
                  final parsed = Uri.tryParse(item.dicUrl);
                  final uri =
                      (parsed != null &&
                          (parsed.scheme == 'http' || parsed.scheme == 'https'))
                      ? parsed
                      : Uri(
                          scheme: 'https',
                          host: 'dic.pixiv.net',
                          pathSegments: ['a', item.name.trim()],
                        );
                  final launched = await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  );
                  if (!launched && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('百科事典を開けませんでした')),
                    );
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  child: Text(
                    'ピクシブ百科事典で見る ↗',
                    style: TextStyle(
                      color: Colors.blueAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    // B2: 百科事典カードは「検索実行の瞬間」に出現する。キーボード表示中は
    // 本体(body)の高さが縮小し、カードの自然高さ(最大≒179px)が
    // body高さ − 検索バー(≒56) − ソースチップ(44) を超えると、
    // 画面下端で RenderFlex BOTTOM OVERFLOWED が発生した。
    // カードの自然高さは有界な制約しか受け取れない Column 内の
    // 非flex子で推定できないため、MediaQuery の viewInsets を使って
    // 使用可能高さを算出し、収まらない場合は高さを上限切って
    // カード内を縦スクロール可能にする。
    final media = MediaQuery.of(context);
    // body 高さ = 画面高さ − AppBar − NavigationBar − キーボード(viewInsets.bottom)
    final available =
        media.size.height -
        media.padding.top -
        56.0 // AppBar 標準高さ
        -
        80.0 // NavigationBar 標準高さ
        -
        media.viewInsets.bottom -
        _kEncyclopediaTopReserve;
    if (available >= _kEncyclopediaCardMaxHeight) {
      // 通常: 従来通りのレイアウト。
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 4,
        child: cardContent,
      );
    }
    return SizedBox(
      height: math.max(0.0, available),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 4,
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(child: cardContent),
      ),
    );
  }

  // =========================================================================
  // 同期プログレス
  // =========================================================================
  Widget buildSyncProgressHUD() {
    if (state.isSyncing != true) return const SizedBox.shrink();

    return Center(
      child: Container(
        padding: const EdgeInsets.all(24.0),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.pinkAccent),
            SizedBox(height: 16),
            Text(
              'Google ドライブに同期中...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              '処理中...',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // フィルターUI部品（HomeFilterHandler と重複してるなら後で削除可）
  // =========================================================================
  Widget buildFilterSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: 13,
      ),
    );
  }

  Widget buildChoiceChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : Colors.grey[400],
          fontSize: 12,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      selected: selected,
      selectedColor: Colors.pinkAccent.withValues(alpha: 0.8),
      backgroundColor: const Color(0xFF2E2E2E),
      elevation: selected ? 2 : 0,
      pressElevation: 4,
      onSelected: (_) => onSelected(),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? Colors.pinkAccent : Colors.transparent,
          width: 1,
        ),
      ),
    );
  }
}
