import 'package:flutter/material.dart';
import '../widgets/pixiv_image.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../novel_model.dart';
import '../illust_model.dart' show Author, cleanCaption;
import 'novel_detail_screen.dart';
import '../services/database_service.dart';
import '../services/database_search.dart';
import '../services/embedding_service.dart';
import '../services/ruri_model_manager.dart';

/// タブレット判定閾値: <700=1列, 700以上=2列
/// （home_ui_components.dart の _kTabletBreakpoint は private かつ循環参照を
///  避けるためローカル定義。値は同一に保つ）
/// 類似度の表示下限（これより低い作品は「近い作品が見つかりませんでした」扱い）
const double kMinDisplaySimilarity = 0.75;

const double kTabletBreakpoint = 700.0;
const double kTabletContentMaxWidth = 800.0;

/// フィーリング発掘画面
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
  bool _hasMore = true;
  bool _isModelReady = false;
  bool _isModelInitializing = false; // AIモデル初期化中フラグ
  bool _isModelDownloaded = false; // モデルファイルが端末に存在し検証済みか
  bool _isDownloading = false;
  int _dlReceived = 0;
  int _dlTotal = 0;
  String _dlLabel = '';
  String? _dlError;
  ValueNotifier<bool>? _dlCancel;
  String _lastQuery = '';
  List<Map<String, dynamic>> _results = [];
  double? _lastMinSimilarity;
  // 重複排除用：表示済み work_id を保持（検索クエリ変更時にクリア）
  final Set<int> _displayedWorkIds = {};

  static const int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadSearchHistory();

    // ONNXモデルをバックグラウンドで事前初期化（ウォームアップ）
    _initializeModel();
  }

  Future<void> _initializeModel() async {
    if (!mounted) return;
    setState(() => _isModelInitializing = true);

    try {
      // 未ダウンロードなら初期化せず、DL 導線を表示する
      final downloaded = await RuriModelManager().isModelReady();
      if (!mounted) return;
      setState(() => _isModelDownloaded = downloaded);
      if (!downloaded) {
        setState(() {
          _isModelReady = false;
          _isModelInitializing = false;
        });
        return;
      }
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
    _dlCancel?.dispose();
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// モデルをダウンロードし、完了後に初期化まで進める。
  Future<void> _startDownload() async {
    if (_isDownloading) return;
    final cancel = ValueNotifier<bool>(false);
    _dlCancel?.dispose();
    _dlCancel = cancel;
    setState(() {
      _isDownloading = true;
      _dlError = null;
      _dlReceived = 0;
      _dlTotal = 0;
      _dlLabel = '';
    });
    try {
      await RuriModelManager().download(
        cancel: cancel,
        onProgress: (received, total, label) {
          if (!mounted) return;
          setState(() {
            _dlReceived = received;
            _dlTotal = total;
            _dlLabel = label;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _isModelDownloaded = true;
      });
      await _initializeModel();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _dlError = e.toString();
      });
    }
  }

  void _cancelDownload() {
    _dlCancel?.value = true;
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// モデル未ダウンロード時の導線 UI
  Widget _buildModelDownloadPrompt(bool isDark) {
    final subColor = isDark ? Colors.grey.shade400 : Colors.grey.shade700;
    final progress = (_dlTotal > 0)
        ? (_dlReceived / _dlTotal).clamp(0.0, 1.0)
        : null;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 64, color: subColor),
              const SizedBox(height: 16),
              const Text(
                'フィーリング発掘を使うには AI モデルが必要です',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                '日本語に特化した検索用 AI モデル（${RuriModelManager.modelSizeDescription}）を'
                '端末にダウンロードします。ダウンロード後はオフラインでも意味検索が使えます。',
                style: TextStyle(fontSize: 14, color: subColor),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '※ 通信量が大きいため Wi-Fi 接続での実行を推奨します',
                style: TextStyle(fontSize: 13, color: Colors.orange.shade700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_isDownloading) ...[
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 12),
                Text(
                  progress != null
                      ? '$_dlLabel ${_formatBytes(_dlReceived)} / '
                            '${_formatBytes(_dlTotal)} '
                            '(${(progress * 100).toStringAsFixed(1)}%)'
                      : '$_dlLabel ${_formatBytes(_dlReceived)} ダウンロード中...',
                  style: TextStyle(fontSize: 13, color: subColor),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: _cancelDownload,
                  icon: const Icon(Icons.close),
                  label: const Text('キャンセル'),
                ),
              ] else ...[
                if (_dlError != null) ...[
                  Text(
                    'ダウンロードに失敗しました: $_dlError',
                    style: TextStyle(fontSize: 13, color: Colors.red.shade400),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                ],
                FilledButton.icon(
                  onPressed: _startDownload,
                  icon: Icon(_dlError != null ? Icons.refresh : Icons.download),
                  label: Text(_dlError != null ? '再試行' : 'モデルをダウンロード'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 初期化中の表示
  Widget _buildModelInitializing(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'AI モデルを初期化しています...',
            style: TextStyle(
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
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
    if (!_hasMore || _isLoadingMore) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _search({bool isLoadMore = false}) async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;

    // モデルが未準備または初期化中なら検索不可
    if ((!_isModelReady || _isModelInitializing) && !isLoadMore) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('AIモデルの準備中です。少々お待ちください。')));
      return;
    }

    if (!isLoadMore) {
      // キーボードを閉じる
      FocusScope.of(context).unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');

      setState(() {
        _isSearching = true;
        _results.clear();
        _lastQuery = query;
        _lastMinSimilarity = null;
        _displayedWorkIds.clear();
        _hasMore = true;
      });
    } else {
      if (_isLoadingMore) return;
      setState(() => _isLoadingMore = true);
    }

    // UIの描画とキーボードが閉じるアニメーションを完了させるために少し待機
    if (!isLoadMore) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
    }

    try {
      final embeddingService = EmbeddingService();
      await embeddingService.initialize();

      final queryEmbedding = await embeddingService.encodeQuery(query);

      final db = await DatabaseService().database;
      final results = await searchNovelsByEmbedding(
        db: db,
        userEmbedding: queryEmbedding,
        limit: _pageSize,
        minSimilarity: _lastMinSimilarity ?? kMinDisplaySimilarity,
      );

      List<Map<String, dynamic>> merged = results;

      // フォールバックはベクトル検索が本当に少ない場合のみ（最初の検索のみ）
      if (!isLoadMore && results.length < 5) {
        final excludeIds = results.map((r) => r['id'] as int).toSet();
        final fallback = await searchNovelsByKeywordFallback(
          db: db,
          query: query,
          excludeWorkIds: excludeIds,
        );
        // 既存結果の後ろにキーワード一致を追加（work_id 重複は除外済み）
        merged = [...results, ...fallback];
      }

      // 重複排除：既に表示済みの work_id を除外（ページネーションのループ防止）
      final newItems = merged
          .where((item) => !_displayedWorkIds.contains(item['id'] as int))
          .toList();

      if (newItems.isEmpty) {
        // これ以上新しい結果がない
        if (mounted) {
          setState(() {
            _hasMore = false;
            _isSearching = false;
            _isLoadingMore = false;
          });
        }
        return;
      }

      _displayedWorkIds.addAll(newItems.map((item) => item['id'] as int));

      if (!isLoadMore) {
        if (mounted) {
          setState(() {
            _results = newItems;
            _isSearching = false;
            // ベクトル検索結果（similarity非null）があればそれで閾値を更新
            final vectorMax = results
                .where((r) => r['similarity'] != null)
                .map((r) => r['similarity'] as double)
                .fold<double?>(
                  null,
                  (max, v) => max == null || v > max ? v : max,
                );
            if (vectorMax != null) {
              _lastMinSimilarity = vectorMax;
            }
            // ベクトル検索が0件なら終端（フォールバックのみなので追加読込しない）
            _hasMore = results.isNotEmpty;
          });
          _saveSearchHistory(query);
        }
      } else {
        if (mounted) {
          setState(() {
            _results.addAll(newItems);
            _isLoadingMore = false;
            // 次ページの閾値はベクトル検索結果（similarity非null）の最小値
            final vectorSims = results
                .where((r) => r['similarity'] != null)
                .map((r) => r['similarity'] as double)
                .toList();
            if (vectorSims.isNotEmpty) {
              _lastMinSimilarity = vectorSims.last;
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
      caption: cleanCaption(item['description'] as String? ?? ''),
      author: Author(
        id: item['author_id'] as int? ?? 0,
        name: item['author_name'] as String? ?? '不明',
        account: '',
      ),
      tags: [],
      coverUrl: item['cover_url'] as String? ?? '',
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
              enabled: !_isModelInitializing, // AI初期化中は入力無効
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
    // モデル未ダウンロード → DL 導線
    if (!_isModelDownloaded) {
      return _buildModelDownloadPrompt(isDark);
    }
    // DL 済みだが未初期化 → 初期化中表示
    if (_isModelInitializing) {
      return _buildModelInitializing(isDark);
    }

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

    // 検索したが0件ヒット（novel_embeddings にデータはあるが類似度未満）
    if (_results.isEmpty) {
      return SingleChildScrollView(
        child: SizedBox(
          height:
              MediaQuery.of(context).size.height -
              (MediaQuery.of(context).padding.top +
                  kToolbarHeight +
                  MediaQuery.of(context).padding.bottom),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
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
                const SizedBox(height: 8),
                Text(
                  '（類似度 ${kMinDisplaySimilarity.toStringAsFixed(2)} 以上の作品のみ表示）',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.grey.shade600 : Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= kTabletBreakpoint;
    final crossAxisCount = isTablet ? 2 : 1;
    final horiz = isTablet ? 24.0 : 16.0;
    final vert = isTablet ? 12.0 : 16.0;

    return RefreshIndicator(
      onRefresh: () => _search(),
      child: CustomScrollView(
        controller: _scrollController,
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
                      childAspectRatio: 2.6,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (ctx, index) =>
                          _buildGridOrListCard(index, isDark, isTablet: true),
                      childCount:
                          _results.length +
                          ((_isLoadingMore && _hasMore) ? 1 : 0),
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, index) =>
                          _buildGridOrListCard(index, isDark, isTablet: false),
                      childCount:
                          _results.length +
                          ((_isLoadingMore && _hasMore) ? 1 : 0),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// インデックスに応じたカードまたはローディングインジケータを返す
  /// （タブレット=2列グリッド、スマホ=1列リスト共通）
  Widget _buildGridOrListCard(
    int index,
    bool isDark, {
    required bool isTablet,
  }) {
    if (index >= _results.length) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final item = _results[index];
    final similarity = item['similarity'] as double?;
    final similarityPercent = similarity != null
        ? (similarity * 100).toStringAsFixed(1)
        : null;
    final isKeywordMatch = item['is_keyword_match'] == 1;

    return _buildResultCard(
      item,
      similarityPercent,
      isDark,
      index,
      isKeywordMatch: isKeywordMatch,
    );
  }

  Widget _buildEmptyState(bool isDark) {
    // 初期化エラーがある場合はエラー表示
    final service = EmbeddingService();
    if (service.initError != null) {
      final screenWidth = MediaQuery.of(context).size.width;
      final isTablet = screenWidth >= kTabletBreakpoint;
      return SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isTablet ? kTabletContentMaxWidth : double.infinity,
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: isDark
                        ? Colors.redAccent.shade200
                        : Colors.redAccent,
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
                      color: isDark
                          ? Colors.grey.shade400
                          : Colors.grey.shade600,
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
          ),
        ),
      );
    }

    // モデル未準備時は準備中表示（初期化中も含む）
    if (!_isModelReady || _isModelInitializing) {
      return SingleChildScrollView(
        child: SizedBox(
          height:
              MediaQuery.of(context).size.height -
              (MediaQuery.of(context).padding.top +
                  kToolbarHeight +
                  MediaQuery.of(context).padding.bottom),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    _isModelInitializing ? 'AIモデルを初期化中...' : 'AIモデルを準備中...',
                    style: TextStyle(
                      fontSize: 16,
                      color: isDark
                          ? Colors.grey.shade400
                          : Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '初回起動時は数秒かかる場合があります',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? Colors.grey.shade500
                          : Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // モデル準備完了だが、まだ小説のEmbeddingが1件も無い場合の案内
    return FutureBuilder<bool>(
      future: _isEmptyDatabase(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        // タブレット幅では中央寄せ（maxWidth 制限）
        final screenWidth = MediaQuery.of(context).size.width;
        final isTablet = screenWidth >= kTabletBreakpoint;
        if (snapshot.data == true) {
          return SingleChildScrollView(
            child: SizedBox(
              height:
                  MediaQuery.of(context).size.height -
                  (MediaQuery.of(context).padding.top +
                      kToolbarHeight +
                      MediaQuery.of(context).padding.bottom),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isTablet
                        ? kTabletContentMaxWidth
                        : double.infinity,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 64,
                          color: isDark
                              ? Colors.pinkAccent.shade200
                              : Colors.pinkAccent,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'まだデータがありません',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '小説を開くと、その作品が\nフィーリング検索の対象になります',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            color: isDark
                                ? Colors.grey.shade500
                                : Colors.grey.shade600,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return SingleChildScrollView(
          child: SizedBox(
            height:
                MediaQuery.of(context).size.height -
                (MediaQuery.of(context).padding.top +
                    kToolbarHeight +
                    MediaQuery.of(context).padding.bottom),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF2A2A2A)
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(60),
                      ),
                      child: Icon(
                        Icons.auto_awesome,
                        size: 60,
                        color: isDark
                            ? Colors.pinkAccent.shade200
                            : Colors.pinkAccent,
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
                        color: isDark
                            ? Colors.grey.shade500
                            : Colors.grey.shade600,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: isTablet
                            ? kTabletContentMaxWidth
                            : double.infinity,
                      ),
                      child: Wrap(
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
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '※ ローカルONNXモデルによる完全オフライン検索\n※ R-18作品も含めて意味検索可能',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? Colors.grey.shade600
                            : Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// novel_embeddings が空（まだ1件もフィーリング検索の対象が無い）かを判定
  Future<bool> _isEmptyDatabase() async {
    try {
      final db = await DatabaseService().database;
      final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM novel_embeddings'),
      );
      return (count ?? 0) == 0;
    } catch (_) {
      return false;
    }
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
    String? similarityPercent,
    bool isDark,
    int index, {
    bool isKeywordMatch = false,
  }) {
    final title = item['title'] as String? ?? '';
    final authorName = item['author_name'] as String? ?? '不明';
    final previewUrl = item['cover_url'] as String?;
    final textLength = item['text_length'] as int? ?? 0;
    final pageCount = item['page_count'] as int? ?? 0;
    final createDate = item['create_date'] as String? ?? '';
    final totalBookmarks = item['total_bookmarks'] as int? ?? 0;
    final caption = cleanCaption(item['description'] as String? ?? '');

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
              // サムネイル
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 80,
                  height: 112,
                  child: previewUrl != null && previewUrl.isNotEmpty
                      ? PixivImage(
                          url: previewUrl,
                          fit: BoxFit.cover,
                          isThumbnail: true,
                          errorWidget: _buildPlaceholderCover(isDark),
                        )
                      : _buildPlaceholderCover(isDark),
                ),
              ),
              const SizedBox(width: 12),
              // 本文
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 類似度バッジ + タイトル
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: isKeywordMatch
                                ? Colors.blueAccent.withValues(alpha: 0.15)
                                : Colors.pinkAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            similarityPercent != null
                                ? '$similarityPercent% 一致'
                                : 'キーワード一致',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: similarityPercent != null
                                  ? Colors.pinkAccent
                                  : Colors.blueAccent,
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
                    // 作者情報
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
                    // キャプション（概要）先頭を表示
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
                    // メタ情報
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
