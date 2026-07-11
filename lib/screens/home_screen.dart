import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import '../services/google_drive_service.dart';
import '../services/pixiv_api_service.dart';
import '../widgets/pixiv_image.dart';
import 'illust_detail_screen.dart';
import 'novel_detail_screen.dart';
import 'history_screen.dart';
import 'mute_settings_screen.dart';
import 'folder_list_screen.dart';

class PixivViewerHome extends StatefulWidget {
  const PixivViewerHome({super.key});

  @override
  State<PixivViewerHome> createState() => _PixivViewerHomeState();
}

class _PixivViewerHomeState extends State<PixivViewerHome> {
  final GoogleDriveService _driveService = GoogleDriveService();
  final PixivApiService _pixivApiService = PixivApiService();
  String? _loggedInEmail;
  bool _isLoggedIn = false;

  // サブスクリプション同期用の状態変数
  Map<String, dynamic>? _syncProgress;
  Timer? _syncTimer;
  final bool _isSyncing = false;

  late final TextEditingController _searchController;
  final FocusNode _searchFocusNode = FocusNode();

  // 共有される検索条件State（カテゴリを跨いで保持されます）
  String _currentSearchWord = '';
  String _selectedSearchTarget =
      'partial_match_for_tags'; // partial_match_for_tags, exact_match_for_tags, title_and_caption
  String _selectedSort = 'date_desc'; // date_desc, date_asc, popular_desc

  // 高度な検索フィルター設定
  String _selectedWorkType = 'all'; // all, illust, manga, ugoira, novel
  String _selectedAgeLimit = 'all'; // all, safe, r18
  String _selectedDuration =
      'all'; // all, within_last_day, within_last_week, within_last_month
  int _selectedBookmarkFilter = 0; // 0, 100, 500, 1000, 5000, 10000

  // 小説専用の検索フィルター設定
  String _selectedNovelSearchTarget =
      'partial_match_for_tags'; // partial_match_for_tags, exact_match_for_tags, text
  String _selectedNovelAgeLimit = 'all'; // all, safe, r18
  int _selectedNovelBookmarkFilter = 0; // 0, 100, 300, 500, 1000, 5000
  String _selectedNovelTextLengthLimit = 'all'; // all, short, medium, long
  // カスタム文字数フィルター用
  TextEditingController? _minTextLengthController;
  TextEditingController? _maxTextLengthController;

  // ボトムナビゲーション用 (0: イラスト, 1: 小説)
  int _currentIndex = 0;

  // イラストタブ内のサブ表示モード (0: おすすめ, 1: 検索結果, 2: ランキング)
  int _illustSubMode = 0;
  // 小説タブ内のサブ表示モード (0: おすすめ, 1: 検索結果, 2: ランキング)
  int _novelSubMode = 0;

  // データリスト
  List<Illust> _illusts = [];
  List<Novel> _novels = [];

  // 百科事典データ
  SearchItem? _searchItem;

  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;

  // ページング用
  int? _nextOffset;

  // スクロールコントローラー（無限スクロール用）
  late final ScrollController _scrollController;

  // ランキング用のアクティブモード設定
  String _selectedIllustRankMode = 'day';
  String _selectedNovelRankMode = 'day';

  final List<Map<String, String>> _illustRankModes = [
    {'value': 'day', 'label': 'デイリー'},
    {'value': 'week', 'label': 'ウィークリー'},
    {'value': 'month', 'label': 'マンスリー'},
    {'value': 'male', 'label': '男性人気'},
    {'value': 'female', 'label': '女性人気'},
  ];

  final List<Map<String, String>> _novelRankModes = [
    {'value': 'day', 'label': 'デイリー'},
    {'value': 'week', 'label': 'ウィークリー'},
  ];

  // 検索履歴リスト
  List<String> _searchHistory = [];
  bool _showHistoryList = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _scrollController = ScrollController();
    _minTextLengthController = TextEditingController();
    _maxTextLengthController = TextEditingController();

    _scrollController.addListener(_onScroll);
    _searchFocusNode.addListener(() {
      setState(() {
        _showHistoryList =
            _searchFocusNode.hasFocus && _searchHistory.isNotEmpty;
      });
    });

