/// AIレコメンドフィード画面（第4タブ独立画面）。
///
/// [RecommendationService] の結果を表示する。ロジックはサービス層に委ね、
/// この画面は表示・ユーザー操作のみを担う。
library;

import 'package:flutter/material.dart';

import '../illust_model.dart';
import '../novel_model.dart';
import '../services/recommendation_service.dart';
import '../services/recommendation_math.dart';
import '../widgets/novel_list_card.dart';
import 'ai_index_maintenance_screen.dart';
import 'illust_detail_screen.dart';
import 'novel_detail_screen.dart';

/// AIレコメンドフィード画面。
class AiRecommendFeedScreen extends StatefulWidget {
  const AiRecommendFeedScreen({super.key});

  @override
  State<AiRecommendFeedScreen> createState() => _AiRecommendFeedScreenState();
}

class _AiRecommendFeedScreenState extends State<AiRecommendFeedScreen> {
  final RecommendationService _service = RecommendationService();
  final ScrollController _scrollController = ScrollController();

  RecommendFeedResult? _result;
  bool _isLoading = true;
  String? _error;
  int? _nextNovelOffset;
  int? _nextIllustOffset;
  bool _isFetchingNextPage = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFeed();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 300 &&
        !_isFetchingNextPage &&
        (_nextNovelOffset != null || _nextIllustOffset != null)) {
      _fetchNextPage();
    }
  }

  Future<void> _loadFeed() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final result = await _service.buildFeed();
      if (!mounted) return;
      setState(() {
        _result = result;
        _nextNovelOffset = result.nextNovelOffset;
        _nextIllustOffset = result.nextIllustOffset;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchNextPage() async {
    if (_isFetchingNextPage) return;
    setState(() => _isFetchingNextPage = true);
    try {
      final result = await _service.buildFeed(
        novelOffset: _nextNovelOffset,
        illustOffset: _nextIllustOffset,
      );
      if (!mounted) return;
      setState(() {
        // 無限スクロール: 既存候補を保持したまま新規候補を追記する。
        // buildFeed は都度ローカル検索も再実行するため、重複は排除する。
        final merged = <RecommendCandidate>[...?_result?.candidates];
        final seen = {for (final c in merged) '${c.type}:${c.workId}'};
        for (final c in result.candidates) {
          if (seen.add('${c.type}:${c.workId}')) merged.add(c);
        }
        _result = RecommendFeedResult(
          candidates: merged,
          modelReady: result.modelReady,
          coverageRatio: result.coverageRatio,
          isFallback: result.isFallback,
          nextNovelOffset: result.nextNovelOffset,
          nextIllustOffset: result.nextIllustOffset,
        );
        _nextNovelOffset = result.nextNovelOffset;
        _nextIllustOffset = result.nextIllustOffset;
        _isFetchingNextPage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isFetchingNextPage = false);
    }
  }

  Future<void> _onRefresh() async {
    _service.invalidateCache();
    await _loadFeed();
  }

  void _navigateToDetail(RecommendCandidate candidate) {
    if (candidate.type == 'novel') {
      final novel = Novel.fromJson(candidate.row);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
      );
    } else {
      final illust = Illust.fromJson(candidate.row);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => IllustDetailScreen(illust: illust)),
      );
    }
  }

  void _navigateToMaintenance() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AiIndexMaintenanceScreen()),
    );
  }

  void _navigateToSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _RecommendSettingsScreen()),
    ).then((_) {
      // 設定変更後にキャッシュ無効化＋再読み込み
      _service.invalidateCache();
      _loadFeed();
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= 700;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.recommend, color: colorScheme.primary),
            const SizedBox(width: 8),
            const Text(
              'AIレコメンド',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _navigateToSettings,
            tooltip: 'レコメンド設定',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadFeed,
            tooltip: '再計算',
          ),
        ],
      ),
      body: _buildBody(isTablet, colorScheme),
    );
  }

  Widget _buildBody(bool isTablet, ColorScheme colorScheme) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: colorScheme.primary),
            const SizedBox(height: 16),
            const Text('AI があなたの好みを分析中...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: colorScheme.error),
            const SizedBox(height: 16),
            Text('エラーが発生しました', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadFeed,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ],
        ),
      );
    }

    final result = _result;
    if (result == null || result.candidates.isEmpty) {
      return _buildEmptyState();
    }

    // タブレット／広幅では左に一覧、右に状態・設定パネルを並べる2ペイン構成
    if (isTablet) {
      return Column(
        children: [
          if (result.isFallback || result.coverageRatio < 0.3)
            _buildGuidanceBanner(result),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: RefreshIndicator(
                    onRefresh: _onRefresh,
                    child: _buildGrid(result, 2),
                  ),
                ),
                SizedBox(width: 320, child: _buildSidePanel(result)),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (result.isFallback || result.coverageRatio < 0.3)
          _buildGuidanceBanner(result),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _onRefresh,
            child: _buildList(result),
          ),
        ),
      ],
    );
  }

  /// タブレット右ペイン: 状態サマリー・説明・再計算・設定・メンテ導線。
  Widget _buildSidePanel(RecommendFeedResult result) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ステータス', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _buildStatusRow('モデル', result.modelReady ? '利用可能' : '未導入'),
            const SizedBox(height: 8),
            _buildStatusRow(
              '埋め込みカバレッジ',
              '${(result.coverageRatio * 100).toInt()}%',
            ),
            const SizedBox(height: 8),
            _buildStatusRow('候補数', '${result.candidates.length}'),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              result.modelReady
                  ? '埋め込みカバレッジが低めです。インデックスを充実させると精度が向上します。'
                  : 'AI モデル未導入: API おすすめを表示中。モデルを導入すると精度が向上します。',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('再計算'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _navigateToSettings,
                icon: const Icon(Icons.settings),
                label: const Text('レコメンド設定'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _navigateToMaintenance,
                icon: const Icon(Icons.build),
                label: const Text('インデックス管理'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildGuidanceBanner(RecommendFeedResult result) {
    final colorScheme = Theme.of(context).colorScheme;
    final isModelMissing = !result.modelReady;
    final message = isModelMissing
        ? 'AI モデル未導入: API おすすめを表示中。モデルを導入すると精度が向上します。'
        : '埋め込みカバレッジが低め（${(result.coverageRatio * 100).toInt()}%）。'
              'インデックスを充実させると精度が向上します。';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: colorScheme.tertiary.withValues(alpha: 0.15),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline, color: colorScheme.tertiary),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
          TextButton(
            onPressed: _navigateToMaintenance,
            child: const Text('管理画面へ'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.sentiment_dissatisfied,
            size: 64,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          const Text('おすすめが見つかりませんでした'),
          const SizedBox(height: 8),
          Text(
            '履歴を読むと改善されます',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('再試行'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(RecommendFeedResult result) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      itemCount: result.candidates.length + (_isFetchingNextPage ? 1 : 0),
      itemBuilder: (ctx, index) {
        if (index == result.candidates.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final candidate = result.candidates[index];
        if (candidate.type == 'novel') {
          return _buildNovelCard(candidate);
        } else {
          return _buildIllustCard(candidate);
        }
      },
    );
  }

  Widget _buildGrid(RecommendFeedResult result, int crossAxisCount) {
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(6),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: 0.75,
      ),
      itemCount: result.candidates.length + (_isFetchingNextPage ? 1 : 0),
      itemBuilder: (ctx, index) {
        if (index == result.candidates.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final candidate = result.candidates[index];
        if (candidate.type == 'novel') {
          return _buildNovelCard(candidate);
        } else {
          return _buildIllustCard(candidate);
        }
      },
    );
  }

  Widget _buildNovelCard(RecommendCandidate candidate) {
    final novel = Novel.fromJson(candidate.row);
    final matchLabel = candidate.source == 'local'
        ? '類似度 ${(candidate.score * 100).toInt()}%'
        : 'APIおすすめ';
    return _wrapWithReasonIcon(
      candidate,
      NovelListCard(
        novel: novel,
        onTap: () => _navigateToDetail(candidate),
        matchLabel: matchLabel,
      ),
    );
  }

  Widget _buildIllustCard(RecommendCandidate candidate) {
    final colorScheme = Theme.of(context).colorScheme;
    final illust = Illust.fromJson(candidate.row);
    final matchLabel = candidate.source == 'local'
        ? '類似度 ${(candidate.score * 100).toInt()}%'
        : 'APIおすすめ';
    final previewUrl = illust.urls.preview ?? '';
    final card = Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _navigateToDetail(candidate),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1.0,
              child: previewUrl.isNotEmpty
                  ? Image.network(
                      previewUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, e, s) => ColoredBox(
                        color: colorScheme.surfaceContainerHighest,
                        child: const SizedBox.expand(),
                      ),
                    )
                  : ColoredBox(
                      color: colorScheme.surfaceContainerHighest,
                      child: const SizedBox.expand(),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    illust.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    illust.author.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    matchLabel,
                    style: TextStyle(
                      fontSize: 10,
                      color: candidate.source == 'local'
                          ? colorScheme.primary
                          : colorScheme.tertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return _wrapWithReasonIcon(candidate, card);
  }

  /// Phase N2: 理由がある場合のみカード上に ⓘ アイコンを乗せる。
  Widget _wrapWithReasonIcon(RecommendCandidate candidate, Widget card) {
    final colorScheme = Theme.of(context).colorScheme;
    final reason = candidate.reasons;
    if (reason == null || !reason.hasReasons) return card;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        card,
        Positioned(
          top: 6,
          right: 6,
          child: Tooltip(
            message: 'この作品をおすすめする理由',
            child: InkWell(
              onTap: () => _showReasonSheet(candidate, reason),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: colorScheme.scrim,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.info_outline,
                  size: 15,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Phase N2: 推薦理由説明の BottomSheet。
  void _showReasonSheet(
    RecommendCandidate candidate,
    RecommendationReason reason,
  ) {
    final title = (candidate.row['title'] as String? ?? '').trim();
    final lines = buildReasonSheetLines(reason);
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'この作品をおすすめする理由',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              if (title.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 14),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.psychology_alt,
                        size: 16,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(line, style: const TextStyle(fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              if (reason.matchedTags.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '一致タグ',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in reason.matchedTags.take(8))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '#$t',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (reason.similarToRecentWorks.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '類似元: 「${reason.similarToRecentWorks.first.title}」',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// レコメンド設定画面（履歴件数・お気に入り重み）。
class _RecommendSettingsScreen extends StatefulWidget {
  const _RecommendSettingsScreen();

  @override
  State<_RecommendSettingsScreen> createState() =>
      _RecommendSettingsScreenState();
}

class _RecommendSettingsScreenState extends State<_RecommendSettingsScreen> {
  late TextEditingController _historyLimitController;
  late TextEditingController _favoriteWeightController;
  late TextEditingController _historyWeightController;
  RecommendSettings? _settings;

  @override
  void initState() {
    super.initState();
    _historyLimitController = TextEditingController();
    _favoriteWeightController = TextEditingController();
    _historyWeightController = TextEditingController();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final s = await RecommendSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _historyLimitController.text = s.historyLimit.toString();
      _favoriteWeightController.text = s.favoriteWeight.toString();
      _historyWeightController.text = s.historyWeight.toString();
    });
  }

  Future<void> _save() async {
    final s = _settings;
    if (s == null) return;
    final histLimit =
        int.tryParse(_historyLimitController.text.trim()) ?? s.historyLimit;
    final favWeight =
        double.tryParse(_favoriteWeightController.text.trim()) ??
        s.favoriteWeight;
    final histWeight =
        double.tryParse(_historyWeightController.text.trim()) ??
        s.historyWeight;
    final newSettings = s.copyWith(
      historyLimit: histLimit,
      favoriteWeight: favWeight,
      historyWeight: histWeight,
    );
    await newSettings.save();
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _historyLimitController.dispose();
    _favoriteWeightController.dispose();
    _historyWeightController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('レコメンド設定')),
      body: _settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('嗜好ベクトル', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _historyWeightController,
                  decoration: const InputDecoration(
                    labelText: '履歴の重み（既定 1.0）',
                    border: OutlineInputBorder(),
                    hintText: '1.0',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _favoriteWeightController,
                  decoration: const InputDecoration(
                    labelText: 'お気に入りの重み（既定 2.0）',
                    border: OutlineInputBorder(),
                    hintText: '2.0',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _historyLimitController,
                  decoration: const InputDecoration(
                    labelText: '履歴採用件数（既定 30）',
                    border: OutlineInputBorder(),
                    hintText: '30',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('保存'),
                ),
              ],
            ),
    );
  }
}
