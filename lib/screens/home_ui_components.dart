import 'home_screen_state.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../novel_model.dart';
import 'history_screen.dart';
import 'bookmark_list_screen.dart';
import 'folder_list_screen.dart';
import 'mute_settings_screen.dart';
import 'illust_detail_screen.dart';
import 'novel_detail_screen.dart';
import '../widgets/pixiv_image.dart';

/// UIコンポーネントを管理するクラス
class HomeUIComponents {
  // タブレット判定閾値: <700=1列, 700〜1099=2列, >=1100=3列
  static const double _kTabletBreakpoint = 700.0;

  final PixivViewerHomeState state;

  HomeUIComponents(this.state);

  // =========================================================================
  // build（エントリポイント）
  // =========================================================================
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    int crossAxisCount = 2;
    if (screenWidth > 1200) {
      crossAxisCount = 5;
    } else if (screenWidth > 800) {
      crossAxisCount = 4;
    } else if (screenWidth > 500) {
      crossAxisCount = 3;
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              state.currentIndex == PixivViewerHomeState.illustIndex
                  ? Icons.palette
                  : state.currentIndex == PixivViewerHomeState.novelIndex
                  ? Icons.menu_book
                  : Icons.auto_awesome,
              color: Colors.pinkAccent,
            ),
            const SizedBox(width: 8),
            Text(
              state.currentIndex == PixivViewerHomeState.illustIndex
                  ? 'Pixiv Illusts'
                  : state.currentIndex == PixivViewerHomeState.novelIndex
                  ? 'Pixiv Novels'
                  : 'フィーリング発掘',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: state.isLoading ? null : state.fetchData,
            tooltip: '更新',
          ),
        ],
      ),
      drawer: _buildDrawer(context),
      body: Stack(
        children: [buildMainContent(crossAxisCount), buildSyncProgressHUD()],
      ),
    );
  }

  // =========================================================================
  // Drawer
  // =========================================================================
  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF1A1A1A),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.pink),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'PixEmber',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Ultimate State v3.1.0',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.image, color: Colors.pinkAccent),
            title: const Text('イラスト (Illusts)'),
            onTap: () {
              Navigator.pop(context);
              state.changeTab(PixivViewerHomeState.illustIndex);
            },
          ),
          ListTile(
            leading: const Icon(Icons.menu_book, color: Colors.pinkAccent),
            title: const Text('小説 (Novels)'),
            onTap: () {
              Navigator.pop(context);
              state.changeTab(PixivViewerHomeState.novelIndex);
            },
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome, color: Colors.pinkAccent),
            title: const Text('フィーリング発掘'),
            onTap: () {
              Navigator.pop(context);
              state.changeTab(PixivViewerHomeState.feelingDiscoveryIndex);
            },
          ),
          ListTile(
            leading: const Icon(Icons.bookmark, color: Colors.pinkAccent),
            title: const Text('しおり一覧'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BookmarkListScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.history, color: Colors.pinkAccent),
            title: const Text('閲覧履歴 (History)'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder, color: Colors.pinkAccent),
            title: const Text('お気に入りフォルダ'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FolderListScreen()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.block, color: Colors.pinkAccent),
            title: const Text('ミュート（ブラックリスト）管理'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MuteSettingsScreen()),
              );
            },
          ),
          ListTile(
            leading: Icon(
              state.isLoggedIn ? Icons.logout : Icons.login,
              color: Colors.pinkAccent,
            ),
            title: Text(state.isLoggedIn ? 'ログアウト' : 'アカウント連携（ログイン）'),
            onTap: () {
              Navigator.pop(context);
              if (state.isLoggedIn) {
                state.logout();
              } else {
                state.showPKCELoginDialog();
              }
            },
          ),
          const Divider(height: 1, color: Colors.grey),
          ..._buildGoogleDriveSyncTiles(),
        ],
      ),
    );
  }

  // =========================================================================
  // メインコンテンツ
  // =========================================================================
  Widget buildMainContent(int crossAxisCount) {
    return Column(
      children: [
        // 検索バー
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: state.searchController,
                  focusNode: state.searchFocusNode,
                  decoration: InputDecoration(
                    hintText: '検索...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon:
                        state.searchHistory.isNotEmpty &&
                            state.searchFocusNode.hasFocus
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              state.searchController.clear();
                              state.searchFocusNode.unfocus();
                              state.resetSearch();
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    filled: true,
                    fillColor: Colors.grey[900],
                  ),
                  onSubmitted: state.onSearchSubmit,
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                icon: const Icon(Icons.filter_list, color: Colors.pinkAccent),
                onSelected: (String value) {
                  if (state.currentIndex == PixivViewerHomeState.illustIndex) {
                    state.showFilterBottomSheet();
                  } else if (state.currentIndex ==
                      PixivViewerHomeState.novelIndex) {
                    state.showNovelFilterBottomSheet();
                  }
                },
                itemBuilder: (BuildContext ctx) => const [
                  PopupMenuItem(value: 'filter', child: Text('フィルター')),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _buildTabBar(),
        buildSubModeSelector(),
        buildRankingFilterBar(),
        const SizedBox(height: 8),
        // コンテンツエリア
        Expanded(
          child: state.errorMessage != null
              ? buildErrorWidget()
              : state.currentIndex == PixivViewerHomeState.illustIndex
              ? buildIllustGrid(crossAxisCount)
              : state.currentIndex == PixivViewerHomeState.novelIndex
              ? buildNovelList()
              : _buildFeelingDiscoveryContent(),
        ),
      ],
    );
  }

  // =========================================================================
  // タブバー
  // =========================================================================
  Widget _buildTabBar() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          _buildSubTabButton(
            label: 'おすすめ',
            isActive:
                state.currentIndex == PixivViewerHomeState.illustIndex &&
                state.illustSubMode == 0,
            onTap: () => state.changeTab(PixivViewerHomeState.illustIndex, 0),
          ),
          _buildSubTabButton(
            label: '検索結果',
            isActive:
                state.currentIndex == PixivViewerHomeState.illustIndex &&
                state.illustSubMode == 1,
            onTap: () => state.changeTab(PixivViewerHomeState.illustIndex, 1),
          ),
          _buildSubTabButton(
            label: 'ランキング',
            isActive:
                state.currentIndex == PixivViewerHomeState.illustIndex &&
                state.illustSubMode == 2,
            onTap: () => state.changeTab(PixivViewerHomeState.illustIndex, 2),
          ),
          const SizedBox(width: 4),
          _buildSubTabButton(
            label: 'おすすめ',
            isActive:
                state.currentIndex == PixivViewerHomeState.novelIndex &&
                state.novelSubMode == 0,
            onTap: () => state.changeTab(PixivViewerHomeState.novelIndex, 0),
          ),
          _buildSubTabButton(
            label: '検索結果',
            isActive:
                state.currentIndex == PixivViewerHomeState.novelIndex &&
                state.novelSubMode == 1,
            onTap: () => state.changeTab(PixivViewerHomeState.novelIndex, 1),
          ),
          _buildSubTabButton(
            label: 'ランキング',
            isActive:
                state.currentIndex == PixivViewerHomeState.novelIndex &&
                state.novelSubMode == 2,
            onTap: () => state.changeTab(PixivViewerHomeState.novelIndex, 2),
          ),
          const SizedBox(width: 4),
          _buildSubTabButton(
            label: 'フィーリング発掘',
            isActive:
                state.currentIndex ==
                PixivViewerHomeState.feelingDiscoveryIndex,
            onTap: () =>
                state.changeTab(PixivViewerHomeState.feelingDiscoveryIndex),
          ),
        ],
      ),
    );
  }

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

    final List filteredIllusts = state.illusts.where((illust) {
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
      // 年齢制限フィルター
      bool hasR18Tag = false;
      try {
        final tags = illust.tags;
        hasR18Tag = tags.any((t) {
          final name = t.toLowerCase();
          return name.contains('r-18') || name.contains('r18');
        });
      } catch (_) {}
      if (state.selectedAgeLimit == 'safe' && hasR18Tag) return false;
      if (state.selectedAgeLimit == 'r18' && !hasR18Tag) return false;
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

  Widget _buildIllustGridItem(BuildContext context, dynamic illust) {
    String? previewUrl;
    try {
      previewUrl =
          illust.urls?.preview ?? illust.urls?.small ?? illust.urls?.medium;
    } catch (_) {}

    return Card(
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
            if (previewUrl != null && previewUrl.isNotEmpty)
              Image.network(
                previewUrl,
                fit: BoxFit.cover,
                headers: const {'Referer': 'https://www.pixiv.net/'},
                errorBuilder: (_, _, _) => Container(color: Colors.black26),
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
    );
  }

  // =========================================================================
  // 小説リスト
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
      horiz = 16.0;
      vert = 10.0;
    } else {
      crossAxisCount = 1;
      horiz = 8.0;
      vert = 6.0;
    }

    final itemCount = state.novels.length;
    final hasNext = state.nextOffset != null;

    return RefreshIndicator(
      onRefresh: () => state.fetchData(),
      child: CustomScrollView(
        controller: state.scrollController,
        physics: const ClampingScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: horiz, vertical: vert),
            sliver: isTablet
                ? SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 12.0,
                      mainAxisSpacing: 12.0,
                      mainAxisExtent: 188.0,
                    ),
                    delegate: SliverChildBuilderDelegate((ctx, index) {
                      if (index >= itemCount) return const SizedBox.shrink();
                      return FutureBuilder<Widget>(
                        future: _buildNovelItemCard(ctx, state.novels[index]),
                        builder: (ctx2, snap) =>
                            snap.data ?? const SizedBox.shrink(),
                      );
                    }, childCount: itemCount),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate((ctx, index) {
                      if (index >= itemCount) return const SizedBox.shrink();
                      return FutureBuilder<Widget>(
                        future: _buildNovelItemCard(ctx, state.novels[index]),
                        builder: (ctx2, snap) =>
                            snap.data ?? const SizedBox.shrink(),
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

  Future<Widget> _buildNovelItemCard(
    BuildContext context,
    dynamic rawNovel,
  ) async {
    final Novel novel = rawNovel as Novel;
    final String coverUrl = novel.coverUrl.isNotEmpty
        ? novel.coverUrl
        : (novel.rawCoverUrl ?? '');

    // バッジ行（優先度: AI > シリーズ、最大2個に制限してWrapの2行化防止）
    final List<Widget> badges = <Widget>[];
    if (novel.aiType == 2) {
      badges.add(
        _buildNovelBadge(Icons.auto_awesome, 'AI', Colors.purpleAccent),
      );
    }
    if (novel.series != null) {
      badges.add(
        _buildNovelBadge(Icons.collections_bookmark, 'シリーズ', Colors.blueAccent),
      );
    }
    // ローカルしおり（読書進捗）がある場合は「しおり」バッジを表示
    // （Pixivサーバーのブックマークとは別管理のアプリ内状態）
    final prefs = await SharedPreferences.getInstance();
    final bookmarkIds = prefs.getStringList('novel_bookmark_ids') ?? [];
    if (bookmarkIds.contains(novel.id.toString())) {
      badges.add(_buildNovelBadge(Icons.bookmark, 'しおり', Colors.pinkAccent));
    }
    if (badges.length > 3) badges.length = 3;

    // タグ：最大2〜3個を1行Textで表示（無制限Wrap禁止）
    final bool hasTags = novel.tags.isNotEmpty;

    // 説明文の正規化
    final String caption = novel.caption.replaceAll(RegExp(r'\s+'), ' ').trim();
    final bool hasCaption = caption.isNotEmpty;

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 表紙（固定サイズ・カード高さを超えない）
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 96,
                  height: 152,
                  child: coverUrl.isNotEmpty
                      ? PixivImage(
                          url: coverUrl,
                          fit: BoxFit.cover,
                          isThumbnail: true,
                          errorWidget: _buildNovelCoverPlaceholder(),
                          placeholder: _buildNovelCoverPlaceholder(),
                        )
                      : _buildNovelCoverPlaceholder(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 狭いカードでは説明文を省略し、優先情報を維持
                    final bool isCompact = constraints.maxWidth < 420;
                    // 説明文は常に最大1行（非compact時も2行にしない）
                    final int captionLines = 1;
                    final int tagLimit = isCompact ? 2 : 3;

                    final List<Widget> infoChildren = <Widget>[];

                    // バッジ（最大2個・1行のみ）
                    if (badges.isNotEmpty) {
                      infoChildren.add(
                        Wrap(spacing: 6, runSpacing: 0, children: badges),
                      );
                      infoChildren.add(const SizedBox(height: 3));
                    }

                    // タイトル（最大2行）
                    infoChildren.add(
                      Text(
                        novel.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                    infoChildren.add(const SizedBox(height: 2));

                    // 作者名（最大1行）
                    infoChildren.add(
                      Row(
                        children: [
                          const Icon(
                            Icons.person_outline,
                            size: 13,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              novel.author.name,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );

                    // シリーズ名（最大1行・存在時）
                    if (novel.series != null) {
                      infoChildren.addAll([
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(
                              Icons.collections_bookmark,
                              size: 13,
                              color: Colors.blueAccent,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                novel.series!.title,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.blueAccent,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ]);
                    }

                    // 説明文（高さ不足時は非表示）
                    if (hasCaption && !isCompact) {
                      infoChildren.addAll([
                        const SizedBox(height: 2),
                        Text(
                          caption,
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 12,
                          ),
                          maxLines: captionLines,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ]);
                    }

                    // タグ（1行Text・最大 tagLimit 個）
                    if (hasTags) {
                      final visibleTags = novel.tags.take(tagLimit).toList();
                      infoChildren.addAll([
                        const SizedBox(height: 3),
                        Text(
                          visibleTags.map((t) => '#$t').join('  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.pinkAccent,
                          ),
                        ),
                      ]);
                    }

                    // メタ情報（必ず表示・下部配置）
                    infoChildren.add(const Spacer());
                    infoChildren.add(
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.notes,
                              size: 12,
                              color: Colors.white54,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _formatNumber(novel.textLength),
                              style: const TextStyle(fontSize: 11),
                            ),
                            const SizedBox(width: 10),
                            const Icon(
                              Icons.menu_book,
                              size: 12,
                              color: Colors.white54,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${novel.pageCount}P',
                              style: const TextStyle(fontSize: 11),
                            ),
                            const SizedBox(width: 10),
                            const Icon(
                              Icons.bookmark,
                              size: 12,
                              color: Colors.pinkAccent,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _formatNumber(novel.totalBookmarks),
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    );

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.max,
                      children: infoChildren,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNovelCoverPlaceholder() {
    return Container(
      color: Colors.grey.shade900,
      alignment: Alignment.center,
      child: const Icon(Icons.menu_book, color: Colors.white38, size: 36),
    );
  }

  Widget _buildNovelBadge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 10, color: color)),
        ],
      ),
    );
  }

  String _formatNumber(int number) {
    if (number >= 10000) {
      return '${(number / 10000).toStringAsFixed(1)}万';
    }
    return number.toString();
  }

  // =========================================================================
  // フィーリング発掘
  // =========================================================================
  Widget _buildFeelingDiscoveryContent() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.auto_awesome,
            size: 64,
            color: Colors.pinkAccent.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          const Text(
            'フィーリング発掘',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('お気に入りのタグやブックマークから', style: TextStyle(color: Colors.grey)),
          const Text('新しい発見を楽しめます', style: TextStyle(color: Colors.grey)),
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
  Widget buildEncyclopediaCard(BuildContext context) {
    if (state.searchItem == null) return const SizedBox.shrink();
    final item = state.searchItem!;
    final String? iconUrl = item.iconUrl;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 4,
      child: Padding(
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
                        ? Image.network(
                            iconUrl,
                            fit: BoxFit.cover,
                            headers: const {
                              'Referer': 'https://www.pixiv.net/',
                            },
                            errorBuilder: (_, _, _) => const Icon(
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
                            (parsed.scheme == 'http' ||
                                parsed.scheme == 'https'))
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
      ),
    );
  }

  // =========================================================================
  // 検索履歴オーバーレイ
  // =========================================================================
  Widget buildSearchHistoryOverlay() {
    return Positioned(
      top: 110,
      left: 8,
      right: 8,
      child: Card(
        color: const Color(0xFF1E1E1E),
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12.0,
                  vertical: 8.0,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '最近の検索履歴',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextButton(
                      onPressed: state.clearAllSearchHistory,
                      child: const Text(
                        'すべてクリア',
                        style: TextStyle(
                          color: Colors.pinkAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.grey),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: state.searchHistory.length,
                  itemBuilder: (ctx, idx) {
                    final word = state.searchHistory[idx];
                    return ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.history,
                        size: 16,
                        color: Colors.grey,
                      ),
                      title: Text(
                        word,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.close,
                          size: 14,
                          color: Colors.grey,
                        ),
                        onPressed: () => state.deleteSearchHistoryItem(word),
                      ),
                      onTap: () => state.onHistoryItemTap(word),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // 最近のブックマーク
  // =========================================================================
  Widget buildRecentBookmarksSection() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: state.getRecentBookmarks(),
      builder: (ctx, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        final recentBookmarks = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
              child: Text(
                '最近のブックマーク',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            Container(
              height: 120,
              margin: const EdgeInsets.symmetric(horizontal: 8.0),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: recentBookmarks.length,
                itemBuilder: (ctx, index) {
                  final bookmark = recentBookmarks[index];
                  return Container(
                    width: 100,
                    margin: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            height: 80,
                            color: Colors.black,
                            child:
                                (bookmark['imageUrl'] != null &&
                                    bookmark['imageUrl']!.isNotEmpty)
                                ? Image.network(
                                    bookmark['imageUrl']!,
                                    fit: BoxFit.cover,
                                    headers: const {
                                      'Referer': 'https://www.pixiv.net/',
                                    },
                                    errorBuilder: (_, _, _) => const Icon(
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
                        const SizedBox(height: 4),
                        Text(
                          bookmark['title'] ?? 'Unknown',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
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
  // Google Drive 同期メニュー（Drawer用）
  // =========================================================================
  List<Widget> _buildGoogleDriveSyncTiles() {
    return [
      ListTile(
        leading: const Icon(Icons.cloud_sync, color: Colors.pinkAccent),
        title: const Text('Google ドライブ同期'),
        subtitle: Text(state.isSyncing == true ? '同期中...' : '同期の状態を管理'),
        trailing: state.isSyncing == true
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onTap: () {
          if (state.isSyncing == true) return;
          state.handleGoogleBackup();
        },
      ),
      ListTile(
        leading: const Icon(Icons.cloud_upload, color: Colors.pinkAccent),
        title: const Text('バックアップ作成'),
        subtitle: Text(state.isSyncing == true ? '処理中...' : 'ブックマークと履歴をバックアップ'),
        onTap: () {
          if (state.isSyncing == true) return;
          state.handleGoogleBackup();
        },
      ),
      ListTile(
        leading: const Icon(Icons.cloud_download, color: Colors.pinkAccent),
        title: const Text('バックアップ復元'),
        subtitle: Text(state.isSyncing == true ? '処理中...' : 'バックアップから復元'),
        onTap: () {
          if (state.isSyncing == true) return;
          state.handleGoogleRestore();
        },
      ),
      ListTile(
        leading: const Icon(Icons.login, color: Colors.pinkAccent),
        title: Text(
          state.isGoogleDriveLoggedIn == true ? 'ログアウト' : 'Googleアカウント連携',
        ),
        subtitle: Text(
          state.isGoogleDriveLoggedIn == true
              ? 'Google アカウントに接続済み'
              : 'Google アカウントで同期',
        ),
        onTap: () {
          if (state.isGoogleDriveLoggedIn == true) {
            state.handleGoogleLogout();
          } else {
            state.handleGoogleLogin();
          }
        },
      ),
    ];
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
