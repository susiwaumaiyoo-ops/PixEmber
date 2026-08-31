import 'package:flutter/material.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import '../services/google_drive_service.dart';
import '../services/pixiv_api_service.dart';
import 'bookmark_list_screen.dart';
import 'history_screen.dart';
import 'feeling_discovery_screen.dart';
import 'ai_recommend_feed_screen.dart';
import 'folder_list_screen.dart';
import 'mute_settings_screen.dart';
import 'subscriptions_screen.dart';
import 'read_later_screen.dart';
import 'statistics_screen.dart';
import 'ai_index_maintenance_screen.dart';
import 'backup_manager_screen.dart';
import 'offline_bookshelf_screen.dart';
import 'download_queue_screen.dart';
import 'visual_search_screen.dart';
import 'duplicate_finder_screen.dart';
import 'home_ui_components.dart';
import 'home_filter_handler.dart';
import 'home_sync_handler.dart';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../services/database_service.dart';
import '../services/embedding_service.dart';
import '../services/ruri_model_manager.dart';
import '../services/novel_document_text.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:crypto/crypto.dart';

class PixivViewerHome extends StatefulWidget {
  const PixivViewerHome({super.key});

  @override
  State<PixivViewerHome> createState() => PixivViewerHomeState();
}

class PixivViewerHomeState extends State<PixivViewerHome> {
  /// ハンドラー／UI コンポーネントから安全に状態更新するための公開 API。
  void applyState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    } else {
      fn();
    }
  }

  /// ハンドラー側から mounted を参照するための公開 API。
  bool get isMounted => mounted;

  /// ハンドラー側から BuildContext を参照するための公開 API。
  BuildContext get uiContext => context;

  final GoogleDriveService driveService = GoogleDriveService();
  final PixivApiService _pixivApiService = PixivApiService();
  String? loggedInEmail;
  bool isLoggedIn = false;

  // 認証コードの二重交換を防ぐためのガード
  bool _isExchangingToken = false;
  String? _processedAuthCode;

  // サブスクリプション同期用の状態変数
  Map<String, dynamic>? _syncProgress;
  Timer? _syncTimer;
  bool isSyncing = false;

  // Google Drive 同期用の状態変数
  String? lastSyncTimestamp;
  bool isBackingUp = false;
  bool isRestoring = false;
  Map<String, int>? lastSyncSummary;

  late final TextEditingController searchController;
  final FocusNode searchFocusNode = FocusNode();

  // 共有される検索条件 State（カテゴリを跨いで保持されます）
  String _currentSearchWord = '';
  String selectedSearchTarget =
      'partial_match_for_tags'; // partial_match_for_tags, exact_match_for_tags, title_and_caption
  String selectedSort = 'date_desc'; // date_desc, date_asc, popular_desc

  // キーワード結合モード: and=スペース区切り(AND), or=' OR '区切り(OR)
  String selectedKeywordMode = 'and';
  // 除外キーワード（スペース区切り）。pixiv の "-word" 構文で送信される。
  late final TextEditingController excludeKeywordController =
      TextEditingController();

  /// pixiv の検索ワードを組み立てる。
  /// AND はスペース区切り、OR は ' OR ' 区切り、NOT は '-word'。
  /// 単一キーワードの場合は従来と完全に同じ文字列になる。
  static String buildSearchWord(
    String raw, {
    String mode = 'and',
    String exclude = '',
  }) {
    final words = raw
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    var base = mode == 'or' ? words.join(' OR ') : words.join(' ');
    final excludes = exclude
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.startsWith('-') ? w : '-$w');
    for (final e in excludes) {
      base = base.isEmpty ? e : '$base $e';
    }
    return base;
  }

  // 高度な検索フィルター設定
  String selectedWorkType = 'all'; // all, illust, manga, ugoira, novel
  // 年齢制限: all=全年齢のみ, include_r18=R-18含む, r18=R-18のみ, r18g=R-18G含む
  String selectedAgeLimit = 'all';
  String selectedDuration =
      'all'; // all, within_last_day, within_last_week, within_last_month
  // 最小ブックマーク数（0=指定なし）。検索ワードに "Nusers入り" として渡す。
  // 最小ブックマーク数（0=指定なし）。検索ワードに "Nusers入り" として渡す。
  int selectedBookmarkFilter = 0; // 0, 100, 500, 1000, 5000, 10000
  // 最小ブックマーク数の自由入力欄（UI用）。空なら selectedBookmarkFilter を使用。
  late final TextEditingController minBookmarkController =
      TextEditingController();
  // イラスト AI フィルター（アプリ内ローカルで適用）: all, hide, only
  String selectedIllustAiFilter = 'all';

  // ===== 検索リビルド Phase 2: 新規フィルター状態（イラスト・小説共通）=====
  // ブックマーク数範囲（API パラメータ bookmark_num_min/max の数値範囲指定）
  late final TextEditingController minBookmarkNumController =
      TextEditingController();
  late final TextEditingController maxBookmarkNumController =
      TextEditingController();
  // 日付範囲指定（duration より優先して API の start_date/end_date に送信）
  bool useStartDate = false;
  bool useEndDate = false;
  DateTime? startDateTime;
  DateTime? endDateTime;

  /// 有効なブックマーク数下限（空 or 0 以下なら null=指定なし）
  int? get effectiveBookmarkNumMin {
    final v = int.tryParse(minBookmarkNumController.text.trim());
    return (v != null && v > 0) ? v : null;
  }

  /// 有効なブックマーク数上限（空 or 0 以下なら null=指定なし）
  int? get effectiveBookmarkNumMax {
    final v = int.tryParse(maxBookmarkNumController.text.trim());
    return (v != null && v > 0) ? v : null;
  }

  DateTime? get effectiveStartDate => useStartDate ? startDateTime : null;

  DateTime? get effectiveEndDate => useEndDate ? endDateTime : null;

  /// 開始日ピッカーを開く。
  Future<void> pickStartDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: uiContext,
      initialDate: startDateTime ?? DateTime(now.year, now.month, now.day - 30),
      firstDate: DateTime(2010, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day + 1),
      helpText: '開始日を選択',
      cancelText: 'キャンセル',
      confirmText: '確定',
    );
    if (date == null) return;
    applyState(() {
      startDateTime = date;
      useStartDate = true;
    });
    _filterHandler.persistFilterPrefs();
  }

  /// 終了日ピッカーを開く。
  Future<void> pickEndDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: uiContext,
      initialDate: endDateTime ?? now,
      firstDate: DateTime(2010, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day + 1),
      helpText: '終了日を選択',
      cancelText: 'キャンセル',
      confirmText: '確定',
    );
    if (date == null) return;
    applyState(() {
      endDateTime = date;
      useEndDate = true;
    });
    _filterHandler.persistFilterPrefs();
  }

  // 小説専用の検索フィルター設定
  String selectedNovelSearchTarget =
      'all_text'; // all_text(全文検索：タグ + 本文), partial_match_for_tags, exact_match_for_tags, text
  String selectedNovelAgeLimit = 'all'; // all, safe, r18
  int selectedNovelBookmarkFilter = 0; // 0, 100, 300, 500, 1000, 5000
  String selectedNovelTextLengthLimit = 'all'; // all, short, medium, long
  // カスタム文字数フィルター用
  TextEditingController? minTextLengthController;
  TextEditingController? maxTextLengthController;
  // シリーズ統計文字数フィルター (シリーズ全体の合計文字数で絞り込み)
  String selectedNovelSeriesTextLengthLimit =
      'all'; // all, short, medium, long, custom
  TextEditingController? minSeriesTextLengthController;
  TextEditingController? maxSeriesTextLengthController;
  // シリーズ ID -> シリーズ全体の合計文字数 のキャッシュ (getNovelSeries で集計)
  final Map<int, int> _seriesTotalTextLengthCache = {};

  // 追加の小説フィルター（アプリ内ローカルで適用）
  // AI 作品：'all'=制限なし，'hide'=AI 以外，'only'=AI のみ
  String selectedNovelAiFilter = 'all';
  // シリーズ作品のみ表示するか
  bool novelSeriesOnly = false;
  // 除外タグ（これらのタグを含む作品を除外）
  final List<String> novelExcludeTags = [];
  TextEditingController? _excludeTagController;
  // 表示密度：'comfortable'=可読性重視 / 'compact'=情報密度重視
  String novelDensityMode = 'comfortable';

  // ボトムナビゲーション用 (0: イラスト，1: 小説，2: フィーリング発掘，3: AIレコメンド)
  int currentIndex = 0;
  static const int illustIndex = 0;
  static const int novelIndex = 1;
  static const int feelingDiscoveryIndex = 2;

  // イラストタブ内のサブ表示モード (0: おすすめ，1: 検索結果，2: ランキング)
  int illustSubMode = 0;
  // 小説タブ内のサブ表示モード (0: おすすめ，1: 検索結果，2: ランキング)
  int novelSubMode = 0;

  // データリスト
  List<Illust> illusts = [];
  List<Novel> novels = [];

  /// アプリ内しおり（読書進捗）の小説ID集合。
  /// 一覧描画時にカードごとの SharedPreferences 読み込みを防ぐため、
  /// 起動時に1回だけ読み込んで保持する。
  final Set<int> localBookmarkIds = {};

  // 百科事典データ
  SearchItem? searchItem;

  // 全文検索用のページング状態（all_text モード時のみ使用）
  AllTextSearchState? _allTextSearchState;

  bool isLoading = false;
  bool _isFetchingNextPage = false;
  String? errorMessage;
  bool rateLimited = false;

  // ページング用
  int? nextOffset;

  // フィーリング発掘：バックグラウンド Embedding 生成の状態管理
  // 生成中の work_id をメモリ上で保持し、同じ作品の二重処理を防止
  final Set<int> _backgroundEmbeddingInProgress = {};
  // 1回の一覧取得あたりの生成上限
  static const int _maxBackgroundEmbeddingsPerFetch = 5;

  // スクロールコントローラー（無限スクロール用）
  late final ScrollController scrollController;

  // ランキング用のアクティブモード設定
  String selectedIllustRankMode = 'day';
  String selectedNovelRankMode = 'day';

  final List<Map<String, String>> illustRankModes = [
    {'value': 'day', 'label': 'デイリー'},
    {'value': 'week', 'label': 'ウィークリー'},
    {'value': 'month', 'label': 'マンスリー'},
    {'value': 'day_male', 'label': '男性向け'},
    {'value': 'day_female', 'label': '女性向け'},
    {'value': 'day_r18', 'label': 'R-18 デイリー'},
    {'value': 'day_male_r18', 'label': 'R-18 男性向け'},
    {'value': 'day_female_r18', 'label': 'R-18 女性向け'},
  ];

  final List<Map<String, String>> novelRankModes = [
    {'value': 'day', 'label': 'デイリー'},
    {'value': 'week', 'label': 'ウィークリー'},
    {'value': 'day_male', 'label': '男性向け'},
    {'value': 'day_female', 'label': '女性向け'},
    {'value': 'day_r18', 'label': 'R-18 デイリー'},
    {'value': 'day_male_r18', 'label': 'R-18 男性向け'},
    {'value': 'day_female_r18', 'label': 'R-18 女性向け'},
  ];

  // 検索履歴
  List<String> searchHistory = [];
  bool _showHistoryList = false;

  // ハンドラーインスタンス
  late HomeFilterHandler _filterHandler;
  late HomeUIComponents _uiComponents;
  late HomeSyncHandler _syncHandler;

  @override
  void initState() {
    super.initState();
    searchController = TextEditingController();
    scrollController = ScrollController()
      ..addListener(() {
        if (scrollController.position.pixels >=
                scrollController.position.maxScrollExtent - 200 &&
            !isLoading &&
            nextOffset != null) {
          fetchNextPage();
        }
      });

    // ハンドラーの初期化
    _filterHandler = HomeFilterHandler(this);
    _uiComponents = HomeUIComponents(this);
    _syncHandler = HomeSyncHandler(this);

    // 検索窓フォーカス時に候補オーバーレイを表示（空欄なら履歴全件）
    searchFocusNode.addListener(() {
      if (searchFocusNode.hasFocus && !_showHistoryList) {
        setState(() => _showHistoryList = true);
      }
    });

    _loadSearchHistory();
    _initializeDriveSync();
    // Phase 2: 新設フィルター（期間 / 日付範囲 / ブクマ数範囲）を復元
    _filterHandler.loadFilterPrefs();
    fetchData();
    _loadLocalBookmarkIds();

    // 起動時の1回限り軽量清掃：旧バグ版で保存された id=0 の無効小説レコードを削除。
    // ブロックせずバックグラウンドで実行（失敗しても起動に影響なし）。
    DatabaseService().cleanupInvalidNovelRecords();

    // 起動後、最初のフレーム描画後にトークンを確認し、
    // 未ログインなら PKCE ログイン画面を自動表示する
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _checkLoginOnStart();

      // アクティブAIモデルのキャッシュをSharedPreferencesから最新化（モデル切り替え後も反映）。
      await RuriModelManager().getActiveModelId();

      // 埋め込みモデルがダウンロード済みなら、起動時にバックグラウンドで初期化。
      // これにより小説詳細を開いた際の「EmbeddingService が初期化されていません」を防ぐ。
      if (await RuriModelManager().isModelReady()) {
        unawaited(EmbeddingService().initialize());
      }
    });
  }

  @override
  void dispose() {
    searchController.dispose();
    scrollController.dispose();
    searchFocusNode.dispose();
    minTextLengthController?.dispose();
    maxTextLengthController?.dispose();
    minSeriesTextLengthController?.dispose();
    maxSeriesTextLengthController?.dispose();
    _excludeTagController?.dispose();
    minBookmarkController.dispose();
    // Phase 2: 新規フィルター用コントローラ
    minBookmarkNumController.dispose();
    maxBookmarkNumController.dispose();
    _syncTimer?.cancel();
    super.dispose();
  }

  // 検索履歴の読み込み
  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      searchHistory = prefs.getStringList('search_history') ?? [];
    });
  }

  // 検索履歴の保存
  Future<void> _saveSearchHistory(String word) async {
    if (word.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('search_history') ?? [];
    history.remove(word);
    history.insert(0, word);
    if (history.length > 20) history.removeLast();
    await prefs.setStringList('search_history', history);
    setState(() {
      searchHistory = history;
    });
  }

  // 検索履歴の削除
  Future<void> deleteSearchHistoryItem(String word) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('search_history') ?? [];
    history.remove(word);
    await prefs.setStringList('search_history', history);
    setState(() {
      searchHistory = history;
    });
  }

  // 検索履歴の全クリア
  Future<void> clearAllSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('search_history');
    setState(() {
      searchHistory = [];
      _showHistoryList = false;
    });
  }

  // 検索ワード送信時の処理
  void onSearchSubmit(String query) {
    if (query.trim().isEmpty) return;
    _saveSearchHistory(query);
    // DB 検索履歴にも保存（使用回数・最新日時付き）。失敗しても検索は継続。
    DatabaseService()
        .addSearchHistory(query.trim())
        .catchError((e) => debugPrint('検索履歴DB保存に失敗（無視）: $e'));
    setState(() {
      _currentSearchWord = buildSearchWord(
        query,
        mode: selectedKeywordMode,
        exclude: excludeKeywordController.text,
      );
      _showHistoryList = false;
      if (currentIndex == illustIndex) {
        illustSubMode = 1;
      } else if (currentIndex == novelIndex) {
        novelSubMode = 1;
      }
    });
    fetchData();
  }

  // 検索履歴アイテムタップ時の処理
  void onHistoryItemTap(String query) {
    searchController.text = query;
    onSearchSubmit(query);
  }

  // 検索リセット
  void resetSearch() {
    searchController.clear();
    setState(() {
      _currentSearchWord = '';
      _showHistoryList = false;
      if (currentIndex == illustIndex) {
        illustSubMode = 0;
      } else if (currentIndex == novelIndex) {
        novelSubMode = 0;
      }
    });
    fetchData();
  }

  // タグ選択時の処理
  void onTagSelected(String tag) {
    searchController.text = tag;
    onSearchSubmit(tag);
  }

  // 購読タグ一覧からタグが選択されたときの処理。
  // type に応じて適切なタブへ切り替えてから検索を実行する。
  void onSubscribedTagSelected(String tag, String type) {
    final targetIndex = type == 'novel' ? novelIndex : illustIndex;
    if (currentIndex != targetIndex) {
      setState(() {
        currentIndex = targetIndex;
      });
    }
    searchController.text = tag;
    onSearchSubmit(tag);
  }

  // タブ変更（subMode を指定した場合はそのサブモードへ切り替える）
  void changeTab(int index, [int? subMode]) {
    if (currentIndex == index) return;

    setState(() {
      currentIndex = index;
      // サブモードをリセット（おすすめに）
      if (index == illustIndex) {
        illustSubMode = subMode ?? 0;
      } else if (index == novelIndex) {
        novelSubMode = subMode ?? 0;
      }
      // フィーリング発掘は Pixiv API 一覧取得タブではないためローディングを解除
      if (index == feelingDiscoveryIndex) {
        isLoading = false;
        errorMessage = null;
      }
    });

    if (index == illustIndex || index == novelIndex) {
      fetchData();
    }
  }

  /// 現在のタブのサブモードを変更する公開 API。
  void changeSubMode(int subMode) {
    setState(() {
      if (currentIndex == illustIndex) {
        illustSubMode = subMode;
      } else if (currentIndex == novelIndex) {
        novelSubMode = subMode;
      }
    });
    fetchData();
  }

  void changeRankMode(String? mode) {
    if (mode == null) return;
    final validIllustValues = illustRankModes
        .map((m) => m['value'])
        .whereType<String>()
        .toSet();
    final validNovelValues = novelRankModes
        .map((m) => m['value'])
        .whereType<String>()
        .toSet();
    setState(() {
      if (currentIndex == illustIndex) {
        // サポート外モードは既定値へフォールバック（後方互換）
        selectedIllustRankMode = validIllustValues.contains(mode)
            ? mode
            : 'day';
      } else if (currentIndex == novelIndex) {
        selectedNovelRankMode = validNovelValues.contains(mode) ? mode : 'day';
      }
    });
    fetchData();
  }

  /// Google Drive 連携状態を参照するための公開 API。
  bool get isGoogleDriveLoggedIn => isLoggedIn;

  // データ取得
  Future<void> fetchData() async {
    final isPixivDataTab =
        currentIndex == illustIndex || currentIndex == novelIndex;

    if (!isPixivDataTab) {
      // フィーリング発掘など Pixiv API 一覧取得タブでは何も取得しない。
      // 誤って呼ばれた場合でも共通ローディングを解除して遮断を防ぐ。
      if (mounted && isLoading) {
        setState(() {
          isLoading = false;
        });
      }
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
      rateLimited = false;
    });

    try {
      if (currentIndex == illustIndex) {
        // イラストモード
        if (illustSubMode == 0) {
          // おすすめ
          final result = await _pixivApiService.getRecommend(offset: 0);
          setState(() {
            illusts = result.items;
            nextOffset = result.nextOffset;
            isLoading = false;
          });
        } else if (illustSubMode == 1) {
          // 検索結果
          // 最小ブックマーク数（自由入力）を bookmarkFilter に反映
          final minBm = int.tryParse(minBookmarkController.text.trim());
          final effectiveBookmarkFilter = minBm != null && minBm > 0
              ? minBm
              : selectedBookmarkFilter;
          final result = await _pixivApiService.searchIllust(
            _currentSearchWord,
            selectedSearchTarget,
            selectedSort,
            0,
            selectedAgeLimit,
            bookmarkFilter: effectiveBookmarkFilter,
            // Phase 2: 新規フィルター（null なら既存動作を維持）
            duration: selectedDuration == 'all' ? null : selectedDuration,
            startDate: effectiveStartDate,
            endDate: effectiveEndDate,
            bookmarkNumMin: effectiveBookmarkNumMin,
            bookmarkNumMax: effectiveBookmarkNumMax,
          );
          // AIフィルター（アプリ内ローカル適用）
          List<Illust> filtered = result.items;
          if (selectedIllustAiFilter != 'all') {
            filtered = filtered.where((it) {
              final isAi = it.aiType == 2;
              return selectedIllustAiFilter == 'only' ? isAi : !isAi;
            }).toList();
          }
          setState(() {
            illusts = filtered;
            nextOffset = result.nextOffset;
            searchItem = result.searchItem;
            isLoading = false;
          });
        } else if (illustSubMode == 2) {
          // ランキング
          final result = await _pixivApiService.getRanking(
            selectedIllustRankMode,
            offset: 0,
          );
          setState(() {
            illusts = result.items;
            nextOffset = result.nextOffset;
            isLoading = false;
          });
        }
      } else if (currentIndex == novelIndex) {
        // 小説モード
        if (novelSubMode == 0) {
          // おすすめ
          final result = await _pixivApiService.getNovelRecommend(offset: 0);
          setState(() {
            novels = result.items;
            nextOffset = result.nextOffset;
            isLoading = false;
            // シリーズ文字数キャッシュを初期化
            _computeSeriesTextLengths(novels);
          });
        } else if (novelSubMode == 1) {
          // 検索結果
          if (selectedNovelSearchTarget == 'all_text') {
            // 全文検索
            final result = await _pixivApiService.searchNovelAllText(
              _currentSearchWord,
              selectedSort,
              selectedNovelAgeLimit,
              null,
              null,
            );
            setState(() {
              novels = result.items;
              _allTextSearchState = result.state;
              nextOffset = result.state.textNextOffset;
              searchItem = result.result.searchItem;
              isLoading = false;
              _computeSeriesTextLengths(novels);
            });
          } else {
            // 通常検索
            final result = await _pixivApiService.searchNovel(
              _currentSearchWord,
              selectedNovelSearchTarget,
              selectedSort,
              0,
              selectedNovelAgeLimit,
              null,
              null,
              bookmarkFilter: selectedNovelBookmarkFilter,
              // Phase 2: 新規フィルター（null なら既存動作を維持）
              duration: selectedDuration == 'all' ? null : selectedDuration,
              startDate: effectiveStartDate,
              endDate: effectiveEndDate,
              bookmarkNumMin: effectiveBookmarkNumMin,
              bookmarkNumMax: effectiveBookmarkNumMax,
            );
            setState(() {
              novels = result.items;
              nextOffset = result.nextOffset;
              searchItem = result.searchItem;
              isLoading = false;
              _computeSeriesTextLengths(novels);
            });
          }
        } else if (novelSubMode == 2) {
          // ランキング
          final result = await _pixivApiService.getNovelRanking(
            selectedNovelRankMode,
            offset: 0,
          );
          setState(() {
            novels = result.items;
            nextOffset = result.nextOffset;
            isLoading = false;
            _computeSeriesTextLengths(novels);
          });
        }
      }

      // 小説一覧を取得したら未生成 Embedding をバックグラウンドで生成
      if (currentIndex == novelIndex && novels.isNotEmpty) {
        _generateEmbeddingsInBackground(novels);
      }
    } catch (e) {
      setState(() {
        isLoading = false;
        errorMessage = e.toString();
        if (errorMessage!.contains('429')) {
          rateLimited = true;
        }
      });
    }
  }

  /// 一覧に表示された小説のうち、Embedding が未生成のものをバックグラウンドで
  /// 静かに生成する。UI をブロックしない（await しない）。
  ///
  /// - EmbeddingService が未初期化ならスキップ（強制初期化しない）
  /// - 1回の呼び出しで最大 [_maxBackgroundEmbeddingsPerFetch] 件に制限
  /// - 生成中の work_id は [_backgroundEmbeddingInProgress] で管理（重複防止）
  /// - エラーは debugPrint のみ（アプリを落とさない）
  void _generateEmbeddingsInBackground(List<Novel> novels) {
    if (novels.isEmpty) return;
    // モデル未初期化なら何もしない（ユーザーが小説を開いた時の生成を優先）
    final embeddingService = EmbeddingService();
    if (!embeddingService.isInitialized) return;

    final candidateIds = novels.map((n) => n.id).where((id) => id > 0).toList();
    if (candidateIds.isEmpty) return;

    // 一覧取得直後は UI 描画が重いため、短いバッファを入れてから開始する。
    // （mounted チェックは不要だが、画面遷移でキャンセルされる可能性を考慮）
    unawaited(
      Future.delayed(const Duration(seconds: 2)).then((_) async {
        if (!EmbeddingService().isInitialized) return;
        await _runBackgroundEmbeddingGeneration(candidateIds);
      }),
    );
  }

  Future<void> _runBackgroundEmbeddingGeneration(List<int> candidateIds) async {
    // モデル未初期化なら何もしない（呼び出し側でも弾いているが念のため再確認）
    final embeddingService = EmbeddingService();
    if (!embeddingService.isInitialized) return;

    try {
      final targets = await DatabaseService().getWorkIdsWithoutEmbedding(
        candidateIds,
      );
      // 未生成かつ生成中でないものを最大上限件数まで選ぶ
      final toProcess = targets
          .where((id) => !_backgroundEmbeddingInProgress.contains(id))
          .take(_maxBackgroundEmbeddingsPerFetch)
          .toList();

      for (final workId in toProcess) {
        _backgroundEmbeddingInProgress.add(workId);
      }

      for (final workId in toProcess) {
        try {
          // 表示リストにない作品（DB上のIDのみ等）はスキップして続行
          final matches = novels.where((n) => n.id == workId);
          if (matches.isEmpty) {
            debugPrint(
              'vectorizeTagNovels: workId=$workId not found in displayed list, skip',
            );
            continue;
          }
          final novel = matches.first;
          final text = buildNovelDocumentText(novel);
          final vector = await embeddingService.encodeDocument(text);
          await DatabaseService().saveNovelEmbedding(
            workId: workId,
            embedding: vector,
          );
          await DatabaseService().saveNovel(novel);
        } catch (e) {
          debugPrint('background embedding failed for workId=$workId: $e');
        } finally {
          _backgroundEmbeddingInProgress.remove(workId);
        }
      }
    } catch (e) {
      debugPrint('background embedding extraction failed: $e');
    }
  }

  /// 表示中の小説タグ検索結果を一括でベクトル化（フィーリング検索の対象に追加）。
  ///
  /// - 小説タブの検索結果（[novels]）を対象とする
  /// - 既に novel_embeddings にあるものはスキップ
  /// - 1件ずつ順次処理し、各処理間に 200ms の間隔を空ける（ONNX 推論は重いため）
  /// - 未初期化なら自動で initialize() してから開始
  /// - 進捗は SnackBar で通知し、処理中も UI をブロックしない
  /// - mounted チェックでキャンセル可能（画面遷移等で安全に中断）
  Future<void> vectorizeTagNovels() async {
    if (currentIndex != novelIndex) return;
    if (searchItem == null) return;
    if (novels.isEmpty) return;

    final embeddingService = EmbeddingService();
    if (!embeddingService.isInitialized) {
      // 未初期化なら自動初期化（失敗したらメッセージを出して終了）
      try {
        await embeddingService.initialize();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('AIモデルの準備中に失敗しました: $e')));
        }
        return;
      }
      if (!embeddingService.isInitialized) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('AIモデルの準備中です。しばらくしてから再度お試しください。')),
          );
        }
        return;
      }
    }

    final candidateIds = novels.map((n) => n.id).where((id) => id > 0).toList();
    if (candidateIds.isEmpty) return;

    List<int> targets;
    try {
      targets = await DatabaseService().getWorkIdsWithoutEmbedding(
        candidateIds,
      );
    } catch (e) {
      debugPrint('vectorizeTagNovels: target extraction failed: $e');
      return;
    }
    // 重複・生成中を除外
    final toProcess = targets
        .where((id) => !_backgroundEmbeddingInProgress.contains(id))
        .toList();
    if (toProcess.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('すべての小説はすでに学習済みです。')));
      }
      return;
    }

    final total = toProcess.length;
    var done = 0;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('AI学習中: 0/$total 件完了')));
    }

    for (final workId in toProcess) {
      if (!mounted) break; // キャンセル（画面遷移等）
      _backgroundEmbeddingInProgress.add(workId);
      try {
        final novel = novels.firstWhere((n) => n.id == workId);
        final text = buildNovelDocumentText(novel);
        final vector = await embeddingService.encodeDocument(text);
        await DatabaseService().saveNovelEmbedding(
          workId: workId,
          embedding: vector,
        );
        await DatabaseService().saveNovel(novel);
        done++;
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('AI学習中: $done/$total 件完了')));
        }
      } catch (e) {
        debugPrint('vectorizeTagNovels: failed for workId=$workId: $e');
      } finally {
        _backgroundEmbeddingInProgress.remove(workId);
      }
      // 各処理間に 200ms の間隔を空ける（UI スレッドを解放）
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$done 件の小説をフィーリング検索の対象に追加しました')));
    }
  }

  // 次ページ取得
  Future<void> fetchNextPage() async {
    if (_isFetchingNextPage || nextOffset == null || rateLimited) return;

    setState(() {
      _isFetchingNextPage = true;
    });

    try {
      if (currentIndex == illustIndex) {
        // イラストモード
        if (illustSubMode == 0) {
          // おすすめ
          final result = await _pixivApiService.getRecommend(
            offset: nextOffset!,
          );
          setState(() {
            illusts.addAll(result.items);
            nextOffset = result.nextOffset;
            _isFetchingNextPage = false;
          });
        } else if (illustSubMode == 1) {
          // 検索結果
          final minBm = int.tryParse(minBookmarkController.text.trim());
          final effectiveBookmarkFilter = minBm != null && minBm > 0
              ? minBm
              : selectedBookmarkFilter;
          final result = await _pixivApiService.searchIllust(
            _currentSearchWord,
            selectedSearchTarget,
            selectedSort,
            nextOffset!,
            selectedAgeLimit,
            bookmarkFilter: effectiveBookmarkFilter,
            // Phase 2: 新規フィルター（null なら既存動作を維持）
            duration: selectedDuration == 'all' ? null : selectedDuration,
            startDate: effectiveStartDate,
            endDate: effectiveEndDate,
            bookmarkNumMin: effectiveBookmarkNumMin,
            bookmarkNumMax: effectiveBookmarkNumMax,
          );
          List<Illust> filtered = result.items;
          if (selectedIllustAiFilter != 'all') {
            filtered = filtered.where((it) {
              final isAi = it.aiType == 2;
              return selectedIllustAiFilter == 'only' ? isAi : !isAi;
            }).toList();
          }
          setState(() {
            illusts.addAll(filtered);
            nextOffset = result.nextOffset;
            searchItem = result.searchItem ?? searchItem;
            _isFetchingNextPage = false;
          });
        } else if (illustSubMode == 2) {
          // ランキング
          final result = await _pixivApiService.getRanking(
            selectedIllustRankMode,
            offset: nextOffset!,
          );
          setState(() {
            illusts.addAll(result.items);
            nextOffset = result.nextOffset;
            _isFetchingNextPage = false;
          });
        }
      } else if (currentIndex == novelIndex) {
        // 小説モード
        if (novelSubMode == 0) {
          // おすすめ
          final result = await _pixivApiService.getNovelRecommend(
            offset: nextOffset!,
          );
          setState(() {
            novels.addAll(result.items);
            nextOffset = result.nextOffset;
            _isFetchingNextPage = false;
            _computeSeriesTextLengths(novels);
          });
        } else if (novelSubMode == 1) {
          // 検索結果
          if (selectedNovelSearchTarget == 'all_text') {
            // 全文検索
            final result = await _pixivApiService.searchNovelAllText(
              _currentSearchWord,
              selectedSort,
              selectedNovelAgeLimit,
              null,
              null,
              state: _allTextSearchState,
            );
            setState(() {
              novels.addAll(result.items);
              _allTextSearchState = result.state;
              nextOffset = result.state.textNextOffset;
              _isFetchingNextPage = false;
              _computeSeriesTextLengths(novels);
            });
          } else {
            // 通常検索
            final result = await _pixivApiService.searchNovel(
              _currentSearchWord,
              selectedNovelSearchTarget,
              selectedSort,
              nextOffset!,
              selectedNovelAgeLimit,
              null,
              null,
              bookmarkFilter: selectedNovelBookmarkFilter,
              // Phase 2: 新規フィルター（null なら既存動作を維持）
              duration: selectedDuration == 'all' ? null : selectedDuration,
              startDate: effectiveStartDate,
              endDate: effectiveEndDate,
              bookmarkNumMin: effectiveBookmarkNumMin,
              bookmarkNumMax: effectiveBookmarkNumMax,
            );
            setState(() {
              novels.addAll(result.items);
              nextOffset = result.nextOffset;
              _isFetchingNextPage = false;
              _computeSeriesTextLengths(novels);
            });
          }
        } else if (novelSubMode == 2) {
          // ランキング
          final result = await _pixivApiService.getNovelRanking(
            selectedNovelRankMode,
            offset: nextOffset!,
          );
          setState(() {
            novels.addAll(result.items);
            nextOffset = result.nextOffset;
            _isFetchingNextPage = false;
            _computeSeriesTextLengths(novels);
          });
        }
      }

      // 追加取得した小説一覧でも未生成 Embedding をバックグラウンドで生成
      if (currentIndex == novelIndex && novels.isNotEmpty) {
        _generateEmbeddingsInBackground(novels);
      }
    } catch (e) {
      setState(() {
        _isFetchingNextPage = false;
        if (e.toString().contains('429')) {
          rateLimited = true;
        }
      });
    }
  }

  // シリーズ文字数キャッシュの計算
  Future<void> _computeSeriesTextLengths(List<Novel> novels) async {
    final seriesIds = novels
        .where((n) => n.series != null && n.series!.id != 0)
        .map((n) => n.series!.id)
        .toSet();

    for (final seriesId in seriesIds) {
      if (_seriesTotalTextLengthCache.containsKey(seriesId)) continue;

      try {
        final seriesNovels = await _pixivApiService.getNovelSeriesAll(seriesId);
        final totalLength = seriesNovels.fold<int>(
          0,
          (sum, n) => sum + n.textLength,
        );
        setState(() {
          _seriesTotalTextLengthCache[seriesId] = totalLength;
        });
      } catch (e) {
        // エラー時はキャッシュしない
      }
    }
  }

  // PKCE ログインダイアログ表示
  void showPKCELoginDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('アカウント連携'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Pixiv アカウントと連携しますか？'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _showWebViewLogin();
              },
              child: const Text('ログインする'),
            ),
          ],
        ),
      ),
    );
  }

  // 起動時にトークンを確認し、未ログインなら自動でログイン画面を表示する
  Future<void> _checkLoginOnStart() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('PIXIV_REFRESH_TOKEN');
    if (token == null || token.isEmpty) {
      // トークンが存在しない／空 → 自動ログイン
      if (mounted) _showWebViewLogin();
      return;
    }
    // 保存済みトークンの有効性を確認
    try {
      await _pixivApiService.getAccessToken(token);
      if (mounted) {
        setState(() => isLoggedIn = true);
      }
    } catch (e) {
      // 無効なトークン → 再ログイン
      if (mounted) _showWebViewLogin();
    }
  }

  // PKCE 用の code_verifier / code_challenge を生成（S256 方式）
  // code_verifier: 43〜128 文字の URL-safe ランダム文字列
  // 利用文字: A-Z a-z 0-9 - . _ ~
  static const String _pkceAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  String _generateCodeVerifier() {
    final rand = Random.secure();
    // 44文字（43〜128文字の範囲内）のランダム文字列を生成
    final length = 44;
    final buffer = StringBuffer();
    for (int i = 0; i < length; i++) {
      buffer.write(_pkceAlphabet[rand.nextInt(_pkceAlphabet.length)]);
    }
    return buffer.toString();
  }

  // code_verifier から S256 の code_challenge を算出
  // SHA-256(code_verifier) を URL-safe Base64（パディング=なし）でエンコード
  String _generateCodeChallenge(String codeVerifier) {
    final bytes = sha256.convert(utf8.encode(codeVerifier)).bytes;
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  // WebView を用いた PKCE ログイン画面の表示
  void _showWebViewLogin() {
    // 古いセッションCookieが残ると既存セッションが使われ、
    // OAuth の code 発行フローが正しく通らないため消去する
    WebViewCookieManager().clearCookies();
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..clearCache()
      ..clearLocalStorage()
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // pixiv:// スキームのリダイレクトは WebView に遷移させず捕捉する
            if (request.url.startsWith('pixiv://')) {
              _handleAuthRedirect(request.url, codeVerifier);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (error) {
            // 未知のスキーム等のリソースエラーでクラッシュしないよう無視する
            // （pixiv:// は onNavigationRequest で prevent 済みのため基本発生しない）
          },
        ),
      )
      ..loadRequest(
        Uri.parse(
          'https://app-api.pixiv.net/web/v1/login'
          '?code_challenge=$codeChallenge'
          '&code_challenge_method=S256'
          '&client=pixiv-android',
        ),
      );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('Pixiv ログイン')),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 480,
          child: WebViewWidget(controller: controller),
        ),
      ),
    );
  }

  // pixiv://auth リダイレクトから認証コードを取り出しトークンと交換
  Future<void> _handleAuthRedirect(String url, String codeVerifier) async {
    try {
      final uri = Uri.parse(url);
      final code = uri.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw Exception('認証コードが取得できませんでした。');
      }
      // 二重交換防止：既に交換中、または同一コードを処理済みならスキップ
      if (_isExchangingToken || _processedAuthCode == code) {
        return;
      }
      _isExchangingToken = true;
      _processedAuthCode = code;
      final refreshToken = await _exchangeCodeForToken(code, codeVerifier);
      // 既存のキーで保存
      _pixivApiService.setRefreshToken(refreshToken);
      if (mounted) {
        setState(() => isLoggedIn = true);
        Navigator.of(context).pop(); // WebView ダイアログを閉じる
        fetchData(); // ログイン後にホーム画面を更新
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ログインしました')));
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('ログイン失敗: $e')));
      }
    }
  }

  // 認証コードをリフレッシュトークンと交換する
  Future<String> _exchangeCodeForToken(String code, String codeVerifier) async {
    final response = await http.post(
      Uri.parse('https://oauth.secure.pixiv.net/auth/token'),
      headers: {
        'User-Agent': 'PixivAndroidApp/5.0.234 (Android 11.0; Pixel 5)',
        'App-OS': 'android',
        'App-OS-Version': '11.0',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'client_id': 'MOBrBDS8blbauoSck0ZfDbtuzpyT',
        'client_secret': 'lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj',
        'grant_type': 'authorization_code',
        'code_verifier': codeVerifier,
        'code': code,
        'include_policy': 'true',
        'redirect_uri':
            'https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback',
      },
    );
    if (response.statusCode == 200) {
      final resData = jsonDecode(response.body) as Map<String, dynamic>;
      final payload = resData['response'] as Map<String, dynamic>?;
      final refreshToken = payload?['refresh_token'] as String?;
      if (refreshToken != null && refreshToken.isNotEmpty) {
        return refreshToken;
      }
      throw Exception('リフレッシュトークンが取得できませんでした。');
    } else {
      // トークン・認証コード・code_verifier は出力しない
      debugPrint('[PKCE] token exchange failed: status=${response.statusCode}');
      debugPrint('[PKCE] response body: ${response.body}');
      throw Exception(
        'トークン交換に失敗しました (status: ${response.statusCode})\n'
        '${response.body}',
      );
    }
  }

  // ログアウト処理
  void logout() {
    setState(() {
      isLoggedIn = false;
      loggedInEmail = null;
    });
  }

  // 小説フィルターボトムシート表示
  void showNovelFilterBottomSheet() {
    _filterHandler.showNovelFilterBottomSheet();
  }

  // フィルターボトムシート表示
  void showFilterBottomSheet() {
    _filterHandler.showFilterBottomSheet();
  }

  // ドライブ同期初期化
  Future<void> _initializeDriveSync() async {
    await driveService.signInSilently();
    if (mounted && driveService.isLoggedIn) {
      setState(() {
        loggedInEmail = driveService.signedInEmail;
      });
    }
    // 最後の同期タイムスタンプを読み込み
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString('GOOGLE_DRIVE_LAST_SYNC');
    if (timestamp != null && mounted) {
      setState(() {
        lastSyncTimestamp = timestamp;
      });
    }
  }

  // ローディングダイアログ表示
  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );
  }

  // ローディングダイアログ非表示
  void _hideLoadingDialog() {
    Navigator.of(context, rootNavigator: true).pop();
  }

  // Google バックアップ処理
  Future<void> handleGoogleBackup() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => isBackingUp = true);
    _showLoadingDialog();
    try {
      final success = await driveService.backupJSON();
      _hideLoadingDialog();
      setState(() => isBackingUp = false);
      if (success && mounted) {
        final now = DateTime.now().toIso8601String();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('GOOGLE_DRIVE_LAST_SYNC', now);
        setState(() => lastSyncTimestamp = now);
        messenger.showSnackBar(const SnackBar(content: Text('バックアップ完了しました！')));
      }
    } catch (e) {
      _hideLoadingDialog();
      setState(() => isBackingUp = false);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('バックアップ失敗：$e')));
      }
    }
  }

  // Google 復元処理
  Future<void> handleGoogleRestore() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => isRestoring = true);
    _showLoadingDialog();
    try {
      final summary = await driveService.restoreJSON();
      _hideLoadingDialog();
      setState(() => isRestoring = false);
      if (summary != null && mounted) {
        final now = DateTime.now().toIso8601String();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('GOOGLE_DRIVE_LAST_SYNC', now);
        setState(() {
          lastSyncTimestamp = now;
          lastSyncSummary = summary;
        });
        final totalAdded = summary.values.fold<int>(0, (sum, v) => sum + v);
        messenger.showSnackBar(
          SnackBar(content: Text('復元完了しました！追加/更新：$totalAdded 件')),
        );
      }
    } catch (e) {
      _hideLoadingDialog();
      setState(() => isRestoring = false);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('復元失敗：$e')));
      }
    }
  }

  // Google ログイン処理
  Future<void> handleGoogleLogin() async {
    try {
      await driveService.signIn();
      if (mounted && driveService.isLoggedIn) {
        setState(() {
          loggedInEmail = driveService.signedInEmail;
        });
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Google ドライブにログインしました')));
        }
      } else if (mounted) {
        // null 返却（キャンセル）/ 例外による失敗のいずれでも、
        // 実エラー（code/message/details）から短い診断を生成して表示する。
        final msg =
            'Googleドライブログイン失敗：'
            '${describeSignInError(driveService.lastSignInError)}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 8)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ログイン失敗：${describeSignInError(e)}'),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  // Google ログアウト処理
  Future<void> handleGoogleLogout() async {
    await driveService.signOut();
    if (mounted) {
      setState(() {
        loggedInEmail = null;
      });
    }
  }

  // アプリ内しおり（読書進捗）の小説IDを1回だけ SharedPreferences から読み込み、
  // カード描画時に同期判定できるようメモリに保持する。
  Future<void> _loadLocalBookmarkIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idStrs = prefs.getStringList('novel_bookmark_ids') ?? [];
      localBookmarkIds
        ..clear()
        ..addAll(idStrs.map((s) => int.tryParse(s)).whereType<int>());
    } catch (e) {
      debugPrint('しおりIDの読み込み失敗：$e');
    }
  }

  @override
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

    final activeSubMode = currentIndex == illustIndex
        ? illustSubMode
        : novelSubMode;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              currentIndex == illustIndex
                  ? Icons.palette
                  : currentIndex == novelIndex
                  ? Icons.menu_book
                  : Icons.auto_awesome,
              color: Colors.pinkAccent,
            ),
            const SizedBox(width: 8),
            Text(
              currentIndex == illustIndex
                  ? 'Pixiv Illusts'
                  : currentIndex == novelIndex
                  ? 'Pixiv Novels'
                  : 'フィーリング発掘',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: isLoading ? null : fetchData,
            tooltip: '更新',
          ),
        ],
      ),
      drawer: Drawer(
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
              leading: const Icon(Icons.bookmark, color: Colors.pinkAccent),
              title: const Text('しおり一覧'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const BookmarkListScreen(),
                  ),
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
                  MaterialPageRoute(
                    builder: (context) => const HistoryScreen(),
                  ),
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
                  MaterialPageRoute(
                    builder: (context) => const FolderListScreen(),
                  ),
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
                  MaterialPageRoute(
                    builder: (context) => const MuteSettingsScreen(),
                  ),
                );
              },
            ),
            FutureBuilder<int>(
              future: DatabaseService().getSubscriptionUnreadCount(),
              initialData: 0,
              builder: (context, snapshot) {
                final unread = snapshot.data ?? 0;
                return ListTile(
                  leading: const Icon(Icons.stars, color: Colors.pinkAccent),
                  title: const Text('購読タグ'),
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
                              onSubscribedTagSelected(tag, type),
                        ),
                      ),
                    ).then((_) {
                      // 購読画面から戻った際に未読バッジを再取得・反映
                      if (mounted) setState(() {});
                    });
                  },
                );
              },
            ),
            FutureBuilder<int>(
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
                      MaterialPageRoute(
                        builder: (_) => const ReadLaterScreen(),
                      ),
                    );
                  },
                );
              },
            ),
            const Divider(height: 1, color: Colors.grey),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                'AI 機能',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
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
              leading: const Icon(Icons.image_search, color: Colors.pinkAccent),
              title: const Text('似た画像を探す'),
              subtitle: const Text('ダウンロード済み画像から似た作品を探す'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VisualSearchScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.construction, color: Colors.pinkAccent),
              title: const Text('AIインデックス管理'),
              subtitle: const Text('モデル・埋め込みの診断・修復'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AiIndexMaintenanceScreen(),
                  ),
                );
              },
            ),
            const Divider(height: 1, color: Colors.grey),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                'データ・保存',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart, color: Colors.pinkAccent),
              title: const Text('閲覧統計'),
              subtitle: const Text('閲覧・読書時間の分析'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const StatisticsScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.download_for_offline,
                color: Colors.pinkAccent,
              ),
              title: const Text('ダウンロード管理'),
              subtitle: const Text('イラスト・うごイラ・小説のダウンロード状況'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DownloadQueueScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.cloud_download,
                color: Colors.pinkAccent,
              ),
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
              leading: const Icon(Icons.find_replace, color: Colors.pinkAccent),
              title: const Text('重複画像の検出'),
              subtitle: const Text('完全一致・近似重複を見つけて整理'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DuplicateFinderScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.manage_accounts,
                color: Colors.pinkAccent,
              ),
              title: const Text('バックアップ管理'),
              subtitle: const Text('複数のバックアップの一覧・復元・削除'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const BackupManagerScreen(),
                  ),
                );
              },
            ),
            const Divider(height: 1, color: Colors.grey),
            // ログイン/ログアウトボタン
            ListTile(
              leading: Icon(
                isLoggedIn ? Icons.logout : Icons.login,
                color: Colors.pinkAccent,
              ),
              title: Text(isLoggedIn ? 'ログアウト' : 'アカウント連携（ログイン）'),
              onTap: () {
                Navigator.pop(context);
                if (isLoggedIn) {
                  logout();
                } else {
                  showPKCELoginDialog();
                }
              },
            ),
            const Divider(height: 1, color: Colors.grey),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                'Google ドライブ同期',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            _syncHandler.buildGoogleDriveSyncSection(),
          ],
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 検索バー (フィルターオプションボタン付き)
              // フィーリング発掘タブでは、画面側(AppBar.bottom)に専用検索バーがあるため非表示
              if (currentIndex != feelingDiscoveryIndex)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: searchController,
                          focusNode: searchFocusNode,
                          decoration: InputDecoration(
                            hintText: currentIndex == illustIndex
                                ? 'イラスト、タグ、キーワードを検索...'
                                : currentIndex == novelIndex
                                ? '小説、タグ、キーワードを検索...'
                                : '気分やキーワードを入力...',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: searchController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 18),
                                    onPressed: resetSearch,
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.4),
                            isDense: true,
                          ),
                          textInputAction: TextInputAction.search,
                          onSubmitted: onSearchSubmit,
                          onChanged: (val) {
                            // 入力中は検索候補（DB履歴 + 購読タグ）オーバーレイを表示
                            if (searchFocusNode.hasFocus && val.isNotEmpty) {
                              if (!_showHistoryList) {
                                setState(() => _showHistoryList = true);
                              } else {
                                setState(() {});
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          Icons.tune,
                          color: currentIndex == illustIndex
                              ? Colors.pinkAccent
                              : currentIndex == novelIndex
                              ? Colors.tealAccent
                              : Colors.amberAccent,
                        ),
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          if (currentIndex == illustIndex) {
                            showFilterBottomSheet();
                          } else if (currentIndex == novelIndex) {
                            showNovelFilterBottomSheet();
                          }
                          // フィーリング発掘タブではフィルターなし
                        },
                        tooltip: currentIndex == illustIndex
                            ? '検索フィルター'
                            : currentIndex == novelIndex
                            ? '小説検索フィルター'
                            : 'フィルターなし',
                      ),
                    ],
                  ),
                ),

              // 3. サブモードセレクター (おすすめ / ランキング)。※検索結果時はサブタブは表示しません。
              // フィーリング発掘タブでは非表示
              if (currentIndex != feelingDiscoveryIndex && activeSubMode != 1)
                _uiComponents.buildSubModeSelector(),

              // 4. ランキング時のモード切替
              // フィーリング発掘タブでは非表示
              if (currentIndex != feelingDiscoveryIndex)
                _uiComponents.buildRankingFilterBar(),

              // 5. 百科事典カード (検索モード時のみ)
              if (currentIndex != feelingDiscoveryIndex &&
                  activeSubMode == 1 &&
                  searchItem != null)
                _uiComponents.buildEncyclopediaCard(context),

              // 6. メインデータコンテンツ
              // フィーリング発掘はホーム側の共通ローディング/エラーに遮断されない
              // 独立画面として扱う（判定を isLoading / errorMessage より前に置く）
              Expanded(
                child: currentIndex == feelingDiscoveryIndex
                    ? const FeelingDiscoveryScreen()
                    : isLoading
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: Colors.pinkAccent),
                            SizedBox(height: 16),
                            Text(
                              'Pixiv からデータを取得中...',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : errorMessage != null
                    ? _uiComponents.buildErrorWidget()
                    : currentIndex == illustIndex
                    ? _uiComponents.buildIllustGrid(crossAxisCount)
                    : _uiComponents.buildNovelList(),
              ),
            ],
          ),

          // 🔍 検索履歴候補オーバーレイリスト
          if (_showHistoryList) _uiComponents.buildSearchHistoryOverlay(),

          // 🔄 サブスクリプション同期プログレス HUD
          if (isSyncing && _syncProgress != null)
            _uiComponents.buildSyncProgressHUD(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: changeTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.image_outlined),
            selectedIcon: Icon(Icons.image, color: Colors.pinkAccent),
            label: 'イラスト',
          ),
          NavigationDestination(
            icon: Icon(Icons.book_outlined),
            selectedIcon: Icon(Icons.book, color: Colors.pinkAccent),
            label: '小説',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome, color: Colors.pinkAccent),
            label: 'フィーリング発掘',
          ),
        ],
      ),
    );
  }
}
