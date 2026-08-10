import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../novel_model.dart';
import '../services/database_service.dart';
import '../services/embedding_service.dart';
import '../services/novel_document_text.dart';
import '../services/pixiv_api_service.dart';

part 'novel_reader_data.dart';
part 'novel_reader_ui_handler.dart';
part 'novel_reader_ui_components.dart';

class NovelReaderScreen extends StatefulWidget {
  final Novel novel;

  const NovelReaderScreen({super.key, required this.novel});

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

  // 自動しおり用のステート
  int _savedPageIndex = 0;
  double _savedScrollOffset = 0.0;
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

  @override
  void initState() {
    debugPrint('📍 [DEBUG Reader] initState 開始');
    super.initState();
    _currentNovel = widget.novel;
    _initSequence();
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
    // 画面破棄時にしおりを永続化
    _saveCurrentBookmark();
    _pageController?.dispose();
    for (var controller in _scrollControllers) {
      controller.dispose();
    }
    _currentPageNotifier.dispose();
    _progressNotifier.dispose();
    _showHUDNotifier.dispose();
    super.dispose();
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
