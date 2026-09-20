import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../widgets/novel_list_card.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../novel_model.dart';
import '../illust_model.dart';
import 'novel_detail_screen.dart';
import 'illust_detail_state.dart' show IllustDetailScreen;
import 'ai_index_maintenance_screen.dart';
import '../services/database_service.dart';
import '../services/embedding_service.dart';
import '../services/hybrid_search_service.dart';
import '../config/feature_flags.dart';
import '../services/feeling_search_query.dart';
import '../services/ruri_model_manager.dart';
import '../services/model_download_coordinator.dart';
import '../services/pixiv_api_service.dart';
import '../services/rerank_model_manager.dart';
import '../utils/score_format.dart';

/// B6: ダウンロードタスクの戻り値をunused warning回避。
void ignoreTask(dynamic _) {}

/// タブレット判定閾値: <700=1列, 700以上=2列
/// （home_ui_components.dart の _kTabletBreakpoint は private かつ循環参照を
///  避けるためローカル定義。値は同一に保つ）
/// 類似度の表示下限（これより低い作品は「近い作品が見つかりませんでした」扱い）
const double kMinDisplaySimilarity = 0.75;

const double kTabletBreakpoint = 700.0;
const double kTabletContentMaxWidth = 800.0;

/// 検索候補の1件（履歴 or 購読タグ）
class _SearchSuggestion {
  final String keyword;
  final bool isTag;

  const _SearchSuggestion({required this.keyword, required this.isTag});
}

/// 検索結果カードの事前計算済みデータ（build の同期コスト削減用）。
class _PreparedCard {
  final Novel novel;
  final String? matchLabel;
  final List<Widget> extraBadges;
  final String? displayExplanation;
  final bool isKeywordMatch;
  final bool isAiUnanalyzed;
  const _PreparedCard({
    required this.novel,
    required this.matchLabel,
    required this.extraBadges,
    required this.displayExplanation,
    this.isKeywordMatch = false,
    this.isAiUnanalyzed = false,
  });
}

/// フィーリング発掘画面
///
/// UI層のみ（検索に集中・速い）。AIインデックス診断・修復UIは
/// [AiIndexMaintenanceScreen] へ分離した。
class FeelingDiscoveryScreen extends StatefulWidget {
  const FeelingDiscoveryScreen({super.key});

  @override
  State<FeelingDiscoveryScreen> createState() => _FeelingDiscoveryScreenState();
}

class _FeelingDiscoveryScreenState extends State<FeelingDiscoveryScreen> {
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  // 検索窓候補（DB履歴 + 購読タグ）オーバーレイの表示フラグ
  bool _showSuggestions = false;

  bool _isSearching = false;
  bool _isModelReady = false;
  bool _isModelInitializing = false; // AIモデル初期化中フラグ
  bool _isModelDownloaded = false; // モデルファイルが端末に存在し検証済みか
  bool _isDownloading = false;
  int _dlReceived = 0;
  int _dlTotal = 0;
  String _dlLabel = '';
  String? _dlError;
  Timer? _dlPollTimer;
  String? _error;
  String _lastQuery = '';
  List<Map<String, dynamic>> _results = [];
  // 段階表示用: 全検索結果を保持し、別フレームで少しずつ _results に追加する。
  List<Map<String, dynamic>> _pendingResults = [];
  // 1回のフレームで一気に描画する件数上限（build 負荷分散用）。
  static const int _initialDisplayCount = 12;
  static const int _stepDisplayCount = 8;
  // 重複排除用：表示済み work_id を保持（検索クエリ変更時にクリア）
  final Set<int> _displayedWorkIds = {};
  // build の同期コストを抑えるため、index ごとに事前計算済みカードをキャッシュする。
  final Map<int, _PreparedCard> _preparedCache = {};

  // v2: 構造化クエリ
  FeelingSearchQuery _query = const FeelingSearchQuery();
  // 検索対象種別（デフォルト小説）。イラスト意味検索は flag 有効時のみ切替可。
  WorkType _workType = WorkType.novel;
  // キーワード/タグ入力用テンポラリコントローラ
  final TextEditingController _mustController = TextEditingController();
  final TextEditingController _shouldController = TextEditingController();
  final TextEditingController _excludeController = TextEditingController();
  final TextEditingController _exactTagController = TextEditingController();
  final TextEditingController _partialTagController = TextEditingController();
  final TextEditingController _minBookmarkController = TextEditingController();
  final TextEditingController _minLenController = TextEditingController();
  final TextEditingController _maxLenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadSearchHistory();

