import 'dart:async';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';
import 'screens/illust_detail_screen.dart';
import 'screens/novel_detail_screen.dart';
import 'screens/novel_series_episodes_screen.dart';
import 'novel_model.dart';
import 'services/download_service.dart';
import 'services/model_download_coordinator.dart';
import 'services/pixiv_api_service.dart';
import 'services/theme_service.dart';
import 'services/usage_tracking_service.dart';
import 'theme/app_theme.dart';
import 'widgets/app_shell.dart';
import 'package:permission_handler/permission_handler.dart';

// ワークマネージャー（バックグラウンドダウンロード）のコールバックディスパッチャー。
// Android のみ登録される（他OSはフォアグラウンド縮退）。
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == ModelDownloadCoordinator.taskName) {
      // B6: AI モデル DL バックグラウンドタスク（入力は sendable な modelId のみ）。
      return ModelDownloadCoordinator.runModelDownloadOnce(inputData);
    }
    // 既存: イラスト/小説のバックグラウンド DL キュー
    await DownloadService().runBackgroundOnce(inputData);
    return true;
  });
}

/// Android 13(API 33) 以上で通知権限を要求する（拒否されてもクラッシュしない）。
Future<void> _requestPostNotificationsIfNeeded() async {
  if (!Platform.isAndroid) return;
  try {
    final status = await Permission.notification.status;
    if (status.isDenied || status.isLimited) {
      await Permission.notification.request();
    }
  } catch (e) {
    debugPrint('[main] POST_NOTIFICATIONS 権限要求失敗(無視): $e');
  }
}

// ディープリンク遷移用のグローバルナビゲーターキー
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Phase 11c: テーマ設定（System / Light / Dark）を SharedPreferences から読み込む。
  // runApp 前に完了させることで初帧からテーマが反映される。
  await ThemeService().init();
  // FGS 通信用ポート初期化（TaskHandler↔UI）。
  FlutterForegroundTask.initCommunicationPort();
  // flutter_foreground_task v11.0.3 は init() を呼ばないと startService が
  // ServiceNotInitializedException → ServiceRequestFailure を返し起動しない。
  // runApp 前・一度だけ実行する（B2-6 Step1 真因修正）。
  FlutterForegroundTask.init(
    // 自動要約専用の単一チャンネル（新規乱立を避ける）。
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'auto_summary',
      channelName: 'PixEmber 自動要約',
      channelDescription: '自動要約の実行状態を表示する通知',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    // AutoSummaryTaskHandler は onRepeatEvent 非依存（コマンド/通知更新は
    // listener+Timer 駆動で完結）→ nothing() が適切。
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: false,
    ),
  );
  // Android のみ workmanager を初期化（バックグラウンド継続ダウンロード）
  if (Platform.isAndroid) {
    await Workmanager().initialize(callbackDispatcher);
    // B6: アプリ起動中のモデル DL 進捗を上位 isolate で受信（SharedPreferences へ反映）。
    await Workmanager().setProgressListener((uniqueName, progress) async {
      await ModelDownloadCoordinator().handleProgressUpdate(progress);
    });
    // 通知権限（Android 13+）を要求（拒否されても継続）。
    await _requestPostNotificationsIfNeeded();
    // バックグラウンドタスクを1回登録（既存なら維持）
    await DownloadService().registerBackgroundTaskIfAndroid();
  }
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final PixivApiService _api = PixivApiService();
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initDeepLinks();
  }

  /// アプリのライフサイクル変化で利用時間トラッキング（Phase 4）を制御する。
  /// - バックグラウンド移行: ここまでの経過時間をチェックポイント保存。
  /// - フォアグラウンド復帰: バックグラウンド中の時間を計測から除外。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(UsageTrackingService().checkpointAll());
    } else if (state == AppLifecycleState.resumed) {
      UsageTrackingService().discardBackgroundTime();
    }
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
    _linkSub = _appLinks.uriLinkStream.listen(_handleLink);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
    super.dispose();
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
    // Phase 11c: ThemeService の変更を MaterialApp の themeMode に反映する。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeService().themeModeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'PixEmber',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
          navigatorKey: _navigatorKey,
          // 16c-1: ホームの周りに AppShell の殻を被せる。
          // 16c-2 でこの殻にボトムナビと複数タブが追加される。
          home: const AppShell(),
        );
      },
    );
  }
}

class _ParsedLink {
  final String type; // 'illust' | 'novel' | 'series'
  final int id;

  _ParsedLink(this.type, this.id);
}
