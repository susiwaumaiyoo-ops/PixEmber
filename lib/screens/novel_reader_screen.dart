import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../novel_model.dart';
import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';

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

  @override
  void initState() {
    print('📍 [DEBUG Reader] initState 開始');
    super.initState();
    _currentNovel = widget.novel;
    _initSequence();
    print('📍 [DEBUG Reader] initState 終了');
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

  // 非同期の初期化シーケンス（.then チェーンを避け、順序制御を安全に行う）
  Future<void> _initSequence() async {
    await _loadPreferences();
    if (!mounted) return;
    await _initAndFetch();
  }

  // 永続化された設定（文字サイズやテーマなど）のロード
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _fontSize = prefs.getDouble('novel_pref_font_size') ?? 18.0;
        _lineHeight = prefs.getDouble('novel_pref_line_height') ?? 1.8;
        _leftPadding = prefs.getDouble('novel_pref_left_padding') ?? 24.0;
        _rightPadding = prefs.getDouble('novel_pref_right_padding') ?? 24.0;
        _themeMode = prefs.getInt('novel_pref_theme_mode') ?? 1;
        _fontFamily = prefs.getString('novel_pref_font_family') ?? 'serif';
        _scrollSpeed = prefs.getDouble('novel_pref_scroll_speed') ?? 3.0;
      });
    } catch (e) {
      debugPrint('環境設定の読み込みに失敗しました: $e');
    }
  }

  // 設定の保存
  Future<void> _savePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      await prefs.setDouble('novel_pref_font_size', _fontSize);
      await prefs.setDouble('novel_pref_line_height', _lineHeight);
      await prefs.setDouble('novel_pref_left_padding', _leftPadding);
      await prefs.setDouble('novel_pref_right_padding', _rightPadding);
      await prefs.setInt('novel_pref_theme_mode', _themeMode);
      await prefs.setString('novel_pref_font_family', _fontFamily);
      await prefs.setDouble('novel_pref_scroll_speed', _scrollSpeed);
    } catch (e) {
      debugPrint('環境設定の保存に失敗しました: $e');
    }
  }

  Future<void> _initAndFetch() async {
    _stopAutoScroll();
    if (!mounted) return;
    _safeSetState(() {
      _isLoading = true;
      _errorMessage = null;
      _textData = null;
    });

    // しおりのロード
    await _loadBookmark();
    // 本文の取得
    await _fetchNovelText();
    // 履歴登録
    _recordHistory();
    // シリーズ一覧の取得（未取得の場合、または別シリーズに移動した場合）
    // 無効なシリーズID（0 や null）の場合は不要なAPI通信エラー(400)を防ぐため呼び出さない
    if (_currentNovel.series != null && _currentNovel.series!.id != 0) {
      _fetchSeriesNovels();
    }
  }

  // 別エピソードへのシームレス遷移
  void _jumpToNovel(Novel targetNovel) {
    _stopAutoScroll();
    _pageController?.dispose();
    for (var controller in _scrollControllers) {
      controller.dispose();
    }
    _scrollControllers = [];

    _safeSetState(() {
      _currentNovel = targetNovel;
      _savedPageIndex = 0;
      _savedScrollOffset = 0.0;
      _cachedPages = null; // 別エピソードへ遷移するため本文キャッシュを無効化
    });
    _initAndFetch();
  }

  Future<void> _recordHistory() async {
    try {
      final db = DatabaseService();
      await db.insertOrUpdateHistory(
        workId: _currentNovel.id,
        title: _currentNovel.title,
        authorName: _currentNovel.author.name,
        previewUrl: _currentNovel.coverUrl,
        type: 'novel',
      );
    } catch (e) {
      print("⚠️ [History Save Error] 履歴の保存に失敗しました（処理は続行します）: $e");
    }
  }

  @override
  void dispose() {
    _isDisposing = true; // 👈 破棄開始を知らせる（最優先で実行）
    _stopAutoScroll();
    // 画面破棄時にしおりを永続化
    _saveCurrentBookmark();
    _pageController?.dispose();
    for (var controller in _scrollControllers) {
      controller.dispose();
    }
    _currentPageNotifier.dispose();
    _showHUDNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadBookmark() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      _savedPageIndex = prefs.getInt('novel_page_${_currentNovel.id}') ?? 0;
      _savedScrollOffset =
          prefs.getDouble('novel_offset_${_currentNovel.id}') ?? 0.0;
    } catch (e) {
      debugPrint('しおりのロードに失敗しました: $e');
    }
  }

  Future<void> _saveBookmark(int pageIndex, double offset) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      await prefs.setInt('novel_page_${_currentNovel.id}', pageIndex);
      await prefs.setDouble('novel_offset_${_currentNovel.id}', offset);

      // 進捗率の計算
      final totalPages = _textData?.novelPages.length ?? 1;
      double pageProgress = 0.0;
      if (_scrollControllers.isNotEmpty &&
          pageIndex < _scrollControllers.length) {
        final controller = _scrollControllers[pageIndex];
        if (controller.hasClients && controller.position.maxScrollExtent > 0) {
          final maxExtent = controller.position.maxScrollExtent;
          final pixels = controller.position.pixels.clamp(0.0, maxExtent);
          pageProgress = pixels / maxExtent;
        }
      }

      double progress = ((pageIndex + pageProgress) / totalPages) * 100.0;
      progress = progress.clamp(0.0, 100.0);

      await prefs.setDouble('novel_progress_${_currentNovel.id}', progress);
      await prefs.setInt('novel_total_pages_${_currentNovel.id}', totalPages);
      await prefs.setString(
        'novel_title_${_currentNovel.id}',
        _currentNovel.title,
      );
      await prefs.setString(
        'novel_author_${_currentNovel.id}',
        _currentNovel.author.name,
      );
      await prefs.setInt(
        'novel_last_read_${_currentNovel.id}',
        DateTime.now().millisecondsSinceEpoch,
      );

      // 履歴一覧に追加
      final List<String> bookmarkedIds =
          prefs.getStringList('novel_bookmark_ids') ?? [];
      final String idStr = _currentNovel.id.toString();
      if (!bookmarkedIds.contains(idStr)) {
        bookmarkedIds.add(idStr);
        await prefs.setStringList('novel_bookmark_ids', bookmarkedIds);
      }
    } catch (e) {
      debugPrint('しおりの保存に失敗しました: $e');
    }
  }

  // 現在の表示位置（ページ＋スクロールオフセット）からしおりを永続化するヘルパ
  Future<void> _saveCurrentBookmark() async {
    if (!mounted) return;
    final page = _pageController?.hasClients == true
        ? _pageController!.page?.round() ?? _savedPageIndex
        : _savedPageIndex;
    final offset =
        (page < _scrollControllers.length &&
            _scrollControllers[page].hasClients)
        ? _scrollControllers[page].position.pixels
        : _savedScrollOffset;
    await _saveBookmark(page, offset);
  }

  void _setupScrollControllers(int count) {
    for (var controller in _scrollControllers) {
      controller.dispose();
    }
    _scrollControllers = List.generate(count, (index) => ScrollController());

    for (int i = 0; i < _scrollControllers.length; i++) {
      _scrollControllers[i].addListener(() {
        // 👈 破棄中、またはすでにマウントされていない場合は即時終了
        if (_isDisposing || !mounted) return;

        final currentPage = _pageController?.hasClients == true
            ? _pageController!.page?.round() ?? 0
            : _savedPageIndex;
        // スクロール中はメモリ上の変数のみ更新し、I/O（SharedPreferences書き込み）は行わない
        // （秒間数十回のディスク書き込みによるカクつきを完全に防止）
        if (currentPage == i) {
          _savedScrollOffset = _scrollControllers[i].position.pixels;
          _savedPageIndex = i;
        }
      });
    }
  }

  Future<void> _fetchNovelText() async {
    print('📍 [DEBUG Reader] _fetchNovelText 開始');
    try {
      final api = PixivApiService();
      print('📍 [DEBUG Reader] _fetchNovelText API呼び出し直前: ${_currentNovel.id}');
      final textData = await api.getNovelText(_currentNovel.id);
      print('📍 [DEBUG Reader] _fetchNovelText API呼び出し成功');

      if (mounted) {
        _safeSetState(() {
          _textData = textData;
          _isLoading = false;

          final totalPages = _textData?.novelPages.length ?? 1;
          if (_savedPageIndex >= totalPages) {
            _savedPageIndex = 0;
            _savedScrollOffset = 0.0;
          }

          _pageController = PageController(initialPage: _savedPageIndex);
          _currentPageNotifier.value = _savedPageIndex;
          _setupScrollControllers(totalPages);
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_savedPageIndex < _scrollControllers.length) {
            final controller = _scrollControllers[_savedPageIndex];
            if (controller.hasClients) {
              controller.jumpTo(_savedScrollOffset);
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        _safeSetState(() {
          _errorMessage = '小説本文の取得に失敗しました: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchSeriesNovels() async {
    print('📍 [DEBUG Reader] _fetchSeriesNovels 開始');
    final series = _currentNovel.series;
    if (series == null) return;

    _safeSetState(() {
      _isLoadingSeries = true;
    });

    try {
      final api = PixivApiService();
      print('📍 [DEBUG Reader] _fetchSeriesNovels API呼び出し直前: ${series.id}');
      final list = await api.getNovelSeries(series.id);
      print('📍 [DEBUG Reader] _fetchSeriesNovels API呼び出し成功');

      if (!mounted) return;
      _safeSetState(() {
        _seriesNovels = list;
        _isLoadingSeries = false;
      });
    } catch (e) {
      debugPrint('シリーズ一覧取得エラー: $e');
      // 画面が Pop 途中の場合は defunct エラーを防ぐため生存確認を最優先で行う
      if (!mounted) return;
      _safeSetState(() => _isLoadingSeries = false);
    }
  }

  // 自動スクロールの制御
  void _toggleAutoScroll() {
    if (_isAutoScrolling) {
      _stopAutoScroll();
    } else {
      _startAutoScroll();
    }
  }

  void _startAutoScroll() {
    _stopAutoScroll();
    _safeSetState(() {
      _isAutoScrolling = true;
      _showHUD = false; // 自動スクロール開始時はHUDを閉じて読書に没頭させる
    });
    _safeNotifyHud(_showHUD);

    // 自動スクロール開始時にしおりを永続化
    _saveCurrentBookmark();

    // 50ミリ秒ごとにわずかにスクロールさせるタイマー
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 50), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel(); // 👈 画面が破棄されていたらタイマーをキャンセルして即座に終了
        return;
      }
      if (_pageController == null) return;
      final currentPage = _pageController!.hasClients
          ? _pageController!.page?.round() ?? 0
          : _savedPageIndex;

      if (currentPage < _scrollControllers.length) {
        final controller = _scrollControllers[currentPage];
        if (controller.hasClients) {
          final maxExtent = controller.position.maxScrollExtent;
          final currentPixels = controller.position.pixels;

          if (currentPixels >= maxExtent - 1.0) {
            // ページの末尾に達した
            _stopAutoScroll();
            final totalPages = _textData?.novelPages.length ?? 1;
            if (currentPage < totalPages - 1) {
              // 次のページへ遷移
              _pageController?.nextPage(
                duration: const Duration(milliseconds: 800),
                curve: Curves.easeInOut,
              );
              // 1.5秒待ってから自動スクロールを再起動 (余韻をもたせる)
              Future.delayed(const Duration(milliseconds: 1500), () {
                if (mounted && !_isAutoScrolling && _pageController != null) {
                  final newPage = _pageController!.page?.round() ?? 0;
                  if (newPage > currentPage) {
                    _startAutoScroll();
                  }
                }
              });
            }
          } else {
            // スピードに応じたスクロール (1〜10の速度に対応)
            // 50msなので、速度3であれば 1.5ピクセルずつ動かす
            final delta = _scrollSpeed * 0.4;
            controller.jumpTo((currentPixels + delta).clamp(0.0, maxExtent));
          }
        }
      }
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    if (mounted) {
      _safeSetState(() {
        _isAutoScrolling = false;
      });
    }
    // 自動スクロール停止時にしおりを永続化
    _saveCurrentBookmark();
  }

  // 背景色テーマ定義
  Color _getBgColor() {
    switch (_themeMode) {
      case 0:
        return const Color(0xFFFAFAFA); // ホワイト
      case 1:
        return const Color(0xFFF5EEDC); // セピア（読書用紙風）
      case 2:
      default:
        return const Color(0xFF121212); // 漆黒
    }
  }

  // 文字色定義
  Color _getTextColor() {
    switch (_themeMode) {
      case 0:
        return const Color(0xFF1E1E1E);
      case 1:
        return const Color(0xFF4A341A); // 深い焦げ茶
      case 2:
      default:
        return const Color(0xFFE0E0E0); // ライトグレー
    }
  }

  Novel? _getPreviousNovel() {
    if (_seriesNovels.isEmpty) return null;
    final currentIndex = _seriesNovels.indexWhere(
      (n) => n.id == _currentNovel.id,
    );
    if (currentIndex > 0) {
      return _seriesNovels[currentIndex - 1];
    }
    return null;
  }

  Novel? _getNextNovel() {
    if (_seriesNovels.isEmpty) return null;
    final currentIndex = _seriesNovels.indexWhere(
      (n) => n.id == _currentNovel.id,
    );
    if (currentIndex != -1 && currentIndex < _seriesNovels.length - 1) {
      return _seriesNovels[currentIndex + 1];
    }
    return null;
  }

  // 環境設定HUD（ボトム調整パネル）の表示
  void _showCustomizationHUD() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _themeMode == 2 ? const Color(0xFF1F1F1F) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isDark = _themeMode == 2;
            final sheetTextColor = isDark ? Colors.white : Colors.black87;

            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '読書環境カスタマイズ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: sheetTextColor,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),

                    // 背景テーマ切り替え
                    Text(
                      '背景テーマ',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildThemeButton(
                          0,
                          'ホワイト',
                          const Color(0xFFFAFAFA),
                          Colors.black,
                          setSheetState,
                        ),
                        const SizedBox(width: 10),
                        _buildThemeButton(
                          1,
                          'セピア紙',
                          const Color(0xFFF5EEDC),
                          const Color(0xFF4A341A),
                          setSheetState,
                        ),
                        const SizedBox(width: 10),
                        _buildThemeButton(
                          2,
                          '漆黒極夜',
                          const Color(0xFF121212),
                          Colors.white70,
                          setSheetState,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // フォント書体
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'フォント書体',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SegmentedButton<String>(
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: 'serif',
                              label: Text(
                                '明朝体',
                                style: TextStyle(
                                  fontFamily: 'serif',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            ButtonSegment(
                              value: 'sans-serif',
                              label: Text(
                                'ゴシック',
                                style: TextStyle(
                                  fontFamily: 'sans-serif',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            ButtonSegment(
                              value: 'monospace',
                              label: Text(
                                '等幅',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                          selected: {_fontFamily},
                          onSelectionChanged: (newSelection) {
                            _safeSetState(() {
                              _fontFamily = newSelection.first;
                              _cachedPages = null; // 本文キャッシュを無効化
                            });
                            setSheetState(() {});
                            _savePreferences();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // 文字サイズ
                    _buildSliderRow(
                      label: '文字サイズ',
                      value: _fontSize,
                      min: 12.0,
                      max: 28.0,
                      displayValue: '${_fontSize.round()} pt',
                      onChanged: (val) {
                        _safeSetState(() {
                          _fontSize = val;
                          _cachedPages = null; // 本文キャッシュを無効化
                        });
                        setSheetState(() {});
                        _savePreferences();
                      },
                    ),

                    // 行間
                    _buildSliderRow(
                      label: '行間マージン',
                      value: _lineHeight,
                      min: 1.4,
                      max: 2.6,
                      displayValue: _lineHeight.toStringAsFixed(1),
                      onChanged: (val) {
                        _safeSetState(() {
                          _lineHeight = val;
                          _cachedPages = null; // 本文キャッシュを無効化
                        });
                        setSheetState(() {});
                        _savePreferences();
                      },
                    ),

                    // 左マージン
                    _buildSliderRow(
                      label: '左マージン',
                      value: _leftPadding,
                      min: 12.0,
                      max: 400.0,
                      displayValue: '${_leftPadding.round()} px',
                      onChanged: (val) {
                        _safeSetState(() {
                          _leftPadding = val;
                          _cachedPages = null; // 本文キャッシュを無効化
                        });
                        setSheetState(() {});
                        _savePreferences();
                      },
                    ),
                    const SizedBox(height: 16),
                    // 右マージン
                    _buildSliderRow(
                      label: '右マージン',
                      value: _rightPadding,
                      min: 12.0,
                      max: 400.0,
                      displayValue: '${_rightPadding.round()} px',
                      onChanged: (val) {
                        _safeSetState(() {
                          _rightPadding = val;
                          _cachedPages = null; // 本文キャッシュを無効化
                        });
                        setSheetState(() {});
                        _savePreferences();
                      },
                    ),

                    // 自動スクロール速度（自動スクロール中にも使える）
                    _buildSliderRow(
                      label: '自動スクロール速度',
                      value: _scrollSpeed,
                      min: 1.0,
                      max: 10.0,
                      displayValue: 'Lv ${_scrollSpeed.toStringAsFixed(1)}',
                      onChanged: (val) {
                        _safeSetState(() {
                          _scrollSpeed = val;
                        });
                        setSheetState(() {});
                        _savePreferences();
                        // 動作中の場合は自動更新される
                      },
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildThemeButton(
    int mode,
    String label,
    Color bg,
    Color text,
    StateSetter setSheetState,
  ) {
    final isSelected = _themeMode == mode;
    return Expanded(
      child: InkWell(
        onTap: () {
          _safeSetState(() {
            _themeMode = mode;
            _cachedPages = null; // 本文キャッシュを無効化
          });
          setSheetState(() {});
          _savePreferences();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? Colors.pinkAccent
                  : Colors.grey.withValues(alpha: 0.3),
              width: isSelected ? 2.5 : 1.0,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.pinkAccent.withValues(alpha: 0.2),
                      blurRadius: 4,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: text,
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
  }) {
    final isDark = _themeMode == 2;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white70 : Colors.black87,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                displayValue,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.pinkAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            activeColor: Colors.pinkAccent,
            inactiveColor: Colors.grey.withValues(alpha: 0.3),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    print('📍 [DEBUG Reader] build 開始');
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
                child: Row(
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
                          color: isDarkTheme ? Colors.white : Colors.black87,
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
                            : (isDarkTheme ? Colors.white70 : Colors.black54),
                      ),
                      onPressed: _toggleAutoScroll,
                      tooltip: _isAutoScrolling ? '自動スクロールを一時停止' : '自動スクロールを開始',
                    ),
                    // カスタマイズHUD表示
                    IconButton(
                      icon: Icon(
                        Icons.text_fields,
                        color: isDarkTheme ? Colors.white70 : Colors.black54,
                      ),
                      onPressed: _showCustomizationHUD,
                      tooltip: 'テキスト・テーマ変更',
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
    print('📍 [DEBUG Reader] build 終了');
    return result;
  }

  // 下部HUDコントロールバー
  Widget _buildBottomHUD(bool isDark) {
    final totalPages = _textData?.novelPages.length ?? 1;
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: 12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 5,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ページ番号は ValueNotifier で局所更新（setState回避で本文の再レイアウトを防止）
          ValueListenableBuilder<int>(
            valueListenable: _currentPageNotifier,
            builder: (context, pageIndex, _) {
              final currentPage = pageIndex + 1;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'エピソード進捗',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                      Text(
                        '$currentPage / $totalPages ページ',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.pinkAccent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 簡易スライダーでページジャンプ
                  if (totalPages > 1)
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                      ),
                      child: Slider(
                        value: currentPage.toDouble().clamp(
                          1.0,
                          totalPages.toDouble(),
                        ),
                        min: 1.0,
                        max: totalPages.toDouble(),
                        activeColor: Colors.pinkAccent,
                        inactiveColor: Colors.grey.withValues(alpha: 0.3),
                        onChanged: (val) {
                          final targetPage = val.round() - 1;
                          _pageController?.jumpToPage(targetPage);
                          _currentPageNotifier.value =
                              targetPage; // setState回避で局所更新
                        },
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),

          // 自動スクロール簡易トグル + 速度調整インジケーター
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // クイック自動スクロールスイッチ
              InkWell(
                onTap: _toggleAutoScroll,
                child: Row(
                  children: [
                    Icon(
                      _isAutoScrolling ? Icons.pause : Icons.play_arrow,
                      color: Colors.pinkAccent,
                      size: 18,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isAutoScrolling ? 'スクロール停止' : '自動スクロール',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.pinkAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              // 簡易カスタマイズボタン
              TextButton.icon(
                onPressed: _showCustomizationHUD,
                icon: const Icon(
                  Icons.tune,
                  size: 16,
                  color: Colors.pinkAccent,
                ),
                label: const Text(
                  'クイック設定',
                  style: TextStyle(fontSize: 12, color: Colors.pinkAccent),
                ),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // シリーズ目次 Drawer コンテンツ
  Widget _buildSeriesDrawerContent(bool isDark) {
    final sheetTextColor = isDark ? Colors.white : Colors.black87;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.auto_stories,
                      color: Colors.pinkAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _currentNovel.series?.title ?? 'シリーズ目次',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: sheetTextColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '連載エピソード一覧',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.grey),
          Expanded(
            child: _isLoadingSeries
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.pinkAccent),
                  )
                : _seriesNovels.isEmpty
                ? const Center(
                    child: Text(
                      'シリーズのエピソードが\n見つかりませんでした。',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _seriesNovels.length,
                    itemBuilder: (context, idx) {
                      final item = _seriesNovels[idx];
                      final isCurrent = item.id == _currentNovel.id;

                      return InkWell(
                        onTap: () {
                          Navigator.pop(context); // Drawerを閉じる
                          _jumpToNovel(item);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          color: isCurrent
                              ? Colors.pinkAccent.withValues(alpha: 0.1)
                              : Colors.transparent,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // 話数インデックス
                              Container(
                                width: 24,
                                alignment: Alignment.center,
                                child: Text(
                                  '${idx + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: isCurrent
                                        ? Colors.pinkAccent
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // エピソードタイトル
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: isCurrent
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: isCurrent
                                            ? Colors.pinkAccent
                                            : sheetTextColor,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (item.caption.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        item.caption,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.grey[600],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (isCurrent) ...[
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.menu_book,
                                  color: Colors.pinkAccent,
                                  size: 16,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // 小説本文をページ単位で表示
  Widget _buildNovelPages(Color textColor) {
    final pages = _textData?.novelPages ?? [];
    print('📍 [DEBUG Reader] ループ開始: pages.length = ${pages.length}');

    if (pages.isEmpty) {
      final text = _textData?.novelText ?? '本文がありません。';
      return _buildPageContent(text, textColor, 0, 1);
    }

    // スワイプバック等で build が毎フレーム呼ばれても全文を再構築しないようキャッシュする。
    // 本文/テーマ/フォント/シリーズ等の「内容に影響する状態」が変わったときだけ再構築する。
    final signature = _pagesSignature(textColor, pages.length);
    if (_cachedPages == null || _cachedPagesSignature != signature) {
      _cachedPages = List.generate(pages.length, (i) {
        return _buildPageContent(pages[i], textColor, i, pages.length);
      });
      _cachedPagesSignature = signature;
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: pages.length,
      // 1ページのみのときは横スワイプを無効化し、左端のシステム「戻る」ジェスチャーを
      // PageView が奪わないようにする（これが swipe-back 時の back-invoke ループ/ANR の根因）
      physics: pages.length <= 1 ? const NeverScrollableScrollPhysics() : null,
      onPageChanged: (index) {
        _savedPageIndex = index;
        _savedScrollOffset = 0.0;
        _currentPageNotifier.value = index; // 局所的にHUDのみ更新（setState回避）
        _saveBookmark(index, 0.0); // ページ切り替わり時のみ永続化
      },
      itemBuilder: (context, index) {
        print('📍 [DEBUG Reader] ループ中: index = $index / ${pages.length}');
        return _cachedPages![index];
      },
    );
  }

  // ページ本文キャッシュの妥当性を判定する署名（内容に影響する状態のみを含める）
  String _pagesSignature(Color textColor, int pageCount) {
    return '$textColor|${_themeMode}|${_fontSize}|${_lineHeight}|'
        '${_leftPadding}|${_rightPadding}|${_fontFamily}|'
        '${_currentNovel.id}|${_currentNovel.title}|${_currentNovel.author.name}|'
        '${_seriesNovels.length}|$pageCount';
  }

  // 各ページのコンテンツ描画
  Widget _buildPageContent(
    String content,
    Color textColor,
    int pageIndex,
    int totalPages,
  ) {
    final ScrollController? sController =
        _scrollControllers.isNotEmpty && pageIndex < _scrollControllers.length
        ? _scrollControllers[pageIndex]
        : null;

    final prevNovel = _getPreviousNovel();
    final nextNovel = _getNextNovel();
    final hasSeriesControl = _currentNovel.series != null;

    return Column(
      children: [
        // 1. ページヘッダー（没頭モード中は透明化 / HUD状態はローカル通知で切り替え）
        ValueListenableBuilder<bool>(
          valueListenable: _showHUDNotifier,
          builder: (context, showHUD, _) {
            return AnimatedOpacity(
              opacity: showHUD ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: Padding(
                padding: EdgeInsets.only(
                  top: kToolbarHeight + MediaQuery.of(context).padding.top + 10,
                  left: 20,
                  right: 20,
                  bottom: 10,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _currentNovel.author.name,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                    ),
                    Text(
                      '${pageIndex + 1} / $totalPages ページ',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),

        // 2. 本文スクロール領域
        Expanded(
          child: SingleChildScrollView(
            controller: sController,
            padding: EdgeInsets.fromLTRB(_leftPadding, 12, _rightPadding, 160),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 最初のページのみ小説の表題・作者名を表示
                if (pageIndex == 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    _currentNovel.title,
                    style: TextStyle(
                      fontSize: _fontSize + 6.0,
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                      color: textColor,
                      fontFamily: _fontFamily,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '著者：${_currentNovel.author.name}',
                    style: TextStyle(
                      fontSize: _fontSize - 2.0,
                      color: textColor.withValues(alpha: 0.8),
                      fontFamily: _fontFamily,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 36),
                  const Divider(color: Colors.grey, thickness: 0.5),
                  const SizedBox(height: 30),
                ],

                // 本文テキスト（ルビ記法 [[rb:親 > ルビ]] を文庫本風にパース）
                _parseRubyText(
                  _formatParagraphs(content),
                  textColor,
                  _fontSize,
                  _lineHeight,
                ),

                // 最終ページの場合のみ、シリーズ用ナビゲーションUIを表示
                if (pageIndex == totalPages - 1 && hasSeriesControl) ...[
                  const SizedBox(height: 60),
                  const Divider(color: Colors.grey, thickness: 0.5),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      '――― シリーズ小説ナビゲーション ―――',
                      style: TextStyle(
                        fontSize: 12,
                        color: textColor.withValues(alpha: 0.5),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // 前の話
                      ElevatedButton.icon(
                        onPressed: prevNovel != null
                            ? () => _jumpToNovel(prevNovel)
                            : null,
                        icon: const Icon(Icons.arrow_back, size: 16),
                        label: const Text('前の話'),
                        style: ElevatedButton.styleFrom(
                          foregroundColor: _themeMode == 0
                              ? Colors.black87
                              : Colors.white,
                          backgroundColor: _themeMode == 0
                              ? Colors.grey[200]
                              : Colors.grey[800],
                          disabledForegroundColor: Colors.grey.withValues(
                            alpha: 0.3,
                          ),
                          disabledBackgroundColor: Colors.grey.withValues(
                            alpha: 0.1,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // 目次
                      ElevatedButton.icon(
                        onPressed: () {
                          // Drawerを安全に開くためのキー経由アクセス
                          _scaffoldKey.currentState?.openEndDrawer();
                        },
                        icon: const Icon(Icons.format_list_bulleted, size: 16),
                        label: const Text('目次一覧'),
                        style: ElevatedButton.styleFrom(
                          foregroundColor: Colors.pinkAccent,
                          backgroundColor: _themeMode == 0
                              ? Colors.pink[50]
                              : const Color(0xFF2C1C24),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // 次の話
                      ElevatedButton.icon(
                        onPressed: nextNovel != null
                            ? () => _jumpToNovel(nextNovel)
                            : null,
                        icon: const Icon(Icons.arrow_forward, size: 16),
                        label: const Text('次の話'),
                        style: ElevatedButton.styleFrom(
                          foregroundColor: _themeMode == 0
                              ? Colors.black87
                              : Colors.white,
                          backgroundColor: _themeMode == 0
                              ? Colors.grey[200]
                              : Colors.grey[800],
                          disabledForegroundColor: Colors.grey.withValues(
                            alpha: 0.3,
                          ),
                          disabledBackgroundColor: Colors.grey.withValues(
                            alpha: 0.1,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 30),
                ],
              ],
            ),
          ),
        ),

        // 3. ページフッター（没頭モード中は透明化 / HUD状態はローカル通知で切り替え）
        ValueListenableBuilder<bool>(
          valueListenable: _showHUDNotifier,
          builder: (context, showHUD, _) {
            return AnimatedOpacity(
              opacity: showHUD ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: 12 + MediaQuery.of(context).padding.bottom,
                  top: 8,
                  left: 20,
                  right: 20,
                ),
                child: Center(
                  child: Text(
                    'タップしてメニューをトグル',
                    style: TextStyle(
                      fontSize: 10,
                      color: textColor.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // 段落改行のフォーマット
  String _formatParagraphs(String text) {
    var cleaned = text.replaceAll('[newpage]', '');
    // 空行を適切に圧縮・字下げなどの和文小説特有の成形が必要であればここで処理可能
    return cleaned;
  }

  // Pixiv のルビ記法 [[rb:親文字 > ルビ]] を文庫本風の縦並びルビ表示にパースする。
  // ルビ箇所は WidgetSpan 内の Column（ルビ→親文字）で埋め込み、通常箇所は TextSpan とする。
  Widget _parseRubyText(
    String text,
    Color textColor,
    double fontSize,
    double lineHeight,
  ) {
    final rubyRegex = RegExp(r'\[\[rb:(.+?)\s*>\s*(.+?)\]\]');
    final spans = <InlineSpan>[];
    int lastMatchEnd = 0;
    final rubyFontSize = fontSize * 0.5;

    for (final match in rubyRegex.allMatches(text)) {
      if (match.start > lastMatchEnd) {
        spans.add(
          TextSpan(
            text: text.substring(lastMatchEnd, match.start),
            style: TextStyle(
              fontSize: fontSize,
              height: lineHeight,
              color: textColor,
              fontFamily: _fontFamily,
              letterSpacing: 0.8,
            ),
          ),
        );
      }
      final baseText = match.group(1) ?? '';
      final rubyText = match.group(2) ?? '';
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                rubyText,
                style: TextStyle(
                  fontSize: rubyFontSize,
                  height: 1.0,
                  color: textColor,
                  fontFamily: _fontFamily,
                ),
                textAlign: TextAlign.center,
              ),
              Text(
                baseText,
                style: TextStyle(
                  fontSize: fontSize,
                  height: 1.0,
                  color: textColor,
                  fontFamily: _fontFamily,
                  letterSpacing: 0.8,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
      lastMatchEnd = match.end;
    }

    // 残りの通常テキスト
    if (lastMatchEnd < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(lastMatchEnd),
          style: TextStyle(
            fontSize: fontSize,
            height: lineHeight,
            color: textColor,
            fontFamily: _fontFamily,
            letterSpacing: 0.8,
          ),
        ),
      );
    }

    return RichText(
      text: TextSpan(children: spans),
      textAlign: TextAlign.left,
    );
  }
}
