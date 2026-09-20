import 'package:flutter/material.dart';

import '../screens/home_screen_widget.dart';
import '../screens/library_hub_screen.dart';
import '../screens/settings_screen.dart';

/// アプリの外側を包む「殻」（Phase 16c-3b）。
///
/// 最終的な 4 つの目的地（ホーム / 検索 / ライブラリ / 設定）を
/// [NavigationBar] で切り替える。ただし **物理 [Navigator] は 3 つ**:
///
/// ```text
/// 目的地0 ホーム     ┐
/// 目的地1 検索       ┴─ 同じ Navigator + 同じ PixivViewerHomeState
/// 目的地2 ライブラリ ─ Library Navigator
/// 目的地3 設定       ─ Settings Navigator
/// ```
///
/// ホームと検索は [HomeSurfaceMode] だけで表示を切り替えるため、
/// 検索 Controller・検索結果・フィルタ・履歴を複製しない。
/// （2 つ目の [PixivViewerHome] を作らない・API リクエストを二重化しない）
///
/// - タブを切り替えても各物理 Navigator の履歴と Widget state は保持される
///   （[Offstage] が `offstage` でも全タブを build・layout するため。
///   Phase 16d-2 までは [IndexedStack] だったが、これに [AnimatedOpacity] を
///   組み合わせたところ実機で **選択タブまで透明になる** 不具合
///   （フィーリング発掘がタップに反応しない）が発生したため、
///   Phase 17a で `Stack` + [Offstage] に置き換えた）。
/// - 選択中の目的地をもう一度タップすると、その物理 Navigator の
///   ルートまで pop する。
/// - ホーム/検索の切替時は共通 Navigator をルートまで pop し、
///   検索ワークスペースを表示する（State は破棄しない）。
/// - ライブラリ起点のタグ連携は検索目的地へ切り替えてから
///   [PixivViewerHomeState.onTagSelected] を呼ぶ。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.homeKey,
    this.tabs,
    this.destinations,
    this.destinationToTab,
  });

  /// ホームタブ（[PixivViewerHome]）に外部からアクセスするためのキー。
  ///
  /// 未指定なら [AppShell] が内部で生成する。テストでタグ連携を検証するときに使う。
  final GlobalKey<PixivViewerHomeState>? homeKey;

  /// 物理 Navigator のルート画面。`null` の場合は本番構成
  /// （[PixivViewerHome] / [LibraryHubScreen] / [SettingsScreen]）。
  ///
  /// テストで差し替え可能にするために公開している。各要素は
  /// 自動的に物理タブ専用の [Navigator] で包まれる。
  final List<Widget>? tabs;

  /// [NavigationBar] に表示する目的地。`null` の場合は本番の 4 目的地。
  final List<NavigationDestination>? destinations;

  /// 目的地 → 物理 Navigator タブ のマッピング（Phase 16c-3b）。
  ///
  /// ホームと検索は同じ物理タブ（同じ [PixivViewerHomeState]）を共有するため、
  /// 本番構成では `[0, 0, 1, 2]` になる。`null` の場合は本番値。
  ///
  /// 制約（[AppShellState.initState] で検証）:
  /// - [destinations] と長さが一致すること
  /// - 各値が [tabs] の範囲内であること
  /// - [tabs] は最低 1 つであること
  final List<int>? destinationToTab;

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  /// 最終 4 目的地（Phase 16c-3b）。
  static const List<NavigationDestination> _defaultDestinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'ホーム',
    ),
    NavigationDestination(
      icon: Icon(Icons.search),
      selectedIcon: Icon(Icons.manage_search),
      label: '検索',
    ),
    NavigationDestination(
      icon: Icon(Icons.collections_bookmark_outlined),
      selectedIcon: Icon(Icons.collections_bookmark),
      label: 'ライブラリ',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: '設定',
    ),
  ];

  /// 目地道 0(ホーム) と 1(検索) は物理タブ 0 を共有する。
  static const List<int> _defaultDestinationToTab = [0, 0, 1, 2];

  // 目的地インデックス（NavigationBar の selectedIndex）
  static const int homeDestination = 0;
  static const int searchDestination = 1;
  static const int libraryDestination = 2;
  static const int settingsDestination = 3;

  // 物理 Navigator タブインデックス
  static const int homeTab = 0;
  static const int libraryTab = 1;

  /// 本番の物理タブ数（ホーム/検索共有 / ライブラリ / 設定）。
  static const int _defaultTabCount = 3;

  /// ホームの State にアクセスするためのキー。
  /// [widget.homeKey] が渡されなければ内部で生成する。
  late final GlobalKey<PixivViewerHomeState> _homeKey =
      widget.homeKey ?? GlobalKey<PixivViewerHomeState>();

  /// ライブラリの State。タブ切替時の未読数再取得に使う。
  late final GlobalKey<LibraryHubScreenState> _libraryKey =
      GlobalKey<LibraryHubScreenState>();

  /// ホーム/検索の表示モード（Phase 16c-3b）。
  ///
  /// ホームと検索は同じ [PixivViewerHomeState] を共有するため、
  /// この [ValueNotifier] で表示だけを切り替える。
  /// [AppShell] が所有するため dispose する。
  final ValueNotifier<HomeSurfaceMode> _homeSurfaceMode =
      ValueNotifier<HomeSurfaceMode>(HomeSurfaceMode.feed);

  /// 現在表示中の目的地インデックス。
  int _destinationIndex = homeDestination;

  /// タブごとの [Navigator] キー。
  late final List<GlobalKey<NavigatorState>> _navigatorKeys =
      List<GlobalKey<NavigatorState>>.generate(
        _tabCount,
        (_) => GlobalKey<NavigatorState>(),
      );

  int get _tabCount => widget.tabs?.length ?? _defaultTabCount;

  List<NavigationDestination> get _destinations =>
      widget.destinations ?? _defaultDestinations;

  List<int> get _destinationToTab =>
      widget.destinationToTab ?? _defaultDestinationToTab;

  /// 現在表示中の物理 Navigator タブ。
  int get _currentTab => _destinationToTab[_destinationIndex];

  /// 構成の整合性を検証する。
  ///
  /// これらをコンストラクタの assert にすると `const AppShell(...)` が
  /// 「const 式の中で `.length` にアクセスできない」エラーになるため、
  /// [State.initState] で実行時に検証する。
  void _validateConfiguration() {
    final tabs = widget.tabs;
    final destinations = widget.destinations;
    final mapping = widget.destinationToTab;
    assert(tabs == null || tabs.isNotEmpty, 'tabs は最低 1 つ必要');
    final tabCount = _tabCount;
    if (destinations != null && mapping != null) {
      assert(
        destinations.length == mapping.length,
        'destinations(${destinations.length}) と '
        'destinationToTab(${mapping.length}) の長さは一致が必要',
      );
      for (var i = 0; i < mapping.length; i++) {
        assert(
          mapping[i] >= 0 && mapping[i] < tabCount,
          'destinationToTab[$i] = ${mapping[i]} が '
          'tabs の範囲 [0, $tabCount) の外を指している',
        );
      }
    }
  }

  List<Widget> _effectiveTabs() {
    final tabs = widget.tabs;
    if (tabs != null) return tabs;
    return [
      PixivViewerHome(
        key: _homeKey,
        surfaceModeListenable: _homeSurfaceMode,
        onSearchDestinationRequested: _switchToSearch,
        onHomeDestinationRequested: _switchToHome,
      ),
      LibraryHubScreen(key: _libraryKey, onTagTap: _searchForTag),
      const SettingsScreen(),
    ];
  }

  @override
  void initState() {
    super.initState();
    _validateConfiguration();
  }

  @override
  void dispose() {
    // AppShell が生成した Notifier だけを dispose する。
    // （本番構成でもテスト注入 tabs でも、この Notifier は常に
    //  AppShell の所有物であるため無条件で解放する）
    _homeSurfaceMode.dispose();
    super.dispose();
  }

  /// NavigationBar の目的地がタップされた。
  void _onDestinationSelected(int destination) {
    if (destination == _destinationIndex) {
      // 選択中目的地の再タップ: その物理 Navigator のルートまで pop する。
      _navigatorKeys[_currentTab].currentState?.popUntil((route) {
        return route.isFirst;
      });
      return;
    }
    _selectDestination(destination);
  }

  /// 目的地を切り替える（Phase 16c-3b）。
  ///
  /// ホーム/検索の切替時は **同じ物理 Navigator** をルートまで pop し、
  /// [HomeSurfaceMode] だけで表示を切り替える（State・検索結果は保持）。
  /// Library / Settings への切替時は各 Navigator の履歴を維持する。
  void _selectDestination(int destination) {
    final tab = _destinationToTab[destination];
    setState(() {
      _destinationIndex = destination;
      // ホームと検索は同じ State を共有: モードだけで表示を切り替える。
      _homeSurfaceMode.value = destination == searchDestination
          ? HomeSurfaceMode.search
          : HomeSurfaceMode.feed;
    });

    // ホーム/検索の共通 Navigator は切替時にルートまで戻す
    // （詳細画面が検索ワークスペースを隠さないように）。
    if (tab == homeTab) {
      _navigatorKeys[homeTab].currentState?.popUntil((route) {
        return route.isFirst;
      });
    }

    // ライブラリへ切り替えたときは未読数を再取得する
    // （別画面でしおり/あとで読むを操作した直後を想定）。
    if (tab == libraryTab && widget.tabs == null) {
      _libraryKey.currentState?.refreshCounts();
    }
  }

  /// 検索目的地へ切り替える（[PixivViewerHomeState] からの依頼）。
  void _switchToSearch() {
    if (_destinationIndex != searchDestination) {
      _selectDestination(searchDestination);
    }
  }

  /// ホーム目的地へ切り替える（[PixivViewerHomeState] からの依頼）。
  void _switchToHome() {
    if (_destinationIndex != homeDestination) {
      _selectDestination(homeDestination);
    }
  }

  /// ライブラリのタグがタップされた: 検索目的地へ切り替えて検索を実行する。
  ///
  /// [PixivViewerHome] が未構築でも例外を出さない（PostFrameCallback で
  /// build 完了後に呼ぶ）。
  void _searchForTag(String tag) {
    _selectDestination(searchDestination);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _homeKey.currentState?.onTagSelected(tag);
    });
  }

  /// テスト用: ライブラリ起点のタグ検索を直接トリガーする。
  ///
  /// 本番では [LibraryHubScreen] の `onTagTap` がこの処理を呼ぶ。
  /// [PixivViewerHome] が未構築（テスト注入タブ構成など）でも
  /// `_homeKey.currentState?.onTagSelected` の `?.` で例外を出さない。
  @visibleForTesting
  void searchForTagForTest(String tag) => _searchForTag(tag);

  /// テスト用: ホーム/検索の現在のサーフェスモード。
  ///
  /// ホームと検索は同じ [PixivViewerHomeState] を共有しているため、
  /// これが [HomeSurfaceMode.search] なら検索ワークスペース表示中。
  @visibleForTesting
  HomeSurfaceMode get homeSurfaceModeForTest => _homeSurfaceMode.value;

  /// 1 タブを、そのタブ専用の [Navigator] で包む。
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
      // 選択中タブだけが OS の戻るを受け持つ。
      enabled: _currentTab == index,
      onPopWithResult: (result) {
        _navigatorKeys[index].currentState?.maybePop(result);
      },
      child: navigator,
    );
  }

  /// 17a: タブの表示を制御する（16d-2 の AnimatedOpacity は撤去）。
  ///
  /// 16d-2 では [IndexedStack] の各タブを [AnimatedOpacity] で包んだが、
  /// 実機で **選択タブまで透明になる** （背景色だけ描画され、タップに一切
  /// 反応しない）不具合が発生した。フィーリング発掘が動かない原因はこれだった。
  ///
  /// そのため「フェードスルー」を優先せず、[Stack] + [Offstage] に戻す:
  /// - [Offstage] は `offstage` でも child を build・layout する
  ///   （[RenderOffstage.performLayout]）ので、各タブの Navigator 履歴と
  ///   Widget state はそのまま保持される（[IndexedStack] と同等）。
  /// - 描画とヒットテストだけがスキップされるため、隠れタブが
  ///   選択タブのタップを奪うこともない。
  /// - `offstage: true` の子はテストフレームワークの `skipOffstage` に
  ///   より「非表示」と判定される（[Offstage] がその基準）ため、
  ///   タブをまたぐ Widget 検索が従来どおり機能する。
  ///
  /// アニメーションが必要な場合は [AppPageTransitionsBuilder]（画面遷移）と
  /// [HomeSurfaceMode] のヘッダー切替（[AnimatedSwitcher]）が別経路で担う。
  Widget _buildTabOffstage(Widget tab, int index) {
    final selected = _currentTab == index;
    return Offstage(
      offstage: !selected,
      child: KeyedSubtree(key: ValueKey('app-shell-tab-$index'), child: tab),
    );
  }

  /// 現在タブのネスト Navigator が pop 可能か（= ルートより上に画面があるか）。
  bool get _currentTabCanPop {
    final navigator = _navigatorKeys[_currentTab].currentState;
    return navigator?.canPop() ?? false;
  }

  /// OS の戻るが押された（Android 予測型バック）。
  ///
  /// 優先順位:
  /// 1. 現在の物理 Navigator が pop 可能 → ネスト Navigator が処理
  /// 2. Search / Library / Settings のルート → ホーム目的地へ切替
  /// 3. ホーム目的地のルート → Flutter/OS の通常処理に任せる
  ///    （`SystemNavigator.pop()` は直接呼ばない）
  Future<void> _handleSystemPop() async {
    if (_currentTabCanPop) return; // 1: maybePop が処理する
    if (_destinationIndex != homeDestination) {
      _selectDestination(homeDestination); // 2
    }
    // 3: ここで false を返すと Flutter が OS へ戻す
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _effectiveTabs();
    final destinations = _destinations;
    return PopScope(
      // 現在タブが pop 可能なら OS 戻るをここで消費せずネスト Navigator へ。
      canPop: !_currentTabCanPop && _destinationIndex == homeDestination,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleSystemPop();
      },
      child: Scaffold(
        // appBar も drawer も持たない: 各タブが自分の Scaffold を持つ。
        // 17a: IndexedStack + AnimatedOpacity をやめ Stack + Offstage に戻す。
        // 前者の組合せが実機で「選択タブが透明になる」原因だったため。
        body: Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < tabs.length; i++)
              _buildTabOffstage(_wrapInNavigator(tabs[i], i), i),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _destinationIndex,
          onDestinationSelected: _onDestinationSelected,
          destinations: destinations,
        ),
      ),
    );
  }
}
