import 'dart:async';

import 'package:flutter/material.dart';

import '../models/trending_tag.dart';
import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';
import 'home_screen_state.dart';
import '../services/search_preset_service.dart';
import '../services/discovery_card_service.dart';
import '../novel_model.dart';
import 'novel_detail_screen.dart';
import 'author_profile_screen.dart';

/// Phase 3 検索アシストビュー。
///
/// コンテンツ領域と同一スロットに配置されるためオーバーレイ（被り）は発生しない。
/// - 最近の検索（直近8件・個別削除・すべて削除）
/// - よく使う検索（use_count>=2 の上位8件）
/// - トレンドタグ（上位12件・取得失敗時は非表示）
/// - 入力中の候補（150ms デバウンスで履歴フィルタ）
class SearchAssistView extends StatefulWidget {
  const SearchAssistView({
    super.key,
    required this.state,
    required this.isNovelTab,
  });

  final PixivViewerHomeState state;
  final bool isNovelTab;

  @override
  State<SearchAssistView> createState() => _SearchAssistViewState();
}

class _SearchAssistViewState extends State<SearchAssistView> {
  /// 最近の検索（最新順・上限8件）
  List<Map<String, dynamic>> _recent = [];

  /// よく使う検索（use_count>=2・上位8件）
  List<Map<String, dynamic>> _frequent = [];

  /// トレンドタグ（上位12件）
  List<TrendingTag> _trending = [];

  /// 保存した検索プリセット（Phase N1・現在のタブカテゴリ、上位12件）
  List<SearchPreset> _presets = [];

  /// 入力中の候補（デバウンス後のフィルタ結果）
  List<Map<String, dynamic>> _typedSuggestions = [];

  Timer? _debounce;
  String _lastQuery = '';
  bool _initialFadedIn = false;

