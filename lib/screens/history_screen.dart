import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../novel_model.dart';
import '../illust_model.dart' show Author;
import 'novel_detail_screen.dart';
import '../services/database_service.dart';
import '../services/database_search.dart';
import '../services/embedding_service.dart';
import '../services/pixiv_api_service.dart';

/// 閲覧履歴画面
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final DatabaseService _databaseService = DatabaseService();
  List<Map<String, dynamic>> _historyList = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await _databaseService.getHistoryList();
      if (mounted) {
        setState(() {
          _historyList = history;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _navigateToDetail(Map<String, dynamic> item) async {
    final workType = item['work_type'] ?? 'illust';
    final workId = item['work_id'] ?? 0;
    if (workType == 'novel') {
      try {
        // Novel オブジェクトを取得
        final novel = await PixivApiService().getNovelById(workId);
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => NovelDetailScreen(novel: novel),
            ),
          );
        }
      } catch (e) {
        // エラー時は簡易表示
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('小説の詳細を取得できませんでした: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('閲覧履歴'),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _historyList.isEmpty
          ? const Center(
              child: Text('閲覧履歴はありません', style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              itemCount: _historyList.length,
              itemBuilder: (context, index) {
                final item = _historyList[index];
                return ListTile(
                  title: Text(item['title'] ?? '無題'),
                  subtitle: Text(item['author_name'] ?? ''),
                  onTap: () => _navigateToDetail(item),
                );
              },
            ),
    );
  }
}

class FeelingDiscoveryScreen extends StatefulWidget {
  const FeelingDiscoveryScreen({super.key});

  @override
  State<FeelingDiscoveryScreen> createState() => _FeelingDiscoveryScreenState();
}

class _FeelingDiscoveryScreenState extends State<FeelingDiscoveryScreen> {
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isSearching = false;
  bool _isLoadingMore = false;
  bool _isModelReady = false;
  bool _isModelInitializing = false;
  String _lastQuery = '';
  List<Map<String, dynamic>> _results = [];
  double? _lastMinSimilarity;

  static const int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadSearchHistory();
    _initializeModel();
  }

  Future<void> _initializeModel() async {
    if (!mounted) return;
    setState(() => _isModelInitializing = true);

    try {
      await EmbeddingService().initialize();
      if (mounted) {
        final service = EmbeddingService();
        setState(() {
          _isModelReady = service.isInitialized;
          _isModelInitializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isModelReady = false;
          _isModelInitializing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('feeling_search_history') ?? [];
    if (history.isNotEmpty && mounted) {
      setState(() {
        _queryController.text = history.first;
      });
    }
  }

  Future<void> _saveSearchHistory(String query) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList('feeling_search_history') ?? [];
    history.remove(query);
    history.insert(0, query);
    if (history.length > 10) history = history.sublist(0, 10);
    await prefs.setStringList('feeling_search_history', history);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _search({bool isLoadMore = false}) async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;

    if ((!_isModelReady || _isModelInitializing) && !isLoadMore) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('AIモデルの準備中です。少々お待ちください。')));
      return;
    }

    if (!isLoadMore) {
      FocusScope.of(context).unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');

      setState(() {
        _isSearching = true;
        _results.clear();
        _lastQuery = query;
        _lastMinSimilarity = null;
      });
    } else {
      if (_isLoadingMore) return;
      setState(() => _isLoadingMore = true);
    }

    if (!isLoadMore) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
    }

    try {
      final embeddingService = EmbeddingService();
      await embeddingService.initialize();

      final queryEmbedding = await embeddingService.encode(query);
      final db = await DatabaseService().database;

      final results = await searchNovelsByEmbedding(
        db: db,
        userEmbedding: queryEmbedding,
        limit: _pageSize,
        minSimilarity: _lastMinSimilarity ?? 0.0,
      );

      if (!isLoadMore) {
        if (mounted) {
          setState(() {
            _results = results;
            _isSearching = false;
            if (results.isNotEmpty) {
              _lastMinSimilarity = results.last['similarity'] as double?;
            }
          });
          _saveSearchHistory(query);
        }
      } else {
        if (mounted) {
          setState(() {
            _results.addAll(results);
            _isLoadingMore = false;
            if (results.isNotEmpty) {
              _lastMinSimilarity = results.last['similarity'] as double?;
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _isLoadingMore = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('検索エラー: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  Future<void> _loadMore() async {
    if (_lastQuery.isEmpty) return;
    await _search(isLoadMore: true);
  }

  void _onQuerySubmitted(String query) {
    _search();
  }

  void _navigateToDetail(Map<String, dynamic> item) {
    final novel = Novel(
      id: item['work_id'] as int? ?? 0,
      title: item['title'] as String? ?? '',
      caption: item['caption'] as String? ?? '',
      author: Author(
        id: item['author_id'] as int? ?? 0,
        name: item['author_name'] as String? ?? '不明',
        account: '',
      ),
      tags: [],
      coverUrl: item['preview_url'] as String? ?? '',
      textCount: item['text_length'] as int? ?? 0,
      wordCount: 0,
      textLength: item['text_length'] as int? ?? 0,
      pageCount: item['page_count'] as int? ?? 0,
      createDate: item['create_date'] as String? ?? '',
      totalView: item['total_view'] as int? ?? 0,
      totalBookmarks: item['total_bookmarks'] as int? ?? 0,
      isBookmarked: false,
    );

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('フィーリング発掘'),
        backgroundColor: isDark ? const Color(0xFF222222) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 0.5,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _queryController,
              enabled: !_isModelInitializing,
              decoration: InputDecoration(
                hintText: _isModelInitializing
                    ? 'AIモデルを初期化中... 少々お待ちください'
                    : '今の気分・キーワードを入力（例: 切ない春、ドキドキする恋愛、癒やされる日常）',
                hintStyle: TextStyle(
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
                  fontSize: 14,
                ),
                prefixIcon: _isModelInitializing
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: isDark
                                ? Colors.grey.shade500
                                : Colors.grey.shade600,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.search,
                        color: isDark
                            ? Colors.grey.shade500
                            : Colors.grey.shade600,
                      ),
                suffixIcon:
                    _queryController.text.isNotEmpty && !_isModelInitializing
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          color: isDark
                              ? Colors.grey.shade500
                              : Colors.grey.shade600,
                        ),
                        onPressed: () {
                          _queryController.clear();
                          setState(() {});
                        },
                      )
                    : null,
                filled: true,
                fillColor: isDark
                    ? const Color(0xFF2A2A2A)
                    : Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black,
                fontSize: 15,
              ),
              onSubmitted: _isModelInitializing ? null : _onQuerySubmitted,
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
      ),
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_lastQuery.isEmpty) {
      return _buildEmptyState(isDark);
    }

    if (_isSearching && _results.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('意味ベクトルで検索中...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.sentiment_dissatisfied,
              size: 64,
              color: isDark ? Colors.grey.shade700 : Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              '「$_lastQuery」に合う作品が見つかりませんでした',
              style: TextStyle(
                fontSize: 16,
                color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '別のキーワードや気分を試してみてください',
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.grey.shade600 : Colors.grey.shade500,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _search(),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: _results.length + (_isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _results.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            );
          }

          final item = _results[index];
          final similarity = item['similarity'] as double? ?? 0.0;
          final similarityPercent = (similarity * 100).toStringAsFixed(1);

          return _buildResultCard(item, similarityPercent, isDark, index);
        },
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final service = EmbeddingService();
    if (service.initError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: isDark ? Colors.redAccent.shade200 : Colors.redAccent,
              ),
              const SizedBox(height: 16),
              Text(
                'AIモデルの初期化に失敗しました',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'エラー詳細: ${service.initError}',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  setState(() => _isModelInitializing = true);
                  EmbeddingService().initialize().then((_) {
                    if (mounted) {
                      final service = EmbeddingService();
                      setState(() {
                        _isModelReady = service.isInitialized;
                        _isModelInitializing = false;
                      });
                    }
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('再試行'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark
                      ? Colors.pinkAccent.shade200
                      : Colors.pinkAccent,
                  foregroundColor: isDark ? Colors.black : Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isModelReady) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _isModelInitializing ? 'AIモデルを初期化中...' : 'AIモデルを準備中...',
                style: TextStyle(
                  fontSize: 16,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '初回起動時は数秒かかる場合があります',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(60),
              ),
              child: Icon(
                Icons.auto_awesome,
                size: 60,
                color: isDark ? Colors.pinkAccent.shade200 : Colors.pinkAccent,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'フィーリング発掘',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '今の気分やキーワードを入力すると、\nAIが意味で似た小説を探し出します',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildSuggestionChip('切ない春', isDark),
                _buildSuggestionChip('ドキドキする恋愛', isDark),
                _buildSuggestionChip('癒やされる日常', isDark),
                _buildSuggestionChip('胸が熱くなる冒険', isDark),
                _buildSuggestionChip('不思議な世界観', isDark),
                _buildSuggestionChip('笑えるコメディ', isDark),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '※ ローカルONNXモデルによる完全オフライン検索\n※ R-18作品も含めて意味検索可能',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.grey.shade600 : Colors.grey.shade500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionChip(String label, bool isDark) {
    final isDisabled = !_isModelReady || _isModelInitializing;
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      backgroundColor: isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade100,
      side: BorderSide(
        color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
      ),
      onPressed: isDisabled
          ? null
          : () {
              _queryController.text = label;
              _search();
            },
    );
  }

  Widget _buildResultCard(
    Map<String, dynamic> item,
    String similarityPercent,
    bool isDark,
    int index,
  ) {
    final title = item['title'] as String? ?? '';
    final authorName = item['author_name'] as String? ?? '不明';
    final previewUrl = item['preview_url'] as String?;
    final textLength = item['text_length'] as int? ?? 0;
    final pageCount = item['page_count'] as int? ?? 0;
    final createDate = item['create_date'] as String? ?? '';
    final totalBookmarks = item['total_bookmarks'] as int? ?? 0;
    final caption = item['caption'] as String? ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isDark ? const Color(0xFF222222) : Colors.white,
      elevation: 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
        ),
      ),
      child: InkWell(
        onTap: () => _navigateToDetail(item),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 80,
                  height: 112,
                  child: previewUrl != null && previewUrl.isNotEmpty
                      ? Image.network(
                          previewUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              _buildPlaceholderCover(isDark),
                        )
                      : _buildPlaceholderCover(isDark),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.pinkAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$similarityPercent% 一致',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.pinkAccent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      authorName,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark
                            ? Colors.grey.shade400
                            : Colors.grey.shade600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    if (caption.isNotEmpty)
                      Text(
                        caption,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? Colors.grey.shade500
                              : Colors.grey.shade600,
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 16,
                      runSpacing: 4,
                      children: [
                        if (textLength > 0)
                          _buildMetaChip(
                            Icons.text_fields,
                            '${(textLength / 1000).toStringAsFixed(1)}k字',
                            isDark,
                          ),
                        if (pageCount > 0)
                          _buildMetaChip(
                            Icons.menu_book,
                            '$pageCountページ',
                            isDark,
                          ),
                        if (totalBookmarks > 0)
                          _buildMetaChip(
                            Icons.bookmark_border,
                            _formatNumber(totalBookmarks),
                            isDark,
                          ),
                        if (createDate.isNotEmpty)
                          _buildMetaChip(
                            Icons.calendar_today,
                            _formatDate(createDate),
                            isDark,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderCover(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade200,
      child: Icon(
        Icons.menu_book,
        color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
        size: 32,
      ),
    );
  }

  Widget _buildMetaChip(IconData icon, String label, bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 13,
          color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  String _formatNumber(int number) {
    if (number >= 10000) {
      return '${(number / 10000).toStringAsFixed(1)}万';
    }
    return number.toString();
  }

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return dateStr;
    }
  }
}
