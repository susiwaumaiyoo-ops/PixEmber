import 'package:flutter/material.dart';

import '../screens/home_screen_widget.dart';
import '../screens/library_hub_screen.dart';
import '../screens/settings_screen.dart';

/// アプリの外側を包む「殻」（Phase 16c-2c）。
///
/// 3 つの目的地（ホーム / ライブラリ / 設定）を [NavigationBar] で切り替え、
/// それぞれが独立した [Navigator]（ネスト Navigator）を持つ。
/// - タブを切り替えても各タブのルート履歴と Widget state は保持される
///   （[IndexedStack] が全タブを常に構築するため）。
/// - 選択中のタブをもう一度タップすると、そのタブのルートまで pop する。
/// - ライブラリ起点のタグ連携は [LibraryHubScreen.onTagTap] を受け、
///   ホームタブへ切り替えてから [PixivViewerHomeState.onTagSelected] を呼ぶ。
///
/// 戻る操作（Android 予測型バック）は 16c-2d で [PopScope] を使って
/// ネスト Navigator に振り向ける。本 Sub では Navigator 構造だけを導入する。
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.homeKey, this.tabs, this.destinations});

  /// ホームタブ（[PixivViewerHome]）に外部からアクセスするためのキー。
  ///
  /// 未指定なら [AppShell] が内部で生成する。テストでタグ連携を検証するときに使う。
  final GlobalKey<PixivViewerHomeState>? homeKey;

  /// タブのルート画面。`null` の場合は本番構成
  /// （[PixivViewerHome] / [LibraryHubScreen] / [SettingsScreen]）。
  ///
  /// テストで差し替え可能にするために公開している。各要素は
  /// 自動的にタブ専用の [Navigator] で包まれる。
  final List<Widget>? tabs;

  /// [NavigationBar] に表示する目的地。`null` の場合は本番の 3 目的地。
  ///
  /// [tabs] と同時に指定する場合は数を一致させる（[State.initState] の
  /// assert で検証）。本番（`tabs == null`）なら初期値の 3 目的地が使われる。
  final List<NavigationDestination>? destinations;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 暫定構成の目的地（16c-2c）。最終 4 目的地（検索を追加）は 16c-3。
  static const List<NavigationDestination> _defaultDestinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'ホーム',
    ),
    NavigationDestination(
      icon: Icon(Icons.library_books_outlined),
      selectedIcon: Icon(Icons.library_books),
      label: 'ライブラリ',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: '設定',
    ),
  ];

  static const int homeIndex = 0;
  static const int libraryIndex = 1;

  /// ホームの State にアクセスするためのキー。
  /// [widget.homeKey] が渡されなければ内部で生成する。
  late final GlobalKey<PixivViewerHomeState> _homeKey =
      widget.homeKey ?? GlobalKey<PixivViewerHomeState>();

  /// ライブラリの State。タブ切替時の未読数再取得に使う。
  late final GlobalKey<LibraryHubScreenState> _libraryKey =
      GlobalKey<LibraryHubScreenState>();

  /// 現在表示中のタブインデックス。
  int _index = 0;

  /// タブごとの [Navigator] キー。
  late final List<GlobalKey<NavigatorState>> _navigatorKeys =
      List<GlobalKey<NavigatorState>>.generate(
        _tabCount,
        (_) => GlobalKey<NavigatorState>(),
      );

  int get _tabCount => widget.tabs?.length ?? _defaultDestinations.length;

  /// 構成の整合性を検証する。
  ///
  /// これらをコンストラクタの assert にすると `const AppShell(tabs: [...])` が
  /// 「const 式の中で `.length` にアクセスできない」エラーになるため、
  /// [State.initState] で実行時に検証する（本番・テストともに意味のある时机）。
  void _validateConfiguration() {
    final tabs = widget.tabs;
    final destinations = widget.destinations;
    assert(tabs == null || tabs.isNotEmpty, 'tabs は最低 1 つ必要');
    if (tabs != null && destinations != null) {
      assert(
        tabs.length == destinations.length,
        'tabs(${tabs.length}) と destinations(${destinations.length}) '
        'の数は一致が必要',
      );
    }
  }

  List<Widget> _effectiveTabs() {
    final tabs = widget.tabs;
    if (tabs != null) return tabs;
    return [
      PixivViewerHome(key: _homeKey),
      LibraryHubScreen(key: _libraryKey, onTagTap: _switchToHomeWithTag),
      const SettingsScreen(),
    ];
  }

  @override
  void initState() {
    super.initState();
    _validateConfiguration();
  }

  /// NavigationBar の目的地がタップされた。
  void _onTabSelected(int index) {
    if (index == _index) {
      // 選択中タブの再タップ: そのタブのルートまで pop する。
      // IndexedStack が全タブを構築するため currentState は非 null だが、
      // 初回 build 前の呼び出しを考慮して ?. で守る。
      _navigatorKeys[_index].currentState?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() => _index = index);
    // ライブラリへ切り替えたときは未読数を再取得する
    // （別画面でしおり/あとで読むを操作した直後を想定）。
    if (index == libraryIndex && widget.tabs == null) {
      _libraryKey.currentState?.refreshCounts();
    }
  }

  /// ライブラリのタグがタップされた: ホームタブへ切り替えて検索を実行する。
  ///
  /// [PixivViewerHome] が未構築でも例外を出さない（PostFrameCallback で
  /// build 完了後に呼ぶ）。
  void _switchToHomeWithTag(String tag) {
    if (_index != homeIndex) {
      setState(() => _index = homeIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _homeKey.currentState?.onTagSelected(tag);
    });
  }

  /// 1 タブを、そのタブ専用の [Navigator] で包む。
  ///
  /// `initialRoute: '/'` でルート画面を 1 枚積んだ状態で開始する。
  /// 以降の `Navigator.push` は渡された [MaterialPageRoute] をそのまま
  /// 積むため、タブごとに独立した履歴ができる。
  ///
  /// [NavigatorPopHandler] で包むことで、Android 予測型バックが
  /// **非選択タブの Navigator を操作せず** 現在タブだけを pop する
  /// （`enabled: false` でオフタブのハンドラを無効化）。
  Widget _wrapInNavigator(Widget tab, int index) {
    final navigator = Navigator(
      key: _navigatorKeys[index],
      initialRoute: '/',
      onGenerateRoute: (settings) {
        if (settings.name == '/') {
          return MaterialPageRoute<void>(
            builder: (_) => tab,
            settings: settings,
          );
        }
        return null;
      },
    );

    return NavigatorPopHandler(
      // 選択中タブだけが OS の戻るを受け持つ。オフタブの Navigator は
      // IndexedStack で offstage になっているが、PopScope と違い
      // NavigatorPopHandler は無効化しておかないと全タブが競合する。
      enabled: _index == index,
      onPopWithResult: (result) {
        _navigatorKeys[index].currentState?.maybePop(result);
      },
      child: navigator,
    );
  }

  /// 現在タブのネスト Navigator が pop 可能か（= ルートより上に画面があるか）。
  bool get _currentTabCanPop {
    final navigator = _navigatorKeys[_index].currentState;
    return navigator?.canPop() ?? false;
  }

  /// OS の戻るが押された（Android 予測型バック）。
  ///
  /// 優先順位:
  /// 1. 現在タブ内で pop 可能 → ネスト Navigator が処理
  /// 2. タブルートでホーム以外 → ホームへ切替
  /// 3. ホームタブルート → Flutter/OS の通常処理に任せる
  ///    （`SystemNavigator.pop()` は直接呼ばない）
  Future<void> _handleSystemPop() async {
    if (_currentTabCanPop) return; // 1: maybePop が処理する
    if (_index != homeIndex) {
      setState(() => _index = homeIndex); // 2
    }
    // 3: ここで false を返すと Flutter が OS へ戻す
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _effectiveTabs();
    final destinations = widget.destinations ?? _defaultDestinations;
    return PopScope(
      // 現在タブが pop 可能なら OS 戻るをここで消費せずネスト Navigator へ。
      canPop: !_currentTabCanPop && _index == homeIndex,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleSystemPop();
      },
      child: Scaffold(
        // appBar も drawer も持たない: 各タブが自分の Scaffold を持つ。
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < tabs.length; i++) _wrapInNavigator(tabs[i], i),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _onTabSelected,
          destinations: destinations,
        ),
      ),
    );
  }
}