  // Phase N4: 今日の再発見カード（非ブロッキング取得・0件なら非表示）
  List<DiscoveryCard> _discovery = [];

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadDiscovery();
    widget.state.addSearchListener(_onExternalChanged);
    // 初回表示の軽いフェード（履歴チップ出現、合計120ms 程度）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _initialFadedIn = true);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.state.removeSearchListener(_onExternalChanged);
    super.dispose();
  }

  /// 外部（履歴チップ操作・検索実行など）で履歴が変わったら再読み込み。
  void _onExternalChanged() {
    if (!mounted) return;
    _loadHistory();
    _loadPresets();
    _applyTypedFilter(widget.state.searchController.text);
  }

  Future<void> _loadAll() async {
    await _loadHistory();
    await _loadTrending();
    await _loadPresets();
    _applyTypedFilter(widget.state.searchController.text);
  }

  Future<void> _loadHistory() async {
    try {
      final db = DatabaseService();
      final recent = await db.searchSearchHistory(orderBy: 'recent');
      final frequent = await db.searchSearchHistory(orderBy: 'use_count');
      if (!mounted) return;
      setState(() {
        _recent = recent.take(8).toList();
        _frequent = frequent
            .where((r) => ((r['use_count'] as int?) ?? 0) >= 2)
            .take(8)
            .toList();
      });
    } catch (e) {
      debugPrint('検索履歴の読み込みに失敗（無視）: $e');
      if (mounted) {
        setState(() {
          _recent = [];
          _frequent = [];
        });
      }
    }
  }

  Future<void> _loadTrending() async {
    // キャッシュ済みなら再取得しない（スラッシュ防止）
    final cacheKey = widget.isNovelTab ? 'novel' : 'illust';
    final cached = widget.state.getTrendingTagCache(cacheKey);
    if (cached != null) {
      if (mounted) setState(() => _trending = cached.take(12).toList());
      return;
    }
    try {
      final tags = await PixivApiService().getTrendingTags(cacheKey);
      widget.state.setTrendingTagCache(cacheKey, tags);
      if (!mounted) return;
      setState(() => _trending = tags.take(12).toList());
    } catch (_) {
      // 取得失敗時は静かに非表示
      if (mounted) setState(() => _trending = []);
    }
  }

  /// 入力中：150ms デバウンス後に履歴をフィルタ（候補はコンテンツに被らない）。
  void _applyTypedFilter(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      if (_lastQuery.isNotEmpty) {
        _lastQuery = '';
        if (mounted) setState(() => _typedSuggestions = []);
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      try {
        final rows = await DatabaseService().searchSearchHistory(query: q);
        if (!mounted) return;
        setState(() {
          _lastQuery = q;
          _typedSuggestions = rows.take(8).toList();
        });
      } catch (_) {
        if (mounted) setState(() => _typedSuggestions = []);
      }
    });
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('検索履歴をすべて削除'),
        content: const Text('すべての検索履歴を削除しますか？この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.state.clearDbSearchHistory();
    _onExternalChanged();
  }

  Future<void> _deleteOne(String keyword) async {
    await widget.state.deleteDbSearchHistoryItem(keyword);
    _onExternalChanged();
  }

  // -------------------------------------------------------------------------
  // Phase N1: 保存した検索（プリセット）
  // -------------------------------------------------------------------------

  Future<void> _loadPresets() async {
    try {
      final all = await SearchPresetService().load();
      final cat = widget.isNovelTab ? 'novel' : 'illust';
      if (!mounted) return;
      setState(() {
        _presets = sortPresetsByUse(
          all.where((p) => p.category == cat).toList(),
        ).take(12).toList();
      });
    } catch (_) {
      if (mounted) setState(() => _presets = const []);
    }
  }

  /// タップ: 条件を復元して即検索。
  Future<void> _restorePreset(SearchPreset preset) async {
    await widget.state.restoreSearchPreset(preset);
    _loadPresets();
  }

  /// 長押し: メニュー（名前変更 / 削除）。
  Future<void> _showPresetMenu(SearchPreset preset) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('プリセット「${preset.name}」'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'rename'),
            child: const Text('名前を変更'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('削除', style: TextStyle(color: Colors.redAccent)),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );
    if (action == 'rename') {
      await _renamePreset(preset);
    } else if (action == 'delete') {
      await _deletePreset(preset);
    }
  }

  Future<void> _renamePreset(SearchPreset preset) async {
    final controller = TextEditingController(text: preset.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プリセットの名前を変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'プリセット名'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('変更'),
          ),
        ],
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    if (ok != true || !mounted || name.isEmpty) return;
    await SearchPresetService().rename(preset.id, name);
    _loadPresets();
  }

  Future<void> _deletePreset(SearchPreset preset) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プリセットを削除'),
        content: Text('プリセット「${preset.name}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await SearchPresetService().delete(preset.id);
    _loadPresets();
  }

  Widget _buildPresetChip(SearchPreset preset, int index) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('preset-${preset.id}'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 40 + (index * 12).clamp(0, 80)),
      curve: Curves.easeOutCubic,
      builder: (ctx, v, child) => Opacity(opacity: v, child: child),
      child: GestureDetector(
        onLongPress: () => _showPresetMenu(preset),
        child: ActionChip(
          avatar: const Icon(Icons.bookmark, size: 14),
          label: Text(
            preset.name,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => _restorePreset(preset),
        ),
      ),
    );
  }

  void _runSearch(String keyword) {
    widget.state.searchController.text = keyword;
    widget.state.onSearchSubmit(keyword);
  }

  // -------------------------------------------------------------------------
  // Phase N4: 今日の再発見カード
  // -------------------------------------------------------------------------

  Future<void> _loadDiscovery() async {
    try {
      final cards = await DiscoveryCardService().fetch();
      if (!mounted) return;
      setState(() => _discovery = cards);
    } catch (_) {
      if (mounted) setState(() => _discovery = const []);
    }
  }

  Future<void> _openDiscovery(DiscoveryCard card) async {
    switch (card.tapTarget) {
      case DiscoveryTapTarget.searchTag:
        final tag = card.tag ?? '';
        if (tag.isNotEmpty) _runSearch(tag);
        break;
      case DiscoveryTapTarget.openNovel:
        await _openDiscoveryNovel(card.workId ?? 0);
        break;
      case DiscoveryTapTarget.openAuthor:
        final authorId = card.authorId ?? 0;
        if (authorId <= 0) return;
        if (!mounted) return;
        await Navigator.of(context, rootNavigator: true).push(
          // 17b
          MaterialPageRoute(
            builder: (_) => AuthorProfileScreen(userId: authorId),
          ),
        );
        break;
    }
  }

  Future<void> _openDiscoveryNovel(int workId) async {
    if (workId <= 0) return;
    try {
      Novel? novel;
      try {
        novel = await DatabaseService().getNovelMeta(workId);
      } catch (_) {
        novel = null;
      }
      novel ??= await PixivApiService().getNovelById(workId);
      if (!mounted) return;
      final target = novel;
      await Navigator.of(context, rootNavigator: true).push(
        // 17b
        MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: target)),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('作品を開けませんでした')));
      }
    }
  }

  ({IconData icon, Color accent}) _discoveryStyle(
    DiscoveryCardKind kind,
    ColorScheme colorScheme,
  ) {
    switch (kind) {
      case DiscoveryCardKind.dormantTag:
        return (icon: Icons.tag, accent: colorScheme.tertiary);
      case DiscoveryCardKind.seriesNext:
        return (icon: Icons.auto_stories, accent: colorScheme.primary);
      case DiscoveryCardKind.longUnseenAuthor:
        return (icon: Icons.person_search, accent: colorScheme.secondary);
      case DiscoveryCardKind.downloadedUnread:
        return (icon: Icons.download_done, accent: colorScheme.primary);
    }
  }

  Widget _buildDiscoveryCard(DiscoveryCard c) {
    final colorScheme = Theme.of(context).colorScheme;
    final style = _discoveryStyle(c.kind, colorScheme);
    return InkWell(
      onTap: () => _openDiscovery(c),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: style.accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(style.icon, size: 18, color: style.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 描画
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final typing = _lastQuery.isNotEmpty;
    final body = AnimatedOpacity(
      opacity: _initialFadedIn ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      child:
          _recent.isEmpty &&
              _frequent.isEmpty &&
              _presets.isEmpty &&
              _discovery.isEmpty &&
              !typing
          ? _buildEmptyState()
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                if (_discovery.isNotEmpty && !typing) ...[
                  _buildSectionHeader('今日の再発見', icon: Icons.auto_awesome),
                  for (final c in _discovery) _buildDiscoveryCard(c),
                  const SizedBox(height: 12),
                ],
                if (typing) ...[
                  _buildSectionHeader('候補', icon: Icons.search),
                  if (_typedSuggestions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '一致する履歴はありません',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    )
                  else
                    _buildChipWrap(
                      _typedSuggestions
                          .map((r) => _keywordOf(r))
                          .where((k) => k.isNotEmpty)
                          .toList(),
                      icon: Icons.history,
                      accent: colorScheme.onSurfaceVariant,
                      deletable: true,
                    ),
                ],
                if (_recent.isNotEmpty) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _buildSectionHeader(
                          '最近の検索',
                          icon: Icons.history,
                        ),
                      ),
                      TextButton(
                        onPressed: _confirmClearAll,
                        child: Text(
                          'すべて削除',
                          style: TextStyle(
                            color: colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  _buildChipWrap(
                    _recent
                        .map((r) => _keywordOf(r))
                        .where((k) => k.isNotEmpty)
                        .toList(),
                    icon: Icons.history,
                    accent: colorScheme.onSurfaceVariant,
                    deletable: true,
                  ),
                ],
                if (_presets.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildSectionHeader('保存した検索', icon: Icons.bookmark_border),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (var i = 0; i < _presets.length; i++)
                        _buildPresetChip(_presets[i], i),
                    ],
                  ),
                ],
                if (_frequent.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildSectionHeader('よく使う検索', icon: Icons.star),
                  _buildChipWrap(
                    _frequent
                        .map((r) => _keywordOf(r))
                        .where((k) => k.isNotEmpty)
                        .toList(),
                    icon: Icons.star,
                    accent: colorScheme.secondary,
                    emphasized: true,
                  ),
                ],
                if (_trending.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildSectionHeader(
                    'トレンドタグ',
                    icon: Icons.local_fire_department,
                  ),
                  _buildChipWrap(
                    _trending.map((t) => t.tag).toList(),
                    icon: Icons.tag,
                    accent: colorScheme.tertiary,
                    saturated: true,
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
    return body;
  }

  String _keywordOf(Map<String, dynamic> row) =>
      ((row['keyword'] as String?) ?? '').trim();

  Widget _buildSectionHeader(String title, {required IconData icon}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// 履歴チップを折り返し付きで描画。初回のみ軽い staggered フェード（合計120ms）。
  Widget _buildChipWrap(
    List<String> keywords, {
    required IconData icon,
    required Color accent,
    bool deletable = false,
    bool emphasized = false,
    bool saturated = false,
  }) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (var i = 0; i < keywords.length; i++)
          TweenAnimationBuilder<double>(
            key: ValueKey('${icon.hashCode}-$i-${keywords[i]}'),
            tween: Tween(begin: 0.0, end: 1.0),
            duration: Duration(milliseconds: 40 + (i * 12).clamp(0, 80)),
            curve: Curves.easeOutCubic,
            builder: (ctx, v, child) => Opacity(opacity: v, child: child),
            child: _buildChip(
              keywords[i],
              icon: icon,
              accent: accent,
              deletable: deletable,
              emphasized: emphasized,
              saturated: saturated,
            ),
          ),
      ],
    );
  }

  Widget _buildChip(
    String keyword, {
    required IconData icon,
    required Color accent,
    required bool deletable,
    required bool emphasized,
    required bool saturated,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final chipColor = saturated
        ? accent.withValues(alpha: 0.18)
        : emphasized
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainerHigh;
    final label = Text(
      keyword,
      style: TextStyle(
        color: emphasized
            ? colorScheme.onSurface
            : colorScheme.onSurfaceVariant,
        fontSize: 12,
        fontWeight: emphasized ? FontWeight.w600 : FontWeight.normal,
      ),
    );
    final side = BorderSide(color: accent.withValues(alpha: 0.35));
    if (deletable) {
      // 履歴チップ: タップで検索、×（deleteIcon）で個別削除。
      return InputChip(
        avatar: Icon(icon, size: 14, color: accent),
        label: label,
        backgroundColor: chipColor,
        side: side,
        deleteIconColor: colorScheme.onSurfaceVariant,
        onPressed: () => _runSearch(keyword),
        onDeleted: () => _deleteOne(keyword),
      );
    }
    return ActionChip(
      avatar: Icon(icon, size: 14, color: accent),
      label: label,
      backgroundColor: chipColor,
      side: side,
      onPressed: () => _runSearch(keyword),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 48,
              color: Colors.grey.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            const Text(
              'まだ検索履歴がありません',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '気になるタグや作品名を検索してみましょう',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
