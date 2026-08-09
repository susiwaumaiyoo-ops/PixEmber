import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'screens/home_screen_widget.dart';
import 'screens/illust_detail_screen.dart';
import 'screens/novel_detail_screen.dart';
import 'screens/novel_series_episodes_screen.dart';
import 'novel_model.dart';
import 'services/pixiv_api_service.dart';

// ディープリンク遷移用のグローバルナビゲーターキー
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final PixivApiService _api = PixivApiService();
  final AppLinks _appLinks = AppLinks();

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
  }

  void _initDeepLinks() {
    // アプリ起動時にリンクから開かれた場合
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) {
        // 最初のフレーム後に処理（Navigator の準備待ち）
        WidgetsBinding.instance.addPostFrameCallback((_) => _handleLink(uri));
      }
    });
    // 起動中にリンクから開かれた場合
    _appLinks.uriLinkStream.listen(_handleLink);
  }

  void _handleLink(Uri uri) {
    final parsed = _parsePixivUri(uri);
    if (parsed == null) return;
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    _navigate(parsed, nav, uri);
  }

  Future<void> _navigate(
    _ParsedLink parsed,
    NavigatorState nav,
    Uri originalUri,
  ) async {
    try {
      if (parsed.type == 'illust') {
        final illust = await _api.getIllustById(parsed.id);
        if (!mounted) return;
        nav.push(
          MaterialPageRoute(builder: (_) => IllustDetailScreen(illust: illust)),
        );
      } else if (parsed.type == 'novel') {
        final novel = await _api.getNovelById(parsed.id);
        if (!mounted) return;
        nav.push(
          MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
        );
      } else if (parsed.type == 'series') {
        nav.push(
          MaterialPageRoute(
            builder: (_) => NovelSeriesEpisodesScreen(
              series: NovelSeriesInfo(id: parsed.id, title: ''),
            ),
          ),
        );
      }
    } catch (e) {
      // 未ログインや取得失敗時はブラウザへ逃がす
      if (await canLaunchUrl(originalUri)) {
        await launchUrl(originalUri, mode: LaunchMode.externalApplication);
      }
    }
  }

  /// pixiv.net の URL を (種別, ID) に解析する。
  /// 例: /artworks/123, /i/123, /novel/show.php?id=123,
  ///     /novel/123, /novel/series/123
  _ParsedLink? _parsePixivUri(Uri uri) {
    if (uri.host != 'www.pixiv.net' && uri.host != 'pixiv.net') return null;
    final segments = uri.pathSegments;

    if (segments.isNotEmpty &&
        (segments[0] == 'artworks' || segments[0] == 'i')) {
      final id = int.tryParse(segments.length > 1 ? segments[1] : '');
      if (id != null) return _ParsedLink('illust', id);
    }

    if (segments.isNotEmpty && segments[0] == 'novel') {
      if (segments.length > 1 && segments[1] == 'series') {
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id != null) return _ParsedLink('series', id);
      }
      final idParam = uri.queryParameters['id'];
      if (idParam != null) {
        final id = int.tryParse(idParam);
        if (id != null) return _ParsedLink('novel', id);
      }
      if (segments.length > 1) {
        final id = int.tryParse(segments[1]);
        if (id != null) return _ParsedLink('novel', id);
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PixEmber',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.pinkAccent,
          brightness: Brightness.dark,
          surface: const Color(0xFF121212),
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
        useMaterial3: true,
        cardTheme: const CardThemeData(color: Color(0xFF1E1E1E)),
      ),
      navigatorKey: _navigatorKey,
      home: const PixivViewerHome(),
    );
  }
}

class _ParsedLink {
  final String type; // 'illust' | 'novel' | 'series'
  final int id;

  _ParsedLink(this.type, this.id);
}