    _loadSearchHistory();
    _checkLoginAndInitialize();
  }

  /// 起動時のログインチェックと初期化処理
  Future<void> _checkLoginAndInitialize() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString('PIXIV_REFRESH_TOKEN');

    if (refreshToken != null && refreshToken.isNotEmpty) {
      // トークンがある場合: バックグラウンドでAPIサービスを初期化してデータ取得
      setState(() {
        _isLoggedIn = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fetchData();
        _initializeDriveSync();
      });
    } else {
      // トークンがない場合（初回起動）: データ取得をスキップし、1フレーム目描画後にログインダイアログを表示
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showPKCELoginDialog();
      });
    }
  }

  /// PKCE認証フローでPixivログインダイアログを表示（アプリ内蔵WebViewによる全自動ログイン）
  ///
  /// 外部ブラウザへの遷移・URLの手動コピペを廃止し、アプリ内の [WebViewWidget] に
  /// Pixivログイン画面を直接描画する。ログイン完了時のリダイレクト先URLを
  /// [NavigationDelegate] で自動横取りし、認可コード(code)を全自動抽出して
  /// トークン交換API（[_exchangeCodeForToken]）を呼び出す。
  Future<void> _showPKCELoginDialog() async {
    // PKCEコードベリファイアとチャレンジを生成
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);

    // 認証開始URL（正しいエントリURL）を構築
    // 中継用の裏URL（.../auth/pixiv/start）ではなく、ログイン画面へ直接遷移する
    // エントリポイント（/web/v1/login）を指定する。
    // Uri が自動でパラメータを URL エンコードするため、code_challenge はそのまま埋め込む。
    final authUrl = Uri.https('app-api.pixiv.net', '/web/v1/login', {
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'client': 'pixiv-android',
    });

    // バックグラウンドでアプリがリセットされても code_verifier が
    // 消失しないよう、ダイアログ表示「直前」に SharedPreferences へ退避
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('temp_login_code_verifier', codeVerifier);

    if (!mounted) return;

    // WebViewコントローラーを生成し、Pixivログイン画面を読み込む
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          // 全ての遷移を監視し、コールバックURLを自動横取りする
          onNavigationRequest: (NavigationRequest request) async {
            final url = request.url;

            // リダイレクト先がコールバックURLで始まる場合、code を自動抽出
            if (url.startsWith(
              'https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback',
            )) {
              String? code;

              // 1. クエリパラメータから code を抽出
              try {
                final uri = Uri.parse(url);
                code = uri.queryParameters['code'];
                // フラグメント内に code が含まれる場合も考慮
                if (code == null && uri.fragment.contains('code=')) {
                  code = Uri.parse(
                    'pixiv://x?${uri.fragment}',
                  ).queryParameters['code'];
                }
              } catch (e) {
                // 2. パースエラー時のフォールバック（正規表現）
                final regExp = RegExp(r'code=([^&]+)');
                final match = regExp.firstMatch(url);
                if (match != null) {
                  code = match.group(1);
                }
              }

              print('[WebView Hook] コールバックURLを検知: $url');
              print('[WebView Hook] 抽出した code: $code');

              if (code != null && code.isNotEmpty) {
                // SharedPreferences から code_verifier を復元して利用
                final restoredVerifier = prefs.getString(
                  'temp_login_code_verifier',
                );
                if (restoredVerifier != null && restoredVerifier.isNotEmpty) {
                  // ダイアログをプログラムで自動的に閉じる
                  if (mounted) {
                    Navigator.of(context).pop();
                  }
                  // 抽出した code と code_verifier でトークン交換APIを自動実行
                  _exchangeCodeForToken(code, restoredVerifier);
                } else {
                  // code_verifier が消失している場合はユーザーへ通知
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('認証セッションが切れています。再度ログインし直してください。'),
                      ),
                    );
                  }
                }
              }
              // コールバックURL自体の読み込みは防止（エラー画面を出さない）
              return NavigationDecision.prevent;
            }

            // それ以外の遷移は許可（ログイン画面内の通常遷移）
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(authUrl);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Pixiv にログイン'),
          contentPadding: EdgeInsets.zero,
          content: SizedBox(
            width: double.maxFinite,
            height: 500,
            child: WebViewWidget(controller: controller),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('キャンセル'),
            ),
          ],
        );
      },
    );
  }

  /// PKCEコードベリファイアを生成（RFC7636 準拠: 32バイト乱数 -> Base64URL・パディング無）
  String _generateCodeVerifier() {
    final random = Random.secure();
    final values = List<int>.generate(32, (i) => random.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }

  /// PKCEコードチャレンジを生成（SHA-256 -> Base64URL・パディング無）
  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  Future<void> _exchangeCodeForToken(String code, String codeVerifier) async {
    try {
      print("========== [OAuth] トークン交換フェーズ開始 ==========");

      // 1. ミリ秒を完全に排除した ISO 8601 UTC 時刻を自律生成
      final now = DateTime.now().toUtc();
      final clientTime =
          "${now.year.toString().padLeft(4, '0')}-"
          "${now.month.toString().padLeft(2, '0')}-"
          "${now.day.toString().padLeft(2, '0')}T"
          "${now.hour.toString().padLeft(2, '0')}:"
          "${now.minute.toString().padLeft(2, '0')}:"
          "${now.second.toString().padLeft(2, '0')}+00:00";

      // 2. 署名の計算
      final salt = "2821213q311543184o13o121o131o1o3";
      final input = clientTime + salt;
      final clientHash = md5.convert(utf8.encode(input)).toString();

      print("[OAuth DEBUG] Client Time: $clientTime");
      print("[OAuth DEBUG] Client Hash: $clientHash");
      print("[OAuth DEBUG] Code Verifier: $codeVerifier");

      final url = Uri.parse("https://oauth.secure.pixiv.net/auth/token");
      final headers = {
        "User-Agent": "PixivAndroidApp/5.0.234 (Android 11.0; Pixel 5)",
        "App-OS": "android",
        "App-OS-Version": "11.0",
        "App-Version": "5.0.234",
        "X-Client-Time": clientTime,
        "X-Client-Hash": clientHash,
        "Accept-Language": "ja_JP",
        "Content-Type": "application/x-www-form-urlencoded",
      };

      final data = {
        "client_id": "MOBrBDS8blbauoSck0ZfDbtuzpyT",
        "client_secret": "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj",
        "grant_type": "authorization_code",
        "code": code,
        "code_verifier": codeVerifier,
        "redirect_uri":
            "https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback",
        "include_policy": "true",
      };

      // === 送信リクエストの徹底可視化（デバッグ用） ===
      print("🌐 [OAuth REQUEST] URL: ${url.toString()}");
      print("🌐 [OAuth REQUEST] Headers: $headers");
      print("🌐 [OAuth REQUEST] Body: $data");

      final response = await http.post(url, headers: headers, body: data);

      // === サーバーからのレスポンス可視化 ===
      print("📥 [OAuth RESPONSE] Status Code: ${response.statusCode}");
      print("📥 [OAuth RESPONSE] Body: ${response.body}");

      if (response.statusCode == 200) {
        final resData = jsonDecode(response.body);
        final responsePayload = resData['response'];
        if (responsePayload != null) {
          final newRefreshToken = responsePayload['refresh_token'];
          final userJson = responsePayload['user'];
          final userName = userJson != null ? userJson['name'] : 'Unknown';

          if (newRefreshToken != null) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('PIXIV_REFRESH_TOKEN', newRefreshToken);

            // 認証情報を登録しログイン
            _pixivApiService.setRefreshToken(newRefreshToken);
            await _pixivApiService.login();

            // ログイン成功により一時退避キーを削除
            final loginPrefs = await SharedPreferences.getInstance();
            await loginPrefs.remove('temp_login_code_verifier');

            if (!mounted) return;
            setState(() {
              _isLoggedIn = true;
            });

            _fetchData();
            _initializeDriveSync();

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('ログインに成功しました！ ユーザー: $userName')),
              );
            }
            print("[OAuth SUCCESS] トークン交換完了。ログイン成功しました！");
            return;
          }
        }
        throw Exception("レスポンス内に refresh_token が見つかりませんでした。");
      } else {
        print("❌❌❌ [OAuth ERROR] Pixivトークン交換サーバーがエラーを返却しました ❌❌❌");
        print("ステータスコード: ${response.statusCode}");
        print("レスポンス内容: ${response.body}");
        throw Exception(
          "Pixiv Token API HTTP ${response.statusCode}: ${response.body}",
        );
      }
    } catch (e, stack) {
      print("❌ [OAuth CRITICAL] 例外が発生しました: $e");
      print(stack); // スタックトレースをコンソールに出力
      if (mounted) {
        // サーバーから返されたエラー(JSON等)を画面にわかりやすく表示し、デバッグ可能にする
        final message = e.toString().length > 300
            ? '${e.toString().substring(0, 300)}...（詳細はコンソールログを確認）'
            : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ログインに失敗しました:\n$message'),
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('PIXIV_ACCESS_TOKEN');
    await prefs.remove('PIXIV_REFRESH_TOKEN');

    if (mounted) {
      setState(() {
        _isLoggedIn = false;
        _illusts = [];
        _novels = [];
        _errorMessage = 'ログアウトしました。再度ログインしてください。';
      });
      _showPKCELoginDialog();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    _minTextLengthController?.dispose();
    _maxTextLengthController?.dispose();
    _syncTimer?.cancel();
    super.dispose();
  }

  // --- 検索履歴ローカル保存処理 (shared_preferences) ---
  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _searchHistory = prefs.getStringList('search_history') ?? [];
      });
    } catch (e) {
      debugPrint('Error loading search history: $e');
    }
  }

  Future<void> _saveSearchHistory(String word) async {
    if (word.trim().isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final list = List<String>.from(_searchHistory);
      list.remove(word); // 重複を削除
      list.insert(0, word); // 先頭に挿入
      if (list.length > 15) {
        list.removeLast(); // 最大15件
      }
      setState(() {
        _searchHistory = list;
        _showHistoryList =
            _searchFocusNode.hasFocus && _searchHistory.isNotEmpty;
      });
      await prefs.setStringList('search_history', list);
    } catch (e) {
      debugPrint('Error saving search history: $e');
    }
  }

  Future<void> _deleteSearchHistoryItem(String word) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final list = List<String>.from(_searchHistory);
      list.remove(word);
      setState(() {
        _searchHistory = list;
        _showHistoryList =
            _searchFocusNode.hasFocus && _searchHistory.isNotEmpty;
      });
      await prefs.setStringList('search_history', list);
    } catch (e) {
      debugPrint('Error deleting search history item: $e');
    }
  }

  Future<void> _clearAllSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _searchHistory = [];
        _showHistoryList = false;
      });
      await prefs.remove('search_history');
    } catch (e) {
      debugPrint('Error clearing search history: $e');
    }
  }

  // --- 無限スクロール検知 ---
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;

    // 最下部手前200pxに達したら次ページ読み込み
    if (maxScroll - currentScroll <= 200) {
      if (!_isLoading && !_isLoadingMore && _nextOffset != null) {
        _fetchNextPage();
      }
    }
  }

  // データ新規取得
  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _nextOffset = null;
      _searchItem = null;
      _illusts = [];
      _novels = [];
    });

    final activeSubMode = _currentIndex == 0 ? _illustSubMode : _novelSubMode;

    try {
      if (_currentIndex == 0) {
        // --- イラストデータ取得 (PixivApiService 直接呼び出し) ---
        final result = await _fetchIllusts(activeSubMode, 0);
        if (!mounted) return;
        setState(() {
          _illusts = result.items;
          _nextOffset = result.nextOffset; // API の next_url から安全に抽出
          _searchItem = result.searchItem; // 検索時のみセット
          _isLoading = false;
        });
      } else {
        // --- 小説データ取得 (PixivApiService 直接呼び出し) ---
        final result = await _fetchNovels(activeSubMode, 0);
        if (!mounted) return;
        setState(() {
          _novels = result.items;
          _nextOffset = result.nextOffset;
          _searchItem = result.searchItem;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'データの取得に失敗しました。\n詳細: $e';
        _isLoading = false;
      });
    }
  }

  // 次ページ追加読み込み (無限スクロール)
  Future<void> _fetchNextPage() async {
    if (_nextOffset == null) return;

    setState(() {
      _isLoadingMore = true;
    });

    final activeSubMode = _currentIndex == 0 ? _illustSubMode : _novelSubMode;

    try {
      if (_currentIndex == 0) {
        // --- イラスト次ページ ---
        final result = await _fetchIllusts(activeSubMode, _nextOffset!);
        if (!mounted) return;
        setState(() {
          _illusts.addAll(result.items);
          _nextOffset = result.nextOffset; // さらに次があれば更新、なければ null
          _isLoadingMore = false;
        });
      } else {
        // --- 小説次ページ ---
        final result = await _fetchNovels(activeSubMode, _nextOffset!);
        if (!mounted) return;
        setState(() {
          _novels.addAll(result.items);
          _nextOffset = result.nextOffset;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching next page: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  // PixivApiService を呼び出してイラスト一覧を取得 (サーバーレス)
  Future<FetchResult<Illust>> _fetchIllusts(int subMode, int offset) async {
    if (subMode == 0) {
      return _pixivApiService.getRecommend(offset: offset);
    } else if (subMode == 1) {
      return _pixivApiService.searchIllust(
        _currentSearchWord,
        _selectedSearchTarget,
        _selectedSort,
        offset,
        _selectedAgeLimit,
        bookmarkFilter: _selectedBookmarkFilter,
        workType: _selectedWorkType,
      );
    } else {
      return _pixivApiService.getRanking(
        _selectedIllustRankMode,
        offset: offset,
      );
    }
  }

  // PixivApiService を呼び出して小説一覧を取得 (サーバーレス)
  Future<FetchResult<Novel>> _fetchNovels(int subMode, int offset) async {
    if (subMode == 0) {
      return _pixivApiService.getNovelRecommend(offset: offset);
    } else if (subMode == 1) {
      int? minLen;
      int? maxLen;
      if (_selectedNovelTextLengthLimit == 'short') {
        maxLen = 5000;
      } else if (_selectedNovelTextLengthLimit == 'medium') {
        minLen = 5000;
        maxLen = 20000;
      } else if (_selectedNovelTextLengthLimit == 'long') {
        minLen = 20000;
      } else if (_selectedNovelTextLengthLimit == 'custom') {
        minLen = int.tryParse(_minTextLengthController?.text ?? '');
        maxLen = int.tryParse(_maxTextLengthController?.text ?? '');
      }
      return _pixivApiService.searchNovel(
        _currentSearchWord,
        _selectedNovelSearchTarget,
        _selectedSort,
        offset,
        _selectedNovelAgeLimit,
        minLen,
        maxLen,
        bookmarkFilter: _selectedNovelBookmarkFilter,
      );
    } else {
      return _pixivApiService.getNovelRanking(
        _selectedNovelRankMode,
        offset: offset,
      );
    }
  }

  // 検索実行
  void _onSearchSubmit(String query) {
    if (query.trim().isEmpty) return;
    _searchFocusNode.unfocus();
    _saveSearchHistory(query.trim());
    setState(() {
      _currentSearchWord = query.trim();
      if (_currentIndex == 0) {
        _illustSubMode = 1; // イラスト検索結果
      } else {
        _novelSubMode = 1; // 小説検索結果
      }
    });
    _fetchData();
  }

  // 検索履歴タップ
  void _onHistoryItemTap(String query) {
    _searchController.text = query;
    _onSearchSubmit(query);
  }

  // 検索リセット
  void _resetSearch() {
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _currentSearchWord = '';
      if (_currentIndex == 0) {
        _illustSubMode = 0; // おすすめに戻る
      } else {
        _novelSubMode = 0; // おすすめに戻る
      }
    });
    _fetchData();
  }

  // 検索タグ連動
  void _onTagSelected(String tag) {
    _searchController.text = tag;
    _saveSearchHistory(tag);
    setState(() {
      _currentSearchWord = tag;
      if (_currentIndex == 0) {
        _illustSubMode = 1;
      } else {
        _novelSubMode = 1;
      }
    });
    _fetchData();
  }

  // タブ切り替え（検索条件を引き継ぐ）
  void _changeTab(int index) {
    if (_currentIndex == index) return;
    setState(() {
      _currentIndex = index;

      // 検索ワードが空でなければ、切り替え先でも自動で検索モードにする
      if (_currentSearchWord.isNotEmpty) {
        if (_currentIndex == 0) {
          _illustSubMode = 1;
        } else {
          _novelSubMode = 1;
        }
      } else {
        if (_currentIndex == 0) {
          _illustSubMode = 0;
        } else {
          _novelSubMode = 0;
        }
      }
    });
    _fetchData();
  }

  // 小説専用検索フィルターボトムシートの表示
  void _showNovelFilterBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161616),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        String target = _selectedNovelSearchTarget;
        String sortVal = _selectedSort; // ソート順は共通
        String ageLimitVal = _selectedNovelAgeLimit;
        int bookmarkFilterVal = _selectedNovelBookmarkFilter;
        String textLengthLimitVal = _selectedNovelTextLengthLimit;
        // カスタム文字数フィルター用コントローラー
        final minController = TextEditingController(
          text: _minTextLengthController?.text ?? '',
        );
        final maxController = TextEditingController(
          text: _maxTextLengthController?.text ?? '',
        );

        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.85,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.grey[800],
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          const Icon(
                            Icons.menu_book,
                            color: Colors.tealAccent,
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '小説専用検索フィルター',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              setModalState(() {
                                target = 'partial_match_for_tags';
                                sortVal = 'date_desc';
                                ageLimitVal = 'all';
                                bookmarkFilterVal = 0;
                                textLengthLimitVal = 'all';
                                minController.clear();
                                maxController.clear();
                              });
                            },
                            child: const Text(
                              'リセット',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                      const Divider(color: Colors.grey),
                      const SizedBox(height: 12),

                      // 1. 検索対象
                      _buildFilterSectionTitle('🔍 検索対象'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: 'タグの部分一致',
                            selected: target == 'partial_match_for_tags',
                            onSelected: () => setModalState(
                              () => target = 'partial_match_for_tags',
                            ),
                          ),
                          _buildChoiceChip(
                            label: 'タグの完全一致',
                            selected: target == 'exact_match_for_tags',
                            onSelected: () => setModalState(
                              () => target = 'exact_match_for_tags',
                            ),
                          ),
                          _buildChoiceChip(
                            label: '本文で検索',
                            selected: target == 'text',
                            onSelected: () =>
                                setModalState(() => target = 'text'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 2. ソート順
                      _buildFilterSectionTitle('↕️ ソート順'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: '新しい順 (降順)',
                            selected: sortVal == 'date_desc',
                            onSelected: () =>
                                setModalState(() => sortVal = 'date_desc'),
                          ),
                          _buildChoiceChip(
                            label: '古い順 (昇順)',
                            selected: sortVal == 'date_asc',
                            onSelected: () =>
                                setModalState(() => sortVal = 'date_asc'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 3. 年齢制限
                      _buildFilterSectionTitle('🔞 年齢制限 (アプリ側でフィルタリング)'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: '制限なし',
                            selected: ageLimitVal == 'all',
                            onSelected: () =>
                                setModalState(() => ageLimitVal = 'all'),
                          ),
                          _buildChoiceChip(
                            label: '全年齢のみ (Safe)',
                            selected: ageLimitVal == 'safe',
                            onSelected: () =>
                                setModalState(() => ageLimitVal = 'safe'),
                          ),
                          _buildChoiceChip(
                            label: 'R-18のみ',
                            selected: ageLimitVal == 'r18',
                            onSelected: () =>
                                setModalState(() => ageLimitVal = 'r18'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 4. 人気フィルター (users入り)
                      _buildFilterSectionTitle('⭐ 人気フィルター (小説用 users入り裏ワザ)'),
                      const SizedBox(height: 4),
                      const Text(
                        '検索ワードの末尾に「○○users入り」を自動付加することで、人気作品に絞り込む裏ワザです。',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: '制限なし',
                            selected: bookmarkFilterVal == 0,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 0),
                          ),
                          _buildChoiceChip(
                            label: '100+ users',
                            selected: bookmarkFilterVal == 100,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 100),
                          ),
                          _buildChoiceChip(
                            label: '300+ users',
                            selected: bookmarkFilterVal == 300,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 300),
                          ),
                          _buildChoiceChip(
                            label: '500+ users',
                            selected: bookmarkFilterVal == 500,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 500),
                          ),
                          _buildChoiceChip(
                            label: '1000+ users',
                            selected: bookmarkFilterVal == 1000,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 1000),
                          ),
                          _buildChoiceChip(
                            label: '5000+ users',
                            selected: bookmarkFilterVal == 5000,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 5000),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 5. 本文の長さ
                      _buildFilterSectionTitle('✍️ 本文の長さ (サーバー自動巡回フィルター)'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: 'すべて (制限なし)',
                            selected: textLengthLimitVal == 'all',
                            onSelected: () =>
                                setModalState(() => textLengthLimitVal = 'all'),
                          ),
                          _buildChoiceChip(
                            label: '短編 (〜5,000文字)',
                            selected: textLengthLimitVal == 'short',
                            onSelected: () => setModalState(
                              () => textLengthLimitVal = 'short',
                            ),
                          ),
                          _buildChoiceChip(
                            label: '中編 (5,000〜20,000文字)',
                            selected: textLengthLimitVal == 'medium',
                            onSelected: () => setModalState(
                              () => textLengthLimitVal = 'medium',
                            ),
                          ),
                          _buildChoiceChip(
                            label: '長編 (20,000文字以上)',
                            selected: textLengthLimitVal == 'long',
                            onSelected: () => setModalState(
                              () => textLengthLimitVal = 'long',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // カスタム文字数範囲指定
                      _buildFilterSectionTitle('🔢 カスタム文字数範囲指定'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _minTextLengthController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: '最小文字数',
                                labelStyle: const TextStyle(color: Colors.grey),
                                filled: true,
                                fillColor: Colors.grey[900],
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _maxTextLengthController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: '最大文字数',
                                labelStyle: const TextStyle(color: Colors.grey),
                                filled: true,
                                fillColor: Colors.grey[900],
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),

                      // 適用ボタン
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: () {
                            // カスタム文字数範囲をコントローラーに保存
                            if (minController.text.isNotEmpty ||
                                maxController.text.isNotEmpty) {
                              _minTextLengthController!.text =
                                  minController.text;
                              _maxTextLengthController!.text =
                                  maxController.text;
                              _selectedNovelTextLengthLimit = 'custom';
                            }
                            setState(() {
                              _selectedNovelSearchTarget = target;
                              _selectedSort = sortVal;
                              _selectedNovelAgeLimit = ageLimitVal;
                              _selectedNovelBookmarkFilter = bookmarkFilterVal;
                              _selectedNovelTextLengthLimit =
                                  textLengthLimitVal;
                            });
                            Navigator.pop(context);
                            _fetchData();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            foregroundColor: Colors.white,
                            elevation: 5,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            '小説フィルターを適用',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // フィルターボトムシートの表示
  void _showFilterBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        String target = _selectedSearchTarget;
        String sortVal = _selectedSort;
        String workTypeVal = _selectedWorkType;
        String ageLimitVal = _selectedAgeLimit;
        String durationVal = _selectedDuration;
        int bookmarkFilterVal = _selectedBookmarkFilter;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.85,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.grey[700],
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          const Icon(
                            Icons.tune,
                            color: Colors.pinkAccent,
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '高度な検索フィルター',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              setModalState(() {
                                target = 'partial_match_for_tags';
                                sortVal = 'date_desc';
                                workTypeVal = 'all';
                                ageLimitVal = 'all';
                                durationVal = 'all';
                                bookmarkFilterVal = 0;
                              });
                            },
                            child: const Text(
                              'リセット',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ],
                      ),
                      const Divider(color: Colors.grey),
                      const SizedBox(height: 12),

                      // 1. 検索対象
                      _buildFilterSectionTitle('🔍 検索対象'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: 'タグの部分一致',
                            selected: target == 'partial_match_for_tags',
                            onSelected: () => setModalState(
                              () => target = 'partial_match_for_tags',
                            ),
                          ),
                          _buildChoiceChip(
                            label: 'タグの完全一致',
                            selected: target == 'exact_match_for_tags',
                            onSelected: () => setModalState(
                              () => target = 'exact_match_for_tags',
                            ),
                          ),
                          _buildChoiceChip(
                            label: 'タイトル・本文',
                            selected: target == 'title_and_caption',
                            onSelected: () => setModalState(
                              () => target = 'title_and_caption',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 2. ソート順
                      _buildFilterSectionTitle('↕️ ソート順'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: '新しい順 (降順)',
                            selected: sortVal == 'date_desc',
                            onSelected: () =>
                                setModalState(() => sortVal = 'date_desc'),
                          ),
                          _buildChoiceChip(
                            label: '古い順 (昇順)',
                            selected: sortVal == 'date_asc',
                            onSelected: () =>
                                setModalState(() => sortVal = 'date_asc'),
                          ),
                          _buildChoiceChip(
                            label: '人気順 (要プレミアム) ⚠️',
                            selected: sortVal == 'popular_desc',
                            onSelected: () {
                              setModalState(() => sortVal = 'popular_desc');
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    '人気順はアカウントが非プレミアムの場合、サーバーエラーになる可能性があります。',
                                  ),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 3. 作品タイプ
                      _buildFilterSectionTitle('🎨 作品タイプ'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: 'すべて',
                            selected: workTypeVal == 'all',
                            onSelected: () =>
                                setModalState(() => workTypeVal = 'all'),
                          ),
                          _buildChoiceChip(
                            label: 'イラスト',
                            selected: workTypeVal == 'illust',
                            onSelected: () =>
                                setModalState(() => workTypeVal = 'illust'),
                          ),
                          _buildChoiceChip(
                            label: 'マンガ',
                            selected: workTypeVal == 'manga',
                            onSelected: () =>
                                setModalState(() => workTypeVal = 'manga'),
                          ),
                          _buildChoiceChip(
                            label: 'うごイラ',
                            selected: workTypeVal == 'ugoira',
                            onSelected: () =>
                                setModalState(() => workTypeVal = 'ugoira'),
                          ),
                          _buildChoiceChip(
                            label: '小説',
                            selected: workTypeVal == 'novel',
                            onSelected: () =>
                                setModalState(() => workTypeVal = 'novel'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 4. 年齢制限
                      _buildFilterSectionTitle('🔞 年齢制限'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: '制限なし',
                            selected: ageLimitVal == 'all',
                            onSelected: () =>
                                setModalState(() => ageLimitVal = 'all'),
                          ),
                          _buildChoiceChip(
                            label: '全年齢 (Safe)',
                            selected: ageLimitVal == 'safe',
                            onSelected: () =>
                                setModalState(() => ageLimitVal = 'safe'),
                          ),
                          _buildChoiceChip(
                            label: 'R-18 (成人向け)',
                            selected: ageLimitVal == 'r18',
                            onSelected: () =>
                                setModalState(() => ageLimitVal = 'r18'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 5. 投稿期間
                      _buildFilterSectionTitle('📅 投稿期間'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: '指定なし',
                            selected: durationVal == 'all',
                            onSelected: () =>
                                setModalState(() => durationVal = 'all'),
                          ),
                          _buildChoiceChip(
                            label: '1日以内',
                            selected: durationVal == 'within_last_day',
                            onSelected: () => setModalState(
                              () => durationVal = 'within_last_day',
                            ),
                          ),
                          _buildChoiceChip(
                            label: '1週間以内',
                            selected: durationVal == 'within_last_week',
                            onSelected: () => setModalState(
                              () => durationVal = 'within_last_week',
                            ),
                          ),
                          _buildChoiceChip(
                            label: '1ヶ月以内',
                            selected: durationVal == 'within_last_month',
                            onSelected: () => setModalState(
                              () => durationVal = 'within_last_month',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // 6. 人気フィルター (users入り)
                      _buildFilterSectionTitle('⭐ 人気フィルター (非会員向け人気順裏ワザ)'),
                      const SizedBox(height: 4),
                      const Text(
                        '検索ワードの末尾に「○○users入り」を自動付加することで、非プレミアムでもブクマ数一定以上の人気作に絞り込む裏ワザです。',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildChoiceChip(
                            label: '制限なし',
                            selected: bookmarkFilterVal == 0,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 0),
                          ),
                          _buildChoiceChip(
                            label: '100+ users',
                            selected: bookmarkFilterVal == 100,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 100),
                          ),
                          _buildChoiceChip(
                            label: '500+ users',
                            selected: bookmarkFilterVal == 500,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 500),
                          ),
                          _buildChoiceChip(
                            label: '1000+ users',
                            selected: bookmarkFilterVal == 1000,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 1000),
                          ),
                          _buildChoiceChip(
                            label: '5000+ users',
                            selected: bookmarkFilterVal == 5000,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 5000),
                          ),
                          _buildChoiceChip(
                            label: '10000+ users',
                            selected: bookmarkFilterVal == 10000,
                            onSelected: () =>
                                setModalState(() => bookmarkFilterVal = 10000),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),

                      // 適用ボタン
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _selectedSearchTarget = target;
                              _selectedSort = sortVal;
                              _selectedWorkType = workTypeVal;
                              _selectedAgeLimit = ageLimitVal;
                              _selectedDuration = durationVal;
                              _selectedBookmarkFilter = bookmarkFilterVal;
                            });
                            Navigator.pop(context);
                            _fetchData();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.pinkAccent,
                            foregroundColor: Colors.white,
                            elevation: 5,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            '検索フィルターを適用',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // ボトムシートセクションタイトルビルダー
  Widget _buildFilterSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: 13,
      ),
    );
  }

  // ChoiceChipのカスタムスタイルビルダー
  Widget _buildChoiceChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : Colors.grey[400],
          fontSize: 12,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      selected: selected,
      selectedColor: Colors.pinkAccent.withValues(alpha: 0.8),
      backgroundColor: const Color(0xFF2E2E2E),
      elevation: selected ? 2 : 0,
      pressElevation: 4,
      onSelected: (_) => onSelected(),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? Colors.pinkAccent : Colors.transparent,
          width: 1,
        ),
      ),
    );
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

    final activeSubMode = _currentIndex == 0 ? _illustSubMode : _novelSubMode;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              _currentIndex == 0 ? Icons.palette : Icons.menu_book,
              color: Colors.pinkAccent,
            ),
            const SizedBox(width: 8),
            Text(
              _currentIndex == 0 ? 'Pixiv Illusts' : 'Pixiv Novels',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _fetchData,
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
              leading: const Icon(Icons.image, color: Colors.pinkAccent),
              title: const Text('イラスト (Illusts)'),
              onTap: () {
                Navigator.pop(context);
                _changeTab(0);
              },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book, color: Colors.pinkAccent),
              title: const Text('小説 (Novels)'),
              onTap: () {
                Navigator.pop(context);
                _changeTab(1); // スムーズな切り替え連動
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
            // ログイン/ログアウトボタン
            ListTile(
              leading: Icon(
                _isLoggedIn ? Icons.logout : Icons.login,
                color: Colors.pinkAccent,
              ),
              title: Text(_isLoggedIn ? 'ログアウト' : 'アカウント連携（ログイン）'),
              onTap: () {
                Navigator.pop(context);
                if (_isLoggedIn) {
                  _logout();
                } else {
                  _showPKCELoginDialog();
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
            _buildGoogleDriveSyncSection(),
          ],
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 検索バー (フィルターオプションボタン付き)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        decoration: InputDecoration(
                          hintText: _currentIndex == 0
                              ? 'イラスト、タグ、キーワードを検索...'
                              : '小説、タグ、キーワードを検索...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: _resetSearch,
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
                        onSubmitted: _onSearchSubmit,
                        onChanged: (val) {
                          setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        Icons.tune,
                        color: _currentIndex == 0
                            ? Colors.pinkAccent
                            : Colors.tealAccent,
                      ),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        if (_currentIndex == 0) {
                          _showFilterBottomSheet();
                        } else {
                          _showNovelFilterBottomSheet();
                        }
                      },
                      tooltip: _currentIndex == 0 ? '検索フィルター' : '小説検索フィルター',
                    ),
                  ],
                ),
              ),

              // 3. サブモードセレクター (おすすめ / ランキング)。※検索結果時はサブタブは表示しません。
              if (activeSubMode != 1) _buildSubModeSelector(),

              // 4. ランキング時のモード切替
              _buildRankingFilterBar(),

              // 5. 百科事典カード (検索モード時のみ)
              if (activeSubMode == 1 && _searchItem != null)
                _buildEncyclopediaCard(),

              // 読書中（しおり）の小説セクション (小説タブかつ非検索時に表示)
              if (_currentIndex == 1 && activeSubMode != 1)
                _buildRecentBookmarksSection(),

              // 6. メインデータコンテンツ
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: Colors.pinkAccent),
                            SizedBox(height: 16),
                            Text(
                              'Pixivからデータを取得中...',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : _errorMessage != null
                    ? _buildErrorWidget()
                    : _currentIndex == 0
                    ? _buildIllustGrid(crossAxisCount)
                    : _buildNovelList(),
              ),
            ],
          ),

          // 🔍 検索履歴候補オーバーレイリスト
          if (_showHistoryList) _buildSearchHistoryOverlay(),

          // 🔄 サブスクリプション同期プログレス HUD
          if (_isSyncing && _syncProgress != null) _buildSyncProgressHUD(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _changeTab,
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
        ],
      ),
    );
  }

  // 百科事典カード
  Widget _buildEncyclopediaCard() {
    if (_searchItem == null) return const SizedBox.shrink();
    final item = _searchItem!;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
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
                    color: Colors.black,
                    child: item.iconUrl != null && item.iconUrl!.isNotEmpty
                        ? PixivImage(
                            url: item.iconUrl ?? '',
                            isThumbnail: true,
                            fit: BoxFit.cover,
                          )
                        : const Icon(
                            Icons.bookmark_border,
                            color: Colors.pinkAccent,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '#${item.name}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.pinkAccent,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '作品数: ${item.wordCount}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (item.summary.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                item.summary,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white70,
                  height: 1.4,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (item.dicUrl.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: () async {
                    final uri = Uri.parse(item.dicUrl);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    child: Text(
                      'ピクシブ百科事典で見る ↗',
                      style: TextStyle(
                        color: Colors.blueAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 検索履歴オーバーレイ
  Widget _buildSearchHistoryOverlay() {
    return Positioned(
      top: 110, // 設定・検索欄の下
      left: 8,
      right: 8,
      child: Card(
        color: const Color(0xFF1E1E1E),
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12.0,
                  vertical: 8.0,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '最近の検索履歴',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextButton(
                      onPressed: _clearAllSearchHistory,
                      child: const Text(
                        'すべてクリア',
                        style: TextStyle(
                          color: Colors.pinkAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.grey),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _searchHistory.length,
                  itemBuilder: (context, idx) {
                    final word = _searchHistory[idx];
                    return ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.history,
                        size: 16,
                        color: Colors.grey,
                      ),
                      title: Text(
                        word,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.close,
                          size: 14,
                          color: Colors.grey,
                        ),
                        onPressed: () => _deleteSearchHistoryItem(word),
                      ),
                      onTap: () => _onHistoryItemTap(word),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // おすすめ/ランキングのサブタブ切り替え
  Widget _buildSubModeSelector() {
    final activeSubMode = _currentIndex == 0 ? _illustSubMode : _novelSubMode;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      child: Row(
        children: [
          _buildSubTabButton(
            label: 'おすすめ',
            isActive: activeSubMode == 0,
            onTap: () {
              setState(() {
                _currentSearchWord = '';
                _searchController.clear();
                if (_currentIndex == 0) {
                  _illustSubMode = 0;
                } else {
                  _novelSubMode = 0;
                }
              });
              _fetchData();
            },
          ),
          const SizedBox(width: 8),
          _buildSubTabButton(
            label: 'ランキング',
            isActive: activeSubMode == 2,
            onTap: () {
              setState(() {
                _currentSearchWord = '';
                _searchController.clear();
                if (_currentIndex == 0) {
                  _illustSubMode = 2;
                } else {
                  _novelSubMode = 2;
                }
              });
              _fetchData();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSubTabButton({
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.pink.withValues(alpha: 0.15)
                : Colors.transparent,
            border: Border.all(
              color: isActive
                  ? Colors.pinkAccent
                  : Colors.grey.withValues(alpha: 0.3),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: isActive ? Colors.pinkAccent : Colors.grey,
            ),
          ),
        ),
      ),
    );
  }

  // ランキング時のフィルター
  Widget _buildRankingFilterBar() {
    final activeSubMode = _currentIndex == 0 ? _illustSubMode : _novelSubMode;
    if (activeSubMode != 2) return const SizedBox.shrink();

    final modes = _currentIndex == 0 ? _illustRankModes : _novelRankModes;
    final selected = _currentIndex == 0
        ? _selectedIllustRankMode
        : _selectedNovelRankMode;

    return Container(
      height: 42,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: modes.length,
        itemBuilder: (context, idx) {
          final m = modes[idx];
          final isSel = m['value'] == selected;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
            child: ChoiceChip(
              label: Text(m['label']!, style: const TextStyle(fontSize: 11)),
              selected: isSel,
              selectedColor: Colors.pink.withValues(alpha: 0.3),
              checkmarkColor: Colors.pinkAccent,
              onSelected: (selectedBool) {
                if (selectedBool) {
                  setState(() {
                    if (_currentIndex == 0) {
                      _selectedIllustRankMode = m['value']!;
                    } else {
                      _selectedNovelRankMode = m['value']!;
                    }
                  });
                  _fetchData();
                }
              },
            ),
          );
        },
      ),
    );
  }

  // エラー表示ウィジェット
  Widget _buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 64, color: Colors.pinkAccent),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _fetchData,
              icon: const Icon(Icons.refresh),
              label: const Text('再読み込みする'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.pinkAccent,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // 🎨 イラストグリッド表示
  // ==========================================
  Widget _buildIllustGrid(int crossAxisCount) {
    final filteredIllusts = _illusts.where((illust) {
      // 1. 作品種別フィルター
      if (_selectedWorkType != 'all') {
        if (_selectedWorkType == 'illust' && illust.type != 'illust') {
          return false;
        }
        if (_selectedWorkType == 'manga' && illust.type != 'manga') {
          return false;
        }
        if (_selectedWorkType == 'ugoira' && illust.type != 'ugoira') {
          return false;
        }
        if (_selectedWorkType == 'novel') {
          return false;
        }
      }
      // 2. 年齢制限フィルター
      final hasR18Tag = illust.tags.any(
        (t) =>
            t.toLowerCase().contains('r-18') || t.toLowerCase().contains('r18'),
      );
      if (_selectedAgeLimit == 'safe' && hasR18Tag) return false;
      if (_selectedAgeLimit == 'r18' && !hasR18Tag) return false;
      return true;
    }).toList();

    if (filteredIllusts.isEmpty && _illusts.isNotEmpty) {
      return const Center(
        child: Text(
          'フィルターに一致するイラストが見つかりませんでした。',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    if (_illusts.isEmpty) {
      return const Center(
        child: Text('イラストが見つかりませんでした。', style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchData,
      child: GridView.builder(
        controller: _scrollController,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.all(6.0),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 6.0,
          mainAxisSpacing: 6.0,
          childAspectRatio: 0.75,
        ),
        itemCount: filteredIllusts.length + (_nextOffset != null ? 1 : 0),
        itemBuilder: (context, index) {
          // 最下部に到達した時のローディング追加表示
          if (index == filteredIllusts.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: CircularProgressIndicator(color: Colors.pinkAccent),
              ),
            );
          }

          final illust = filteredIllusts[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            elevation: 3,
            child: InkWell(
              onTap: () async {
                // 詳細画面へ遷移
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => IllustDetailScreen(
                      illust: illust,
                      onTagTap: _onTagSelected,
                      onBookmarkChanged: (newVal) {
                        setState(() {
                          illust.isBookmarked = newVal;
                        });
                      },
                    ),
                  ),
                );
                // 戻った際、状態整合性を保つため再描画
                if (!mounted) return;
                setState(() {});
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 画像ローダー
                  const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  // プレビュー画像
                  if (illust.urls.preview != null)
                    PixivImage(
                      url: illust.urls.preview ?? '',
                      isThumbnail: true,
                      fit: BoxFit.cover,
                    ),
                  // ブックマーク済みハートバッジ (左上)
                  if (illust.isBookmarked)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.favorite,
                          size: 16,
                          color: Colors.pinkAccent,
                        ),
                      ),
                    ),
                  // 複数枚インジケータ (右上)
                  if (illust.pageCount > 1)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${illust.pageCount}P',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  // タイトル & ユーザー名フッター
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(6.0),
                      color: Colors.black87,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            illust.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '👤 ${illust.author.name}',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 9,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
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

  // ==========================================
  // 📚 小説リスト表示（レスポンシブ GridView）
  // ==========================================
  Widget _buildNovelList() {
    final filteredNovels = _novels.where((novel) {
      // 1. 年齢制限フィルター (小説専用)
      final hasR18Tag = novel.tags.any(
        (t) =>
            t.toLowerCase().contains('r-18') || t.toLowerCase().contains('r18'),
      );
      if (_selectedNovelAgeLimit == 'safe' && hasR18Tag) {
        return false;
      }
      if (_selectedNovelAgeLimit == 'r18' && !hasR18Tag) {
        return false;
      }

      // 2. 本文の長さフィルター (小説専用)
      if (_selectedNovelTextLengthLimit == 'short' && novel.textLength > 5000) {
        return false;
      }
      if (_selectedNovelTextLengthLimit == 'medium' &&
          (novel.textLength <= 5000 || novel.textLength > 20000)) {
        return false;
      }
      if (_selectedNovelTextLengthLimit == 'long' &&
          novel.textLength <= 20000) {
        return false;
      }

      return true;
    }).toList();

    if (filteredNovels.isEmpty && _novels.isNotEmpty) {
      return const Center(
        child: Text(
          'フィルターに一致する小説が見つかりませんでした。',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    if (_novels.isEmpty) {
      return const Center(
        child: Text('小説が見つかりませんでした。', style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchData,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 700;

          Widget buildItem(BuildContext context, int index) {
            // 最下部ローディング表示
            if (index == filteredNovels.length) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(color: Colors.pinkAccent),
                ),
              );
            }
            final novel = filteredNovels[index];
            // スマホ(<=700px): 高さ固定 135px / タブレット(>700px): 145px の横長カード
            return SizedBox(
              height: isWide ? 145 : 135,
              child: _buildNovelItemCard(novel),
            );
          }

          if (isWide) {
            // タブレット・PC: 2列グリッド、mainAxisExtent で高さ固定
            return GridView.builder(
              controller: _scrollController,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.all(6.0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisExtent: 145,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: filteredNovels.length + (_nextOffset != null ? 1 : 0),
              itemBuilder: buildItem,
            );
          }

          // スマホ: 標準的な縦スクロールリスト、高さ固定 135px
          return ListView.builder(
            controller: _scrollController,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.all(6.0),
            itemCount: filteredNovels.length + (_nextOffset != null ? 1 : 0),
            itemBuilder: buildItem,
          );
        },
      ),
    );
  }

  // 小説カード（横長・固定高）: 左カバー + 右詳細カラム
  Widget _buildNovelItemCard(Novel novel) {
    final avatar = novel.author.avatar;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => NovelDetailScreen(
                novel: novel,
                onTagTap: _onTagSelected,
                onBookmarkChanged: (newVal) {
                  setState(() {
                    novel.isBookmarked = newVal;
                  });
                },
              ),
            ),
          );
          if (!mounted) return;
          setState(() {});
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 左側: 角丸カバー画像（幅 100px, 小説カバー標準の縦長比率 2:3 を固定維持）
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                bottomLeft: Radius.circular(10),
              ),
              child: SizedBox(
                width: 100,
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      color: Colors.grey[900],
                      child: novel.coverUrl.isNotEmpty
                          ? PixivImage(
                              url: novel.coverUrl,
                              isThumbnail: true,
                              fit: BoxFit.cover,
                            )
                          : const Center(
                              child: Icon(
                                Icons.book,
                                color: Colors.grey,
                                size: 32,
                              ),
                            ),
                    ),
                    if (novel.isBookmarked)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.favorite,
                            size: 14,
                            color: Colors.pinkAccent,
                          ),
                        ),
                      ),
                    if (novel.pageCount > 1)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${novel.pageCount} P',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // 右側: 詳細情報（Expanded）
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10.0,
                  vertical: 8.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // タイトル（太字・最大2行）
                    Text(
                      novel.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.white,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    // 作者情報（丸アバター + 名前）
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 7,
                          backgroundImage: avatar != null && avatar.isNotEmpty
                              ? NetworkImage(
                                  avatar,
                                  headers: const {
                                    'Referer': 'https://app-api.pixiv.net/',
                                  },
                                )
                              : null,
                          child: (avatar == null || avatar.isEmpty)
                              ? const Icon(Icons.person, size: 7)
                              : null,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            novel.author.name,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 10,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    // タグ一覧 (Wrap で折り返し表示)
                    if (novel.tags.isNotEmpty)
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const ClampingScrollPhysics(),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 2,
                            children: novel.tags.map((tag) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.pinkAccent.withValues(
                                    alpha: 0.15,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(
                                    color: Colors.pinkAccent.withValues(
                                      alpha: 0.3,
                                    ),
                                    width: 0.5,
                                  ),
                                ),
                                child: Text(
                                  tag,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: Colors.pinkAccent,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    const Spacer(),
                    // 統計バッジ行（ページ数 / 文字数 / 進捗）
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.teal.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.menu_book,
                                size: 9,
                                color: Colors.tealAccent,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '${novel.pageCount} P',
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.tealAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.edit_note,
                                size: 10,
                                color: Colors.blueAccent,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '${_formatNumber(novel.textLength)} 文字',
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        FutureBuilder<double?>(
                          future: SharedPreferences.getInstance().then(
                            (prefs) =>
                                prefs.getDouble('novel_progress_${novel.id}'),
                          ),
                          builder: (context, snapshot) {
                            final progress = snapshot.data;
                            if (progress == null || progress <= 0.0) {
                              return const SizedBox.shrink();
                            }
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.pink.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.bookmark,
                                    size: 9,
                                    color: Colors.pinkAccent,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '${progress.toStringAsFixed(0)}%',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.pinkAccent,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 数値フォーマットヘルパー (3桁カンマ区切り)
  String _formatNumber(int? number) {
    if (number == null) return '0';
    final str = number.toString();
    final reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    return str.replaceAllMapped(reg, (Match m) => '${m[1]},');
  }

  // 読書中（しおり）の小説の簡易情報を取得する
  Future<List<Map<String, dynamic>>> _getRecentBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> bookmarkedIds =
          prefs.getStringList('novel_bookmark_ids') ?? [];
      final List<Map<String, dynamic>> results = [];

      for (final idStr in bookmarkedIds) {
        final id = int.tryParse(idStr);
        if (id == null) continue;

        final title = prefs.getString('novel_title_$id');
        final author = prefs.getString('novel_author_$id');
        final progress = prefs.getDouble('novel_progress_$id') ?? 0.0;
        final lastRead = prefs.getInt('novel_last_read_$id') ?? 0;

        if (title != null && progress > 0.0 && progress < 100.0) {
          // 読了(100%)していないものを対象
          results.add({
            'id': id,
            'title': title,
            'author': author ?? '不明',
            'progress': progress,
            'lastRead': lastRead,
          });
        }
      }

      // 最終読書日時（lastRead）が新しい順にソート
      results.sort((a, b) => b['lastRead'].compareTo(a['lastRead']));

      return results.take(5).toList();
    } catch (e) {
      debugPrint('しおり履歴の取得失敗: $e');
      return [];
    }
  }

  // しおり履歴（読書中）セクションのビルド
  // ※ future は build ごとに再生成すると無限リビルド（親ルートの setState ループ）を招くため、
  //  initState で一度だけ生成したインスタンスをキャッシュして再利用する。
  Future<List<Map<String, dynamic>>>? _recentBookmarksFuture;

  Widget _buildRecentBookmarksSection() {
    _recentBookmarksFuture ??= _getRecentBookmarks();
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _recentBookmarksFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }

        final list = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                children: [
                  Icon(
                    Icons.bookmark_added,
                    color: Colors.pinkAccent,
                    size: 18,
                  ),
                  SizedBox(width: 8),
                  Text(
                    '読書中の小説 (しおり履歴)',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 110,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                itemCount: list.length,
                itemBuilder: (context, idx) {
                  final item = list[idx];
                  final id = item['id'] as int;
                  final title = item['title'] as String;
                  final author = item['author'] as String;
                  final progress = item['progress'] as double;

                  return Card(
                    color: const Color(0xFF1E1E1E),
                    margin: const EdgeInsets.symmetric(
                      horizontal: 6.0,
                      vertical: 4.0,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8.0),
                      side: BorderSide(
                        color: Colors.pinkAccent.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8.0),
                      onTap: () async {
                        // 読書再開用のダミーのNovelインスタンスを生成
                        final novel = Novel(
                          id: id,
                          title: title,
                          caption: '',
                          coverUrl: '', // 履歴からはカバー画像なし
                          createDate: '',
                          textCount: 0,
                          wordCount: 0,
                          textLength: 0,
                          pageCount: 0,
                          totalBookmarks: 0,
                          totalView: 0,
                          isBookmarked: false,
                          tags: [],
                          author: Author(
                            id: 0,
                            name: author,
                            account: '',
                            avatar: null,
                          ),
                        );

                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => NovelDetailScreen(
                              novel: novel,
                              onTagTap: _onTagSelected,
                              onBookmarkChanged: (_) {},
                            ),
                          ),
                        );
                        // 戻ってきたら再描画
                        if (!mounted) return;
                        setState(() {});
                      },
                      child: Container(
                        width: 180,
                        padding: const EdgeInsets.all(10.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'by $author',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      '進捗',
                                      style: TextStyle(
                                        color: Colors.grey,
                                        fontSize: 9,
                                      ),
                                    ),
                                    Text(
                                      '${progress.toStringAsFixed(0)}%',
                                      style: const TextStyle(
                                        color: Colors.pinkAccent,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: LinearProgressIndicator(
                                    value: progress / 100.0,
                                    backgroundColor: Colors.grey[800],
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                          Colors.pinkAccent,
                                        ),
                                    minHeight: 4,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(color: Colors.grey, height: 16),
          ],
        );
      },
    );
  }

  // サブスクリプション同期進捗 HUD
  Widget _buildSyncProgressHUD() {
    final status = _syncProgress?['status'] as String? ?? 'unknown';
    final message = _syncProgress?['message'] as String? ?? '';
    final current = _syncProgress?['current'] as int? ?? 0;
    final total = _syncProgress?['total'] as int? ?? 0;
    final currentNovel = _syncProgress?['current_novel'] as String? ?? '';

    double progress = 0.0;
    if (total > 0) {
      progress = current / total;
    }

    return Positioned(
      top: MediaQuery.of(context).padding.top + 80,
      left: 16,
      right: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF1E1E1E),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.tealAccent.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.sync, color: Colors.tealAccent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '小説サブスクリプション同期中',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (status == 'error')
                    const Icon(Icons.error, color: Colors.redAccent, size: 20)
                  else if (status == 'completed')
                    const Icon(
                      Icons.check_circle,
                      color: Colors.greenAccent,
                      size: 20,
                    )
                  else
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.tealAccent,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                message,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (currentNovel.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '同期中: $currentNovel',
                  style: const TextStyle(
                    color: Colors.tealAccent,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.grey[800],
                      valueColor: AlwaysStoppedAnimation<Color>(
                        status == 'error'
                            ? Colors.redAccent
                            : Colors.tealAccent,
                      ),
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    total > 0
                        ? '$current / $total (${(progress * 100).toStringAsFixed(0)}%)'
                        : '準備中...',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _initializeDriveSync() async {
    await _driveService.signInSilently();
    if (mounted && _driveService.isLoggedIn) {
      setState(() {
        _loggedInEmail = _driveService.signedInEmail;
      });
    }
  }

  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );
  }

  void _hideLoadingDialog() {
    Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> _handleGoogleBackup() async {
    _showLoadingDialog();
    try {
      final success = await _driveService.backupHistoryDb();
      _hideLoadingDialog();
      if (success && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('バックアップ完了しました！')));
      } else if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('バックアップに失敗しました')));
      }
    } catch (e) {
      _hideLoadingDialog();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラー：$e')));
      }
    }
  }

  Future<void> _handleGoogleRestore() async {
    _showLoadingDialog();
    try {
      final success = await _driveService.restoreHistoryDb();
      _hideLoadingDialog();
      if (success && mounted) {
        setState(() {});
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('復元完了しました！')));
      } else if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('復元に失敗しました')));
      }
    } catch (e) {
      _hideLoadingDialog();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラー：$e')));
      }
    }
  }

  Future<void> _handleGoogleLogin() async {
    try {
      await _driveService.signIn();
      if (mounted && _driveService.isLoggedIn) {
        setState(() {
          _loggedInEmail = _driveService.signedInEmail;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('ログイン失敗：$e')));
      }
    }
  }

  Future<void> _handleGoogleLogout() async {
    await _driveService.signOut();
    if (mounted) {
      setState(() {
        _loggedInEmail = null;
      });
    }
  }

  Widget _buildGoogleDriveSyncSection() {
    if (_loggedInEmail == null) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: Colors.teal.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
        ),
        child: ListTile(
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.cloud_upload,
              color: Colors.tealAccent,
              size: 24,
            ),
          ),
          title: const Text(
            'Google ドライブ同期（パーソナルクラウド）',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: const Text(
            '履歴・お気に入り・購読データをクラウドで管理',
            style: TextStyle(color: Colors.white60, fontSize: 11),
          ),
          trailing: const Icon(
            Icons.arrow_forward_ios,
            color: Colors.white54,
            size: 16,
          ),
          onTap: _handleGoogleLogin,
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー：アカウント情報
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.1),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.teal.withValues(alpha: 0.2),
                  child: const Icon(
                    Icons.person,
                    color: Colors.tealAccent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ログイン中',
                        style: TextStyle(
                          color: Colors.tealAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _loggedInEmail!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // 説明テキスト
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              '履歴・フォルダ・購読タグを Google ドライブ（appDataFolder）と同期',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          ),

          const SizedBox(height: 12),

          // ボタン行：バックアップ / 復元
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                // クラウドにバックアップ（送信）
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _handleGoogleBackup,
                    icon: const Icon(Icons.cloud_upload, size: 18),
                    label: const Text(
                      'クラウドにバックアップ（送信）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // クラウドから復元（受信）
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _handleGoogleRestore,
                    icon: const Icon(Icons.cloud_download, size: 18),
                    label: const Text(
                      'クラウドから復元（受信）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ログアウトボタン
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: _handleGoogleLogout,
                icon: const Icon(Icons.logout, color: Colors.white54, size: 18),
                label: const Text(
                  'ログアウト',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
