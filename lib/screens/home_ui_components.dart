import 'dart:math' as math;

import 'home_screen_state.dart';
import '../services/pixiv_api_service.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
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

  /// 16d-3: stagger（順次フェードイン）を発動済みの項目数。
  ///
  /// このクラスの各 build 呼び出し（`buildIllustGrid`）が
  /// 一度でも完了したら `true` 相当の状態にする。IndexedStack が
  /// 常に全タブを build するため、ホームの再描画は頻発する。
  /// 「初回描画のみ」という要件を、このカウントで担保する。
  int _staggeredCount = 0;

  HomeUIComponents(this.state);

  Widget _buildSubTabButton({
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(state.context);
    final colorScheme = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isActive
              ? colorScheme.primary.withValues(alpha: 0.3)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: isActive
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs - 2,
      ),
      child: Row(
        children: [
          _buildSubTabButton(
            label: 'おすすめ',
            isActive: activeSubMode == 0,
            onTap: () => state.changeSubMode(0),
          ),
          const SizedBox(width: AppSpacing.sm),
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
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        itemCount: modes.length,
        itemBuilder: (ctx, idx) {
          final theme = Theme.of(ctx);
          final colorScheme = theme.colorScheme;
          final m = modes[idx];
          final isSel = m['value'] == selected;
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.xs,
            ),
            child: ChoiceChip(
              label: Text(
                m['label']?.toString() ?? '',
                style: theme.textTheme.bodySmall,
              ),
              selected: isSel,
              selectedColor: colorScheme.primary.withValues(alpha: 0.3),
              checkmarkColor: colorScheme.primary,
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
      return Center(
        child: Text(
          'フィルターに一致するイラストが見つかりませんでした。',
          style: TextStyle(
            color: Theme.of(state.context).colorScheme.onSurfaceVariant,
          ),
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
        padding: const EdgeInsets.all(AppSpacing.md - 2),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: AppSpacing.md - 2,
          mainAxisSpacing: AppSpacing.md - 2,
          childAspectRatio: 0.75,
        ),
        itemCount: filteredIllusts.length + (state.nextOffset != null ? 1 : 0),
        itemBuilder: (ctx, index) {
          if (index == filteredIllusts.length) {
            return _buildLoadMoreIndicator();
          }
          return _buildStaggeredGridItem(ctx, filteredIllusts[index], index);
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    String? previewUrl;
    try {
      previewUrl =
          illust.urls?.preview ?? illust.urls?.small ?? illust.urls?.medium;
    } catch (_) {}

    // 16d-2: サムネ→詳細の Hero タグ。
    // うごイラは詳細画面側が Hero にならない（フレーム取得Stateが追従できず
    // 崩れる）ため、ここでも付けない。タグの重複を避けるため、このタグを
    // 渡すのはホームグリッドのみとする。
    final heroTag = illust.type == 'ugoira' ? null : 'illust-hero-${illust.id}';

    return RepaintBoundary(
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: 3,
        child: InkWell(
          onTap: () async {
            await Navigator.of(context, rootNavigator: true) // 17b
                .push(
                  MaterialPageRoute(
                    builder: (_) => IllustDetailScreen(
                      illust: illust,
                      heroTag: heroTag,
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
                heroTag == null
                    ? PixivImage(
                        url: previewUrl,
                        fit: BoxFit.cover,
                        isThumbnail: true,
                        cacheWidth: 300,
                        errorWidget: Container(color: Colors.black26),
                      )
                    : Hero(
                        tag: heroTag,
                        child: PixivImage(
                          url: previewUrl,
                          fit: BoxFit.cover,
                          isThumbnail: true,
                          cacheWidth: 300,
                          errorWidget: Container(color: Colors.black26),
                        ),
                      )
              else
                Container(color: Colors.black26),
              // ブックマーク済みハート（左上）
              if (illust.isBookmarked == true)
                Positioned(
                  top: AppSpacing.sm,
                  left: AppSpacing.sm,
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.xs),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
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
                  bottom: AppSpacing.sm,
                  right: AppSpacing.sm,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm - 2,
                      vertical: AppSpacing.xs - 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.bookmark,
                          size: 12,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: AppSpacing.xs - 2),
                        Text(
                          '${illust.totalBookmarks}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white,
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

  /// 16d-3: グリッド項目を順にフェードインさせる（stagger）。
  ///
  /// - 発動条件: 初回描画のみ。追加ロード・スクロール再描画では発動しない
  ///   （[_staggeredCount] を超えたインデックスは何も包まずに返す）。
  /// - 遅延は index * 24ms 相当、最大 8 項目（192ms で頭打ち）。
  /// - AnimationController は使わず TweenAnimationBuilder だけで実装する。
  ///
  /// **仕組み**: アイテムの State は持たないが、インデックスに対して
  /// 一意な ValueKey を使うことで TweenAnimationBuilder の
  /// 「初回だけ 0.0 から開始する」性質を利用する。遅延は [Interval] で
  /// 表現する（240ms のアニメーション幅の中で項目ごとに開始位置をずらす）。
  Widget _buildStaggeredGridItem(
    BuildContext context,
    dynamic illust,
    int index,
  ) {
    final isFirstAppearance = index >= _staggeredCount;
    if (isFirstAppearance) {
      _staggeredCount = index + 1;
    }

    final content = _buildIllustGridItem(context, illust);
    if (!isFirstAppearance) {
      // 2 回目以降の build （追加ロード・スクロール再描画）:
      // 何も包まずにそのまま返す（アニメーションなし）。
      return content;
    }

    // 16d-3: 先頭 8 項目まで index * 24ms の遅延を Interval で表現する。
    // 240ms のアニメーション全体を 20 等分（1 単位 = 12ms）し、
    // index 1 つにつき 2 単位（24ms）ずつ開始を遅らせる。
    final delayFraction = (index < 8 ? index : 8) / 20.0;
    return TweenAnimationBuilder<double>(
      key: ValueKey('grid-stagger-$index'),
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: AppMotion.medium,
      curve: Interval(delayFraction, 1.0, curve: AppMotion.enter),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1.0 - value) * 8.0),
            child: child,
          ),
        );
      },
      child: content,
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
      horiz = AppSpacing.xxl;
      vert = AppSpacing.md - 2;
    } else {
      crossAxisCount = 1;
      horiz = AppSpacing.lg;
      vert = AppSpacing.md - 2;
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
                      crossAxisSpacing: AppSpacing.md,
                      mainAxisSpacing: AppSpacing.md,
                      // カバー高さいっぱい + テキスト収まる余裕（Overflow防止）
                      mainAxisExtent: 156.0,
                    ),
                    delegate: SliverChildBuilderDelegate((ctx, index) {
                      if (index >= itemCount) return const SizedBox.shrink();
                      final novel = state.novels[index];
                      return NovelListCard(
                        novel: novel,
                        onTap: () =>
                            Navigator.of(ctx, rootNavigator: true).push(
                              // 17b
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
                        onTap: () =>
                            Navigator.of(ctx, rootNavigator: true).push(
                              // 17b
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
    final theme = Theme.of(state.context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: colorScheme.onSurfaceVariant),
          const SizedBox(height: AppSpacing.lg),
          Text(
            message,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            subMessage,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadMoreIndicator() {
    final theme = Theme.of(state.context);
    final colorScheme = theme.colorScheme;
    if (state.rateLimited == true) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'アクセス制限が発生しました',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Pixivのアクセス制限（レート制限）が発生しました。\nしばらく時間を置いてから再試行してください。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: CircularProgressIndicator(),
      ),
    );
  }

  Widget buildErrorWidget() {
    final theme = Theme.of(state.context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 64, color: colorScheme.primary),
            const SizedBox(height: AppSpacing.lg),
            Text(
              state.errorMessage?.toString() ?? 'エラーが発生しました',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.error,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            ElevatedButton.icon(
              onPressed: state.fetchData,
              icon: const Icon(Icons.refresh),
              label: const Text('再読み込みする'),
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (state.searchItem == null) return const SizedBox.shrink();
    final item = state.searchItem!;
    final String? iconUrl = item.iconUrl;

    final cardContent = Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
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
                  color: colorScheme.surfaceContainerHighest,
                  child: (iconUrl != null && iconUrl.isNotEmpty)
                      ? PixivImage(
                          url: iconUrl,
                          fit: BoxFit.cover,
                          isThumbnail: true,
                          cacheWidth: 150,
                          width: 50,
                          height: 50,
                          errorWidget: Icon(
                            Icons.bookmark_border,
                            color: colorScheme.primary,
                          ),
                        )
                      : Icon(Icons.bookmark_border, color: colorScheme.primary),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#${item.name}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xs - 2),
                    if (item.wordCount != null)
                      Text(
                        '作品数: ${item.wordCount}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Text(
                        '作品数: 取得できません',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (item.summary.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md - 2),
            Text(
              item.summary,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (item.dicUrl.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.xs,
                    horizontal: AppSpacing.sm,
                  ),
                  child: Text(
                    'ピクシブ百科事典で見る ↗',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.tertiary,
                      fontWeight: FontWeight.bold,
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
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md - 2,
          vertical: AppSpacing.sm - 2,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 4,
        child: cardContent,
      );
    }
    return SizedBox(
      height: math.max(0.0, available),
      child: Card(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md - 2,
          vertical: AppSpacing.sm - 2,
        ),
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

    final theme = Theme.of(state.context);
    return Center(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Google ドライブに同期中...',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // 背景は固定の黒(0.8)オーバーレイ（ライト/ダーク共通）のため、
            // onSurfaceVariant（ライトでは濃いグレー）にせず白系統を維持する。
            Text(
              '処理中...',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
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
    final theme = Theme.of(state.context);
    return Text(
      title,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget buildChoiceChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    final theme = Theme.of(state.context);
    final colorScheme = theme.colorScheme;
    return ChoiceChip(
      label: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: selected
              ? colorScheme.onSurface
              : colorScheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      selected: selected,
      selectedColor: colorScheme.primary.withValues(alpha: 0.8),
      backgroundColor: colorScheme.surfaceContainerHighest,
      elevation: selected ? 2 : 0,
      pressElevation: 4,
      onSelected: (_) => onSelected(),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? colorScheme.primary : Colors.transparent,
          width: 1,
        ),
      ),
    );
  }
}
