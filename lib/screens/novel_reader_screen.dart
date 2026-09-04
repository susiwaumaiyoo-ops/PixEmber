import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import '../services/database_service.dart';
import '../services/embedding_service.dart';
import '../services/emotion_curve_service.dart';
import '../services/novel_document_text.dart';
import '../services/novel_parser.dart';
import '../services/pixiv_api_service.dart';
import '../services/novel_tts_service.dart';
import '../services/reading_notes_service.dart';
import '../services/reading_speed_service.dart';
import '../services/ruri_model_manager.dart';
import '../services/series_progress_service.dart';
import '../services/usage_tracking_service.dart';
import '../widgets/pixiv_image.dart';
import 'full_screen_image_page.dart';

part 'novel_reader_data.dart';
part 'novel_reader_tts.dart';
part 'novel_reader_ui_handler.dart';
part 'novel_reader_ui_components.dart';

class NovelReaderScreen extends StatefulWidget {
  final Novel novel;

  /// 開いた直後にジャンプするページ番号（Phase C: 感情曲線タップジャンプ用）。
  /// null ならしおりから復元する。
  final int? initialPage;

  const NovelReaderScreen({super.key, required this.novel, this.initialPage});

  @override
  State<NovelReaderScreen> createState() => _NovelReaderScreenState();
}