    // B6: 画面復帰時に永続された DL 状態を読み込む（バックグラウンド完了の検知用）。
    _restoreDownloadState();
    // ONNXモデルをバックグラウンドで事前初期化（ウォームアップ）。
    // 未ダウンロードなら初期化せず、DL 導線を表示する。
    // ※ 診断は行わない（メンテ画面側の責務）。
    _initializeModel();
  }

  /// B6: 永続されたモデル DL 状態を画面に反映（バックグラウンド完了/進行中を検知）。
  Future<void> _restoreDownloadState() async {
    final activeId = await RuriModelManager().getActiveModelId();
    final snap = await ModelDownloadCoordinator().loadPersisted(activeId);
    if (!mounted || snap == null) return;
    if (snap.state == ModelDownloadState.completed) {
      setState(() {
        _isModelDownloaded = true;
        _dlReceived = snap.totalBytes;
        _dlTotal = snap.totalBytes;
        _dlLabel = snap.label;
        _isDownloading = false;
      });
    } else if (snap.state == ModelDownloadState.downloading ||
        snap.state == ModelDownloadState.queued) {
      // 進行中ならポーリング再開
      setState(() {
        _isDownloading = true;
        _dlReceived = snap.receivedBytes;
        _dlTotal = snap.totalBytes;
        _dlLabel = snap.label;
      });
      _startPoll(activeId);
    } else if (snap.state == ModelDownloadState.failed) {
      setState(() {
        _isDownloading = false;
        _dlError = snap.error;
      });
    }
  }

  /// ポーリング開始（復帰時・初期開始時共用）。
  void _startPoll(String activeId) {
    _dlPollTimer?.cancel();
    _dlPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final snap = ModelDownloadCoordinator().snapshotFor(activeId);
      if (snap == null) return;
      setState(() {
        _dlReceived = snap.receivedBytes;
        _dlTotal = snap.totalBytes;
        _dlLabel = snap.label;
        if (snap.state == ModelDownloadState.completed) {
          _isDownloading = false;
          _isModelDownloaded = true;
        } else if (snap.state == ModelDownloadState.failed) {
          _isDownloading = false;
          _dlError = snap.error ?? '不明なエラー';
        } else if (snap.state == ModelDownloadState.cancelled) {
          _isDownloading = false;
          _dlError = null;
        }
      });
      if (snap.state == ModelDownloadState.completed ||
          snap.state == ModelDownloadState.failed ||
          snap.state == ModelDownloadState.cancelled) {
        _dlPollTimer?.cancel();
        // 完了時は初期化へ進める（初回ダウンロード後の自動 warmup）。
        if (snap.state == ModelDownloadState.completed) {
          _initializeModel();
        }
      }
    });
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
    _dlPollTimer?.cancel();
    _queryController.dispose();
    _scrollController.dispose();
    _mustController.dispose();
    _shouldController.dispose();
    _excludeController.dispose();
    _exactTagController.dispose();
    _partialTagController.dispose();
    _minBookmarkController.dispose();
    _minLenController.dispose();
    _maxLenController.dispose();
    super.dispose();
  }

  /// モデルをダウンロードし、完了後に初期化まで進める。
  /// Coordinator 経由：画面 dispose 後もバックグラウンドで DL が継続する。
  Future<void> _startDownload() async {
    if (_isDownloading) return;
    final activeId = await RuriModelManager().getActiveModelId();
    setState(() {
      _isDownloading = true;
      _dlError = null;
      _dlReceived = 0;
      _dlTotal = 0;
      _dlLabel = '';
    });
    // Coordinator へ DL 開始（Android は FGS、非 Android はフォアグラウンド）。
    await ModelDownloadCoordinator().start(activeId);
    // ポーリング開始（_startPoll で統一）。
    _startPoll(activeId);
  }

  void _cancelDownload() {
    RuriModelManager().getActiveModelId().then((id) {
      ModelDownloadCoordinator().cancel(id);
    });
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// モデル未ダウンロード時の導線 UI
  Widget _buildModelDownloadPrompt(ColorScheme colorScheme) {
    final subColor = colorScheme.onSurfaceVariant;
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
                'AIモデルをダウンロードすると意味検索が使えます',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                '日本語に特化した検索用 AI モデル（${RuriModelManager.modelSizeDescription}）を'
                '端末にダウンロードします。ダウンロード後はオフラインでも意味検索が使えます。\n'
                '（ダウンロードせずともキーワード検索は今すぐ使えます）',
                style: TextStyle(fontSize: 14, color: subColor),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '※ 通信量が大きいため Wi-Fi 接続での実行を推奨します',
                style: TextStyle(fontSize: 13, color: colorScheme.tertiary),
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
                    style: TextStyle(fontSize: 13, color: colorScheme.error),
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
  Widget _buildModelInitializing(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'AI モデルを初期化しています...',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
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
    // v2 は単発検索のため追加読込なし
  }

  /// 検索結果を段階的に描画する（UI フリーズ防止）。
  /// 初回フレームで上位 [_initialDisplayCount] 件を表示し、以降は毎フレーム
  /// [_stepDisplayCount] 件ずつ追加して build のピーク負荷を分散させる。
  void _scheduleRemainingResults() {
    if (!mounted) return;
    if (_pendingResults.isEmpty) return;
    final already = _results.length;
    if (already >= _pendingResults.length) {
      _pendingResults.clear();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pendingResults.isEmpty) return;
      final next = (_results.length + _stepDisplayCount).clamp(
        0,
        _pendingResults.length,
      );
      setState(() {
        _results = _pendingResults.sublist(0, next);
      });
      if (_results.length < _pendingResults.length) {
        _scheduleRemainingResults();
      } else {
        _pendingResults.clear();
      }
    });
  }

  Future<void> _search({bool isLoadMore = false}) async {
    if (isLoadMore) {
      // v2 は単発検索で十分量を返すため、追加読込は行わない
      return;
    }

    // 構造化クエリを組み立て（semanticText は検索窓のテキスト、他はフィルタシート）
    final semanticText = _queryController.text.trim();
    _query = _query.copyWith(semanticText: semanticText, workType: _workType);
    if (_query.isEmpty) return;

    // キーボードを閉じる
    FocusScope.of(context).unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    if (mounted) setState(() => _showSuggestions = false);

    if (!mounted) return;
    setState(() {
      _isSearching = true;
      _error = null;
      _results.clear();
      _pendingResults.clear();
      _lastQuery = semanticText;
      _displayedWorkIds.clear();
      _preparedCache.clear();
    });

    // UIの描画とキーボードが閉じるアニメーションを完了させるために少し待機
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    try {
      // モデル未導入でも lexical 検索で動作する（modelReady を渡す）
      final modelReady = _isModelReady;
      final results = await HybridSearchService().search(
        _query,
        modelReady: modelReady,
      );

      final newItems = results
          .where((item) => !_displayedWorkIds.contains(item['id'] as int))
          .toList();

      if (!mounted) return;
      // 描画を次フレーム（addPostFrameCallback）に遅延させ、検索完了処理と
      // build を別フレームに分ける。これにより search_return_to_ui 直後の
      // setState -> build が同一フレームで一気に走ることによるメインスレッド
      // ブロック（信号3 / ANR）を回避する。
      final itemsToShow = newItems;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          // 段階表示: 初回は上位 _initialDisplayCount 件のみ描画し、
          // 残りは次フレームで追加して build 負荷を分散する。
          final initial = itemsToShow.length > _initialDisplayCount
              ? itemsToShow.sublist(0, _initialDisplayCount)
              : itemsToShow;
          _results = initial;
          _pendingResults = itemsToShow;
          _isSearching = false;
          _preparedCache.clear();
        });
        // 残りの結果を次フレームで段階追加（UI フリーズ防止）
        _scheduleRemainingResults();
      });
      if (semanticText.isNotEmpty) {
        _saveSearchHistory(semanticText);
        // DB 検索履歴にも保存。失敗しても検索結果表示は継続。
        DatabaseService()
            .addSearchHistory(semanticText)
            .catchError((e) => debugPrint('検索履歴DB保存に失敗（無視）: $e'));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _error = e.toString();
        });
      }
    }
  }

  void _onQuerySubmitted(String query) {
    _search();
  }

  /// 検索窓候補オーバーレイを組み立てる（DB履歴 + 購読タグの部分一致）。
  Widget _buildSuggestionsOverlay(ColorScheme colorScheme) {
    final query = _queryController.text.trim();
    return FutureBuilder<List<_SearchSuggestion>>(
      future: _buildSearchSuggestions(query),
      builder: (ctx, snap) {
        final suggestions = snap.data ?? <_SearchSuggestion>[];
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          constraints: const BoxConstraints(maxHeight: 280),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: colorScheme.shadow,
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: suggestions.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '候補がありません',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                )
              : ListView.builder(
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
                            ? colorScheme.tertiary
                            : colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        s.keyword,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 13,
                        ),
                      ),
                      onTap: () {
                        _queryController.text = s.keyword;
                        setState(() => _showSuggestions = false);
                        _search();
                      },
                    );
                  },
                ),
        );
      },
    );
  }

  /// 検索候補を組み立てる（DB検索履歴の部分一致 + 購読タグの部分一致）。
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

  /// カードタップ時は DB Map から不完全な Novel を組み立てず、
  /// item['id'] を使って API から完全な Novel を取得してから遷移する。
  /// 取得した完全メタデータは DB に保存し、次回以降のカード表示にも利用する。
  Future<void> _navigateToDetail(Map<String, dynamic> item) async {
    // 検索結果 item は novels / illusts テーブルの行（主キーは id）＋ similarity。
    // 誤って item['work_id'] を参照すると null になり id=0 で 404 になる。
    final int id = item['id'] as int? ?? 0;
    if (id == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('この作品のIDを取得できませんでした')));
      return;
    }

    // ローディング表示（バリア付きダイアログ）
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    // 検索対象種別で遷移先を分岐（イラスト意味検索 flag on + トグル選択時）。
    if (_workType == WorkType.illust) {
      Illust? illust;
      try {
        illust = await PixivApiService().getIllustById(id);
        // 完全なメタデータをローカル DB に保存（次回以降の表示補完に利用）
        await DatabaseService().saveIllustMeta(illust);
      } catch (e) {
        illust = null;
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      if (illust == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('作品情報の取得に失敗しました。通信状況を確認してください')),
        );
        return;
      }

      // 17b: 詳細画面は root Navigator に積みボトムナビを隠す。
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => IllustDetailScreen(illust: illust!)),
      );
      return;
    }

    Novel? novel;
    bool isGone = false;
    try {
      novel = await PixivApiService().getNovelById(id);
      // 完全なメタデータをローカル DB に保存（次回以降の表示補完に利用）
      await DatabaseService().saveNovel(novel);
    } on RateLimitException {
      // レート制限は削除せず、通信失敗として扱う
      novel = null;
    } on Exception catch (e) {
      // 404（小説が削除された / データが古い）の場合のみ、以降検索に出ないよう遅延削除する。
      final msg = e.toString();
      if (DatabaseServiceIntegrity.isGenuineNovelMissing(msg)) {
        isGone = true;
        await DatabaseService().removeInvalidNovel(id, errorMessage: msg);
      }
      novel = null;
    } catch (e) {
      novel = null;
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // ローディングを閉じる

    if (novel == null) {
      // 不完全なデータでの強制遷移はしない
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isGone
                ? 'この作品は削除されたか、データが古いため一覧から削除しました'
                : '作品情報の取得に失敗しました。通信状況を確認してください',
          ),
        ),
      );
      return;
    }

    final fullNovel = novel;
    // 17b: 詳細画面は root Navigator に積みボトムナビを隠す。
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: fullNovel)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    return _buildScaffold(isDark, colorScheme);
  }

  Widget _buildScaffold(bool isDark, ColorScheme colorScheme) {
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('フィーリング発掘'),
        elevation: 0.5,
        actions: [
          // 検索対象種別トグル（イラスト意味検索は flag 有効時のみ表示）。
          // flag off 時はトグル非表示で小説のみ（既存挙動維持）。
          if (FeatureFlags.illustSemanticSearch)
            SegmentedButton<WorkType>(
              segments: const [
                ButtonSegment<WorkType>(
                  value: WorkType.novel,
                  label: Text('小説'),
                  icon: Icon(Icons.menu_book),
                ),
                ButtonSegment<WorkType>(
                  value: WorkType.illust,
                  label: Text('イラスト'),
                  icon: Icon(Icons.image),
                ),
              ],
              selected: {_workType},
              onSelectionChanged: (selected) {
                if (selected.isEmpty) return;
                setState(() => _workType = selected.first);
              },
              style: ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          // 複数条件フィルタシート
          IconButton(
            icon: Badge(
              isLabelVisible: _query.hasHardFilter,
              smallSize: 8,
              child: const Icon(Icons.tune),
            ),
            tooltip: '詳細条件',
            onPressed: () => _showFilterBottomSheet(colorScheme),
          ),
          // AIインデックス管理（診断・修復）へ遷移
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'maintenance') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AiIndexMaintenanceScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'maintenance',
                child: Row(
                  children: [
                    Icon(Icons.health_and_safety, size: 20),
                    SizedBox(width: 12),
                    Text('AIインデックス管理'),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queryController,
                        enabled: !_isModelInitializing, // AI初期化中は入力無効
                        decoration: InputDecoration(
                          hintText: _isModelInitializing
                              ? 'AIモデルを初期化中... 少々お待ちください'
                              : '今の気分・キーワードを入力（例: 切ない春、ドキドキする恋愛、癒やされる日常）',
                          hintStyle: TextStyle(
                            color: colorScheme.onSurfaceVariant,
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
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : Icon(
                                  Icons.search,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                          suffixIcon:
                              _queryController.text.isNotEmpty &&
                                  !_isModelInitializing
                              ? IconButton(
                                  icon: Icon(
                                    Icons.clear,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  onPressed: () {
                                    _queryController.clear();
                                    setState(() {});
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHigh,
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
                          color: colorScheme.onSurface,
                          fontSize: 15,
                        ),
                        onSubmitted: _isModelInitializing
                            ? null
                            : (q) {
                                setState(() => _showSuggestions = false);
                                _onQuerySubmitted(q);
                              },
                        onChanged: (_) {
                          if (!_showSuggestions) {
                            setState(() => _showSuggestions = true);
                          } else {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _isModelInitializing
                          ? null
                          : () {
                              setState(() => _showSuggestions = false);
                              _search();
                            },
                      icon: const Icon(Icons.search),
                      label: const Text('検索'),
                    ),
                  ],
                ),
                // 検索窓候補オーバーレイ（DB履歴 + 購読タグ）
                if (_showSuggestions) _buildSuggestionsOverlay(colorScheme),
              ],
            ),
          ),
        ),
      ),
      body: _buildBody(isDark, colorScheme),
    );
  }

  Widget _buildBody(bool isDark, ColorScheme colorScheme) {
    // DL 済みだが未初期化 → 初期化中表示
    if (_isModelInitializing) {
      return _buildModelInitializing(colorScheme);
    }
    // モデル未導入かつまだ検索していない場合のみ DL 誘導を表示。
    // v2 ではモデル未導入でもキーワード検索（lexical フォールバック）が動くため、
    // 一度検索すれば結果画面へ遷移する。
    if (!_isModelDownloaded && _lastQuery.isEmpty && _results.isEmpty) {
      return _buildModelDownloadPrompt(colorScheme);
    }

    if (_lastQuery.isEmpty && _results.isEmpty) {
      return _buildEmptyState(isDark, colorScheme);
    }

    if (_isSearching && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '検索中...',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    // エラー状態
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                '検索中にエラーが発生しました',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => _search(),
                icon: const Icon(Icons.refresh),
                label: const Text('再試行'),
              ),
            ],
          ),
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
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  '「$_lastQuery」に合う作品が見つかりませんでした',
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '別のキーワードや気分を試してみてください',
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '（類似度 ${kMinDisplaySimilarity.toStringAsFixed(2)} 以上の作品のみ表示）',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
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
    final horiz = isTablet ? 32.0 : 16.0;
    final vert = isTablet ? 12.0 : 16.0;

    final listWidget = RefreshIndicator(
      onRefresh: () => _search(),
      child: CustomScrollView(
        controller: _scrollController,
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
                    delegate: SliverChildBuilderDelegate(
                      (ctx, index) => _buildGridOrListCard(index, colorScheme),
                      childCount: _results.length,
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, index) => _buildGridOrListCard(index, colorScheme),
                      childCount: _results.length,
                    ),
                  ),
          ),
        ],
      ),
    );
    return listWidget;
  }

  /// インデックスに応じたカードまたはローディングインジケータを返す。
  /// （タブレット=2列グリッド、スマホ=1列リスト共通）
  ///
  /// カード UI はホームと同一の [NovelListCard] を使用する。
  /// DB の novels 行情報から [Novel] を復元し（meta_json 優先、なければ部分列から構築）、
  /// 不完全なモデルを直接組み立てるのではなく、共通カードへ渡す。
  /// タップ時は [_navigateToDetail] が API から完全な Novel を取得して遷移する。
  Widget _buildGridOrListCard(int index, ColorScheme colorScheme) {
    if (index >= _results.length) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final item = _results[index];
    // build のたびに jsonDecode / ScoreFormat を走らせないよう、最初に
    // 計算した結果をキャッシュする（スクロール時の再構築でも同期コストを抑える）。
    final prepared = _preparedCache[index] ??= _prepareCard(item);
    final extraBadges = prepared.extraBadges;
    final displayExplanation = prepared.displayExplanation;
    final novel = prepared.novel;

    final card = NovelListCard(
      novel: novel,
      matchLabel: prepared.matchLabel,
      isKeywordMatch: prepared.isKeywordMatch,
      isAiUnanalyzed: prepared.isAiUnanalyzed,
      extraBadges: extraBadges,
      onTap: () => _navigateToDetail(item),
    );

    // なぜヒットしたかの簡易説明（v2）
    final String? shownHint = displayExplanation;
    if (shownHint != null && shownHint.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            card,
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Text(
                shownHint,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(padding: const EdgeInsets.only(bottom: 12), child: card);
  }

  /// 検索結果 1 件をカード描画用に事前計算する（jsonDecode / ScoreFormat 等の
  /// 同期コストを build から分離し、スクロール時の再構築でも再利用する）。
  _PreparedCard _prepareCard(Map<String, dynamic> item) {
    final semanticScore = item['semanticScore'] as double? ?? 0.0;
    final isKeywordMatch = (item['is_keyword_match'] as int? ?? 0) == 1;
    final rerankApplied = (item['rerankApplied'] as bool? ?? false);
    // rerankApplied はソートキー用。表示ラベルには影響させない。
    final explanation = item['explanation'] as String?;

    final bool semanticComputed = semanticScore > 0.0;
    final List<Widget> extraBadges = <Widget>[];
    bool kwMatch = false;
    bool aiUnanalyzed = false;

    // 表示%は embedding の生 semanticScore をそのまま使う（rerank は順位のみ）。
    final String matchLabel = ScoreFormat.formatMatchPercent(
      score: semanticComputed ? semanticScore : null,
      semanticComputed: semanticComputed,
      lexicalHit: isKeywordMatch,
      rerankApplied: rerankApplied,
    );
    if (!semanticComputed && isKeywordMatch) {
      kwMatch = true;
    } else if (!semanticComputed && !isKeywordMatch) {
      aiUnanalyzed = true;
    }

    // 表示側のみ: explanation から「意味近め (NN%)」の断片を除去する。
    // （スコア計算・検索ロジックは一切変更しない）
    final String? explanationForDisplay = _stripSemanticLabel(explanation);
    final displayExplanation =
        (explanationForDisplay == null || explanationForDisplay.isEmpty)
        ? (semanticComputed
              ? null
              : (isKeywordMatch
                    ? 'キーワード一致（意味検索インデックス未生成）'
                    : 'AIインデックス未生成（再インデックス推奨）'))
        : explanationForDisplay;
    final novel = _novelFromResultRow(item);
    return _PreparedCard(
      novel: novel,
      matchLabel: matchLabel,
      extraBadges: extraBadges,
      displayExplanation: displayExplanation,
      isKeywordMatch: kwMatch,
      isAiUnanalyzed: aiUnanalyzed,
    );
  }

  /// explanation 文字列から「意味近め (NN%)」表記だけを取り除く（表示用）。
  /// 区切り（' / ' や '、'）も含めて自然に消す。
  static String? _stripSemanticLabel(String? explanation) {
    if (explanation == null || explanation.isEmpty) return explanation;
    var s = explanation.replaceAll(
      RegExp(r'意味近め\s*\(?\s*\d+\s*%?\s*\)?(\s*・高精度)?'),
      '',
    );
    s = s.replaceAll(RegExp(r'^[\s/、,]+'), '');
    s = s.replaceAll(RegExp(r'[\s/、,]+$'), '');
    s = s.replaceAll(RegExp(r'\s*/\s*/\s*'), ' / ');
    return s.trim();
  }

  /// novels テーブル行（＋similarity）から [Novel] を復元する。
  /// 保存済みの meta_json があればそれを優先し、なければ部分列から最小構築する。
  Novel _novelFromResultRow(Map<String, dynamic> item) {
    final metaJson = item['meta_json'] as String?;
    if (metaJson != null && metaJson.isNotEmpty) {
      try {
        return Novel.fromJson(jsonDecode(metaJson) as Map<String, dynamic>);
      } catch (_) {
        // パース失敗時は部分構築へフォールバック
      }
    }
    final tagsJson = item['tags_json'] as String?;
    List<String> tags = const <String>[];
    if (tagsJson != null && tagsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(tagsJson) as List<dynamic>;
        tags = decoded
            .map(
              (e) => e is Map<String, dynamic>
                  ? (e['name'] as String? ?? '')
                  : e.toString(),
            )
            .where((t) => t.isNotEmpty)
            .toList();
      } catch (_) {
        // ignore
      }
    }
    if (tags.isEmpty) {
      final rawTags = item['tags'] as String?;
      if (rawTags != null && rawTags.isNotEmpty) {
        tags = rawTags.split(',').where((t) => t.isNotEmpty).toList();
      }
    }
    final seriesId = item['series_id'] as int? ?? 0;
    final userId = item['user_id'] as int? ?? 0;
    return Novel(
      id: item['id'] as int? ?? 0,
      title: item['title'] as String? ?? '無題',
      caption: cleanCaption(item['description'] as String? ?? ''),
      author: Author(
        id: userId,
        name: item['author_name'] as String? ?? '不明',
        account: '',
      ),
      tags: tags,
      coverUrl: item['cover_url'] as String? ?? '',
      rawCoverUrl: item['cover_url'] as String? ?? '',
      textCount: item['text_length'] as int? ?? 0,
      wordCount: item['text_length'] as int? ?? 0,
      textLength: item['text_length'] as int? ?? 0,
      pageCount: item['page_count'] as int? ?? 0,
      createDate: item['create_date'] as String? ?? '',
      totalView: item['total_view'] as int? ?? 0,
      totalBookmarks: item['total_bookmarks'] as int? ?? 0,
      isBookmarked: false,
      series: seriesId != 0
          ? NovelSeriesInfo(
              id: seriesId,
              title: item['series_title'] as String? ?? 'シリーズ',
            )
          : null,
      aiType: item['novel_ai_type'] as int? ?? 0,
      xRestrict: item['x_restrict'] as int? ?? 0,
    );
  }

  Widget _buildEmptyState(bool isDark, ColorScheme colorScheme) {
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
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '初回起動時は数秒かかる場合があります',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
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
                    color: colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(60),
                  ),
                  child: Icon(
                    Icons.auto_awesome,
                    size: 60,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'フィーリング発掘',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '今の気分やキーワードを入力すると、\nAIが意味で似た小説を探し出します',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isDark ? kTabletContentMaxWidth : double.infinity,
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _buildSuggestionChip('切ない春', colorScheme),
                      _buildSuggestionChip('ドキドキする恋愛', colorScheme),
                      _buildSuggestionChip('癒やされる日常', colorScheme),
                      _buildSuggestionChip('胸が熱くなる冒険', colorScheme),
                      _buildSuggestionChip('不思議な世界観', colorScheme),
                      _buildSuggestionChip('笑えるコメディ', colorScheme),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '※ ローカルONNXモデルによる完全オフライン検索\n※ R-18作品も含めて意味検索可能',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestionChip(String label, ColorScheme colorScheme) {
    // v2 ではモデル未導入でもキーワード検索が可能なため常に有効
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      backgroundColor: colorScheme.surfaceContainerHigh,
      side: BorderSide(color: colorScheme.outlineVariant),
      onPressed: () {
        _queryController.text = label;
        _search();
      },
    );
  }

  /// 複数条件検索フィルタシート（v2）。
  /// 必須/できれば/除外キーワード、完全一致/部分一致タグ、ブクマ・文字数閾値、
  /// R-18 / AI / 並び順 を設定できる。
  void _showFilterBottomSheet(ColorScheme colorScheme) {
    // 現在の値をテンポラリコントローラに反映
    _mustController.text = _query.mustKeywords.join(' ');
    _shouldController.text = _query.shouldKeywords.join(' ');
    _excludeController.text = _query.excludeKeywords.join(' ');
    _exactTagController.text = _query.exactTags.join(' ');
    _partialTagController.text = _query.partialTags.join(' ');
    _minBookmarkController.text = _query.minBookmarks?.toString() ?? '';
    _minLenController.text = _query.minTextLength?.toString() ?? '';
    _maxLenController.text = _query.maxTextLength?.toString() ?? '';

    R18Mode r18 = _query.r18Mode;
    AiMode ai = _query.aiMode;
    SortMode sort = _query.sortMode;
    bool highPrecision = _query.highPrecision;
    bool rerankReady = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // Reranker 未導入時はトグルを無効化（案内表示用）
          RerankModelManager().isModelReady().then((ready) {
            if (ctx.mounted) setSheet(() => rerankReady = ready);
          });
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '詳細条件',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setSheet(() {
                            r18 = R18Mode.all;
                            ai = AiMode.all;
                            sort = SortMode.relevance;
                            _mustController.clear();
                            _shouldController.clear();
                            _excludeController.clear();
                            _exactTagController.clear();
                            _partialTagController.clear();
                            _minBookmarkController.clear();
                            _minLenController.clear();
                            _maxLenController.clear();
                          });
                        },
                        child: const Text('クリア'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _filterTextField(
                    _mustController,
                    '必須キーワード（空白区切り・すべて含む）',
                    colorScheme: colorScheme,
                  ),
                  _filterTextField(
                    _shouldController,
                    'できれば含むキーワード（空白区切り）',
                    colorScheme: colorScheme,
                  ),
                  _filterTextField(
                    _excludeController,
                    '除外キーワード（空白区切り・含むと除外）',
                    colorScheme: colorScheme,
                  ),
                  _filterTextField(
                    _exactTagController,
                    '完全一致タグ（空白区切り）',
                    colorScheme: colorScheme,
                  ),
                  _filterTextField(
                    _partialTagController,
                    '部分一致タグ（空白区切り）',
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _segmentLabel('R-18'),
                      _chip(
                        '含む',
                        r18 == R18Mode.all,
                        () => setSheet(() => r18 = R18Mode.all),
                      ),
                      _chip(
                        'R-18含む',
                        r18 == R18Mode.includeR18,
                        () => setSheet(() => r18 = R18Mode.includeR18),
                      ),
                      _chip(
                        '健全のみ',
                        r18 == R18Mode.safeOnly,
                        () => setSheet(() => r18 = R18Mode.safeOnly),
                      ),
                      _chip(
                        'R-18のみ',
                        r18 == R18Mode.r18Only,
                        () => setSheet(() => r18 = R18Mode.r18Only),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _segmentLabel('高精度モード'),
                      ChoiceChip(
                        label: Text(
                          rerankReady ? '高精度(rerank)' : '高精度(モデル未導入)',
                          style: const TextStyle(fontSize: 13),
                        ),
                        selected: highPrecision && rerankReady,
                        onSelected: rerankReady
                            ? (_) =>
                                  setSheet(() => highPrecision = !highPrecision)
                            : null,
                      ),
                    ],
                  ),
                  if (!rerankReady)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '高精度モードは「AIインデックス管理」で Reranker を導入すると使えます。'
                        '未導入でも意味検索（embedding）はそのまま動作します。',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _segmentLabel('AI'),
                      _chip(
                        '問わず',
                        ai == AiMode.all,
                        () => setSheet(() => ai = AiMode.all),
                      ),
                      _chip(
                        'AI除外',
                        ai == AiMode.excludeAi,
                        () => setSheet(() => ai = AiMode.excludeAi),
                      ),
                      _chip(
                        'AIのみ',
                        ai == AiMode.aiOnly,
                        () => setSheet(() => ai = AiMode.aiOnly),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _segmentLabel('並び順'),
                      _chip(
                        '関連度',
                        sort == SortMode.relevance,
                        () => setSheet(() => sort = SortMode.relevance),
                      ),
                      _chip(
                        '新着',
                        sort == SortMode.newest,
                        () => setSheet(() => sort = SortMode.newest),
                      ),
                      _chip(
                        'ブクマ',
                        sort == SortMode.bookmarks,
                        () => setSheet(() => sort = SortMode.bookmarks),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _filterTextField(
                          _minBookmarkController,
                          '最小ブクマ数',
                          colorScheme: colorScheme,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _filterTextField(
                          _minLenController,
                          '最小文字数',
                          colorScheme: colorScheme,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _filterTextField(
                          _maxLenController,
                          '最大文字数',
                          colorScheme: colorScheme,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        setState(() {
                          _query = _query.copyWith(
                            mustKeywords: _splitWords(_mustController.text),
                            shouldKeywords: _splitWords(_shouldController.text),
                            excludeKeywords: _splitWords(
                              _excludeController.text,
                            ),
                            exactTags: _splitWords(_exactTagController.text),
                            partialTags: _splitWords(
                              _partialTagController.text,
                            ),
                            minBookmarks: _parseIntOrNull(
                              _minBookmarkController.text,
                            ),
                            minTextLength: _parseIntOrNull(
                              _minLenController.text,
                            ),
                            maxTextLength: _parseIntOrNull(
                              _maxLenController.text,
                            ),
                            r18Mode: r18,
                            aiMode: ai,
                            sortMode: sort,
                            highPrecision: rerankReady && highPrecision,
                            // 高精度モードは rerank 上位40件を評価し、最終表示は20件に絞る
                            topK: (rerankReady && highPrecision)
                                ? 20
                                : _query.topK,
                          );
                        });
                        Navigator.of(ctx).pop();
                        // 既に検索済みなら条件変更後に再検索
                        if (_lastQuery.isNotEmpty) _search();
                      },
                      child: const Text('条件を適用'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _filterTextField(
    TextEditingController controller,
    String hint, {
    TextInputType? keyboardType,
    required ColorScheme colorScheme,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
        filled: true,
        fillColor: colorScheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      style: TextStyle(fontSize: 14, color: colorScheme.onSurface),
    ),
  );

  Widget _segmentLabel(String text) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
    label: Text(label, style: const TextStyle(fontSize: 13)),
    selected: selected,
    onSelected: (_) => onTap(),
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  int? _parseIntOrNull(String s) {
    final v = int.tryParse(s.trim());
    return v == null || v < 0 ? null : v;
  }

  List<String> _splitWords(String s) =>
      s.split(' ').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}
