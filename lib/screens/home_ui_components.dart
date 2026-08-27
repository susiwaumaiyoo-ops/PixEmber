import 'home_screen_state.dart';
import '../widgets/pixiv_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'history_screen.dart';
import 'bookmark_list_screen.dart';
import 'folder_list_screen.dart';
import 'mute_settings_screen.dart';
import 'subscriptions_screen.dart';
import 'backup_manager_screen.dart';
import '../services/database_service.dart';
import 'read_later_screen.dart';
import 'offline_bookshelf_screen.dart';
import 'download_queue_screen.dart';
import 'ai_recommend_feed_screen.dart';
import 'illust_detail_screen.dart';
import 'novel_detail_screen.dart';
import '../widgets/novel_list_card.dart';

/// 検索候補の1件（履歴 or 購読タグ）
class _SearchSuggestion {
  final String keyword;
  final bool isTag;

  const _SearchSuggestion({required this.keyword, required this.isTag});
}

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
        children: [
          buildMainContent(context, crossAxisCount),
          buildSyncProgressHUD(),
        ],
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
            leading: const Icon(Icons.recommend, color: Colors.pinkAccent),
            title: const Text('AIレコメンド'),
            subtitle: const Text('あなたの好みに合わせた推薦'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AiRecommendFeedScreen(),
                ),
              );
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
          FutureBuilder<int>(
            // Drawer 表示時に未読新着合計を一度だけ取得する（ポーリングなし）
            future: DatabaseService().getSubscriptionUnreadCount(),
            initialData: 0,
            builder: (context, snapshot) {
              final unread = snapshot.data ?? 0;
              return ListTile(
                leading: const Icon(Icons.stars, color: Colors.pinkAccent),
                title: const Text('購読タグ'),
                // 0 件ならバッジ非表示、それ以外は未読数を表示
                trailing: unread > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.pinkAccent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          unread > 999 ? '999+' : unread.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SubscriptionsScreen(
                        onTagSelected: (tag, type) =>
                            state.onSubscribedTagSelected(tag, type),
                      ),
                    ),
                  ).then((_) {
                    // 購読画面から戻った際に未読バッジを更新するため再描画
                    state.applyState(() {});
                  });
                },
              );
            },
          ),
          FutureBuilder<int>(
            // Drawer 表示時にあとで読む未読数を一度だけ取得する（ポーリングなし）
            future: DatabaseService().getReadLaterUnreadCount(),
            initialData: 0,
            builder: (context, snapshot) {
              final unread = snapshot.data ?? 0;
              return ListTile(
                leading: const Icon(
                  Icons.bookmark_add_outlined,
                  color: Colors.pinkAccent,
                ),
                title: const Text('あとで読む'),
                trailing: unread > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.pinkAccent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          unread > 999 ? '999+' : unread.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ReadLaterScreen()),
                  ).then((_) {
                    // 戻った際に未読バッジを更新するため再描画
                    state.applyState(() {});
                  });
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download, color: Colors.pinkAccent),
            title: const Text('オフライン本棚'),
            subtitle: const Text('キャッシュした小説をオフラインで読む'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const OfflineBookshelfScreen(),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(
              Icons.download_for_offline,
              color: Colors.pinkAccent,
            ),
            title: const Text('ダウンロードキュー'),
            subtitle: const Text('イラスト・うごイラ・小説のダウンロード状況'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DownloadQueueScreen()),
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
          ..._buildGoogleDriveSyncTiles(context),
        ],
      ),
    );
  }

  // =========================================================================
  // メインコンテンツ
  // =========================================================================
  Widget buildMainContent(BuildContext context, int crossAxisCount) {
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
        // 小説タブで検索結果がある時のみ表示：タグ別一括ベクトル化ボタン
        if (state.currentIndex == PixivViewerHomeState.novelIndex &&
            state.searchItem != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('このタグの小説をAI学習する'),
                onPressed: () => _showVectorizeConfirmDialog(context),
              ),
            ),
          ),
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
      // 年齢制限フィルター（x_restrict フィールドベース）
      // all=全年齢のみ(0), include_r18=R-18含む(0,1,2), r18=R-18のみ(1), r18g=R-18G含む(0,1,2)
      if (state.selectedAgeLimit == 'all' && illust.xRestrict > 0) return false;
      if (state.selectedAgeLimit == 'r18' && illust.xRestrict != 1) {
        return false;
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
              if (previewUrl != null && previewUrl.isNotEmpty)
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
    final query = state.searchController.text.trim();
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
          child: FutureBuilder<List<_SearchSuggestion>>(
            future: _buildSearchSuggestions(query),
            builder: (ctx, snap) {
              final suggestions = snap.data ?? <_SearchSuggestion>[];
              return Column(
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
                        Text(
                          query.isEmpty ? '最近の検索履歴' : '検索候補',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (query.isEmpty)
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
                  if (suggestions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        '候補がありません',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: suggestions.length,
                        itemBuilder: (ctx, idx) {
                          final s = suggestions[idx];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              s.isTag ? Icons.tag : Icons.history,
                              size: 16,
                              color: s.isTag
                                  ? Colors.orangeAccent
                                  : Colors.grey,
                            ),
                            title: Text(
                              s.keyword,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            trailing: s.isTag
                                ? null
                                : IconButton(
                                    icon: const Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Colors.grey,
                                    ),
                                    onPressed: () => state
                                        .deleteSearchHistoryItem(s.keyword),
                                  ),
                            onTap: () => state.onHistoryItemTap(s.keyword),
                          );
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 検索候補を組み立てる（DB検索履歴の部分一致 + 購読タグの部分一致）。
  /// 重複はキーワード単位で排除し、履歴優先で表示する。
  Future<List<_SearchSuggestion>> _buildSearchSuggestions(String query) async {
    final db = DatabaseService();
    try {
      final histRows = await db.searchSearchHistory(query: query);
      final tags = await db.getSubscribedTags();
      final seen = <String>{};
      final result = <_SearchSuggestion>[];
      for (final r in histRows) {
        final kw = (r['keyword'] as String?) ?? '';
        if (kw.isNotEmpty && seen.add(kw)) {
          result.add(_SearchSuggestion(keyword: kw, isTag: false));
        }
      }
      final q = query.toLowerCase();
      for (final t in tags) {
        final tag = (t['tag'] as String?) ?? '';
        if (tag.isEmpty || !seen.add(tag)) continue;
        if (query.isEmpty || tag.toLowerCase().contains(q)) {
          result.add(_SearchSuggestion(keyword: tag, isTag: true));
        }
      }
      return result;
    } catch (e) {
      debugPrint('検索候補の構築に失敗（無視）: $e');
      return <_SearchSuggestion>[];
    }
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
  List<Widget> _buildGoogleDriveSyncTiles(BuildContext context) {
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
        leading: const Icon(Icons.manage_accounts, color: Colors.pinkAccent),
        title: const Text('バックアップ管理'),
        subtitle: const Text('複数のバックアップの一覧・復元・削除'),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BackupManagerScreen()),
          );
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

  // タグ別一括ベクトル化の確認ダイアログ
  Future<void> _showVectorizeConfirmDialog(BuildContext context) async {
    final count = state.novels.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('フィーリング検索の対象に追加'),
        content: Text(
          '表示中の小説$count件をフィーリング検索の対象に追加します。'
          '処理中はアプリを使い続けられます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('追加する'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.vectorizeTagNovels();
    }
  }
}