class _NovelReaderScreenState extends State<NovelReaderScreen>
    with TickerProviderStateMixin {
  // Scaffold を一意に参照するためのキー（Drawer の安全な操作に使用）
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // 現在表示中の小説オブジェクト（シリーズ遷移に対応）
  late Novel _currentNovel;

  bool _isLoading = true;
  String? _errorMessage;
  NovelTextData? _textData;

  // 読書設定用ステート
  double _fontSize = 18.0;
  double _lineHeight = 1.8; // 行間 (1.4 - 2.6)
  double _leftPadding = 24.0; // 左マージン (12.0 - 400.0)
  double _rightPadding = 24.0; // 右マージン (12.0 - 400.0)
  int _themeMode = 1; // 0: 白背景, 1: セピア(文庫風), 2: 漆黒(ダーク)
  String _fontFamily = 'serif'; // デフォルトは読みやすい明朝体 (serif)
  RubyDisplayMode _rubyMode = RubyDisplayMode.show; // ルビ表示モード（Phase 1 設計書 §6.2）

  // pixivimage 解決キャッシュ（P1-8）: メモリ LRU 上限 20 + 進行中リクエストの重複排除。
  // Map リテラルは挿入順 LinkedHashMap のため remove→insert で LRU を表現する。
  final Map<int, Illust> _illustMemoryCache = {};
  final Map<int, Future<Illust?>> _illustResolveInFlight = {};

  // 自動しおり用のステート
  int _savedPageIndex = 0;
  double _savedScrollOffset = 0.0;
  // あとで読む進捗保存の頻度制御用（前回保存時の進捗率）
  double? _lastSavedReadLaterProgress;
  PageController? _pageController;
  List<ScrollController> _scrollControllers = [];
  bool _isDisposing = false; // 破棄中フラグ（リスナーのゴーストイベント防止）

  // ページ番号HUDの局所的更新用（setState回避で本文の再レイアウトを防止）
  final ValueNotifier<int> _currentPageNotifier = ValueNotifier<int>(0);

  // 読書進捗（0.0〜1.0）の局所的更新用（常時表示のプログレスバーに使用）
  final ValueNotifier<double> _progressNotifier = ValueNotifier<double>(0.0);

  // シリーズ小説用ステート
  List<Novel> _seriesNovels = [];
  bool _isLoadingSeries = false;
  // シリーズ進捗（Phase N3）: 目次Drawerの「読了 X/N ・ あと約XX分」表示用
  SeriesProgress? _seriesProgress;

  // 没頭モード（HUD表示トグル）
  bool _showHUD = true;
  // HUD表示状態の局所的更新用（setState回避でページ全文の再レイアウトを防止）
  final ValueNotifier<bool> _showHUDNotifier = ValueNotifier<bool>(true);

  // ページ本文ウィジェットのキャッシュ（スワイプバック時の毎フレーム再構築によるANR防止）
  List<Widget>? _cachedPages;
  String? _cachedPagesSignature;

  // 自動スクロール用ステート
  bool _isAutoScrolling = false;
  double _scrollSpeed = 3.0; // スクリプト速度 (1.0 - 10.0)
  Timer? _autoScrollTimer;

  // ページ内検索用ステート
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<int> _searchPageMatches = []; // 検索語を含むページインデックス
  int _searchMatchIndex = -1; // 現在の検索結果位置（-1=なし）
  bool _showSearchBar = false;

  // スリープタイマー用ステート
  Timer? _sleepTimer;
  int? _sleepMinutes;
  int _sleepRemainingSeconds = 0;

  // TTS読み上げ用ステート（Phase 3）
  NovelTtsService? _ttsService;
  bool _isTtsPlaying = false; // 再生中（一時停止含む）
  bool _isTtsPaused = false; // 一時停止中
  int _ttsCurrentIndex = -1; // 現在読み上げ中のチャンク番号
  int _ttsChunkTotal = 0; // 総チャンク数
  double _ttsRate = 1.0; // 読み上げ速度 (0.5 - 2.0)
  bool _ttsReadRuby = false; // true=ルビ（かな）を読む / false=親文字を読む
  int? _ttsResumeIndex; // 保存済み再開位置（本文ロード後に設定）
  bool _ttsInitializing = false; // 二重開始防止

  // 読書時間トラッキング（Phase 4）。この画面を開いている間＝読書時間。
  UsageSessionHandle? _usageSession;

  // 読了予測（Phase A）: 個人の読書速度（字/分）と表示ON/OFF設定。
  double _readerCpm = kDefaultCharsPerMinute;
  bool _readerCpmIsDefault = true;
  bool _showReadingTime = true;

  // 感情曲線（Phase C）: HUDの現在位置感情色設定とキャッシュ曲線。
  bool _showEmotionColor = false;
  bool _initialPageConsumed = false;
  EmotionCurveResult? _emotionCurve;
  final ValueNotifier<({Color color, String label})?> _emotionColorNotifier =
      ValueNotifier<({Color color, String label})?>(null);

  @override
  void initState() {
    debugPrint('📍 [DEBUG Reader] initState 開始');
    super.initState();
    _currentNovel = widget.novel;
    _initSequence();
    // 読書時間トラッキング開始（Phase 4）
    _usageSession = UsageTrackingService().startSession(
      workId: widget.novel.id,
      workType: 'novel',
    );
    debugPrint('📍 [DEBUG Reader] initState 終了');
  }

  // 破棄中/非マウント時に setState を呼ばない安全なヘルパ（defunct クラッシュ防止）
  void _safeSetState(VoidCallback fn) {
    if (_isDisposing || !mounted) return;
    setState(fn);
  }

  // 破棄中/非マウント時に notifyListeners を呼ばない安全なヘルパ
  void _safeNotifyHud(bool value) {
    if (_isDisposing || !mounted) return;
    _showHUDNotifier.value = value;
  }

  @override
  void dispose() {
    _isDisposing = true; // 👈 破棄開始を知らせる（最優先で実行）
    _sleepTimer?.cancel();
    _stopAutoScroll();
    // TTS読み上げを停止しエンジンも破棄（非同期のため fire-and-forget）
    final tts = _ttsService;
    if (tts != null) {
      unawaited(tts.disposeService());
    }
    // 読書時間セッションを確定（fire-and-forget）
    final usage = _usageSession;
    if (usage != null) {
      unawaited(UsageTrackingService().endSession(usage));
    }
    // 画面破棄時にしおりを永続化
    _saveCurrentBookmark();
    _pageController?.dispose();
    for (var controller in _scrollControllers) {
      controller.dispose();
    }
    _currentPageNotifier.dispose();
    _progressNotifier.dispose();
    _showHUDNotifier.dispose();
    _emotionColorNotifier.dispose();
    super.dispose();
  }

  /// 読書メモシートを開く（Phase N6）。現在ページに引用アンカーを付与。
  void _showNoteSheet(bool isDark) {
    final pages = _textData?.novelPages ?? const <String>[];
    final pageIndex = _currentPageNotifier.value.clamp(
      0,
      (pages.isEmpty ? 1 : pages.length) - 1,
    );
    String? anchor;
    if (pages.isNotEmpty) {
      anchor = extractAnchorText(pages[pageIndex]);
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark
          ? const Color(0xFF1E1E1E)
          : const Color(0xFFFAFAFA),
      builder: (_) => _NoteComposerSheet(
        workId: _currentNovel.id,
        workTitle: _currentNovel.title,
        pageIndex: pageIndex,
        anchorText: anchor,
        isDark: isDark,
        onJumpToPage: (int page) {
          Navigator.pop(context);
          _pageController?.jumpToPage(page);
          _currentPageNotifier.value = page;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('📍 [DEBUG Reader] build 開始');
    final bgColor = _getBgColor();
    final textColor = _getTextColor();
    final isDarkTheme = _themeMode == 2;

    // スワイプバック（システムの予測型バックジェスチャー）時に確実に pop する。
    // これがないと PageView の水平スワイプと競合し、back-invoke の再呼び出しループ
    // （OnBackInvokedCallbackWrapper が連続発火）で ANR/defunct クラッシュになる。
    final Widget result = PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (!mounted) return;
        Navigator.of(context).pop(result);
      },
      child: Scaffold(
        key: _scaffoldKey, // Drawer を確実に操作するためのキー
        backgroundColor: bgColor,
        // シリーズ目次サイドパネル Drawer
        endDrawer: Drawer(
          backgroundColor: isDarkTheme
              ? const Color(0xFF1E1E1E)
              : const Color(0xFFFAFAFA),
          child: _buildSeriesDrawerContent(isDarkTheme),
        ),
        // 本文目次（しおり/ジャンプ用）Drawer
        drawer: Drawer(
          backgroundColor: isDarkTheme
              ? const Color(0xFF1E1E1E)
              : const Color(0xFFFAFAFA),
          child: _buildNovelTocDrawer(isDarkTheme),
        ),
        // 没頭モードに対応するため、タップ可能領域としてGestureDetectorで本文部分をラップ
        body: Stack(
          children: [
            // 1. 小説本文エリア
            GestureDetector(
              onTap: () {
                // 全文の再レイアウトを避けるため、HUD表示はローカル通知でも反映させる
                _safeSetState(() {
                  _showHUD = !_showHUD;
                });
                _safeNotifyHud(_showHUD);
              },
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Colors.pinkAccent,
                      ),
                    )
                  : _errorMessage != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.warning,
                              color: Colors.amber,
                              size: 48,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _errorMessage ?? '',
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _fetchNovelText,
                              child: const Text('リトライ'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _buildNovelPages(textColor),
            ),

            // 2. 上部 AppBar（HUD表示時のみスライド表示）
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              top: _showHUD ? 0 : -100,
              left: 0,
              right: 0,
              child: Container(
                height: kToolbarHeight + MediaQuery.of(context).padding.top,
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top,
                ),
                decoration: BoxDecoration(
                  color: isDarkTheme ? const Color(0xFF1E1E1E) : Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 5,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 検索バー（表示時のみ）
                    if (_showSearchBar) _buildSearchBar(isDarkTheme),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.arrow_back,
                            color: isDarkTheme ? Colors.white : Colors.black87,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Text(
                            _currentNovel.title,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isDarkTheme
                                  ? Colors.white
                                  : Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 自動スクロール トグル
                        IconButton(
                          icon: Icon(
                            _isAutoScrolling
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                            color: _isAutoScrolling
                                ? Colors.pinkAccent
                                : (isDarkTheme
                                      ? Colors.white70
                                      : Colors.black54),
                          ),
                          onPressed: _toggleAutoScroll,
                          tooltip: _isAutoScrolling
                              ? '自動スクロールを一時停止'
                              : '自動スクロールを開始',
                        ),
                        // カスタマイズHUD表示
                        IconButton(
                          icon: Icon(
                            Icons.text_fields,
                            color: isDarkTheme
                                ? Colors.white70
                                : Colors.black54,
                          ),
                          onPressed: _showCustomizationHUD,
                          tooltip: 'テキスト・テーマ変更',
                        ),
                        // 本文目次（しおり/ジャンプ）Drawerを開く
                        Builder(
                          builder: (context) {
                            return IconButton(
                              icon: Icon(
                                Icons.menu_book,
                                color: isDarkTheme
                                    ? Colors.white70
                                    : Colors.black54,
                              ),
                              onPressed: () {
                                _scaffoldKey.currentState?.openDrawer();
                              },
                              tooltip: '本文目次',
                            );
                          },
                        ),
                        // 読書メモ（Phase N6）: 現在ページのメモ・引用
                        IconButton(
                          icon: Icon(
                            Icons.sticky_note_2,
                            color: isDarkTheme
                                ? Colors.white70
                                : Colors.black54,
                          ),
                          onPressed: () => _showNoteSheet(isDarkTheme),
                          tooltip: 'このページのメモ',
                        ),
                        // シリーズ目次 Drawerを開く
                        if (_currentNovel.series != null)
                          Builder(
                            builder: (context) {
                              return IconButton(
                                icon: Icon(
                                  Icons.format_list_bulleted,
                                  color: isDarkTheme
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                                onPressed: () {
                                  _scaffoldKey.currentState?.openEndDrawer();
                                },
                                tooltip: 'エピソード目次',
                              );
                            },
                          ),
                        // ページ内検索
                        IconButton(
                          icon: Icon(
                            Icons.search,
                            color: isDarkTheme
                                ? Colors.white70
                                : Colors.black54,
                          ),
                          onPressed: _toggleSearchBar,
                          tooltip: 'ページ内検索',
                        ),
                        // TTS読み上げ（Phase 3）
                        IconButton(
                          icon: Icon(
                            _isTtsPlaying
                                ? (_isTtsPaused
                                      ? Icons.play_circle_fill
                                      : Icons.pause_circle_filled)
                                : Icons.volume_up,
                            color: _isTtsPlaying
                                ? Colors.pinkAccent
                                : (isDarkTheme
                                      ? Colors.white70
                                      : Colors.black54),
                          ),
                          onPressed: _toggleTts,
                          tooltip: _isTtsPlaying
                              ? (_isTtsPaused ? '読み上げを再開' : '読み上げを一時停止')
                              : '小説を読み上げる',
                        ),
                        // スリープタイマー
                        IconButton(
                          icon: Icon(
                            _sleepMinutes != null
                                ? Icons.bedtime
                                : Icons.bedtime_outlined,
                            color: _sleepMinutes != null
                                ? Colors.pinkAccent
                                : (isDarkTheme
                                      ? Colors.white70
                                      : Colors.black54),
                          ),
                          onPressed: _showSleepTimerDialog,
                          tooltip: _sleepMinutes != null
                              ? 'スリープタイマー (${_formatSleepRemaining()})'
                              : 'スリープタイマー',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // 3. 下部操作コントロールHUD (自動スクロール調整、しおり・ページ調整)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              bottom: _showHUD ? 0 : -120,
              left: 0,
              right: 0,
              child: _buildBottomHUD(isDarkTheme),
            ),
          ],
        ),
      ),
    );
    debugPrint('📍 [DEBUG Reader] build 終了');
    return result;
  }
}
