import 'package:flutter/material.dart';

import '../screens/home_screen_widget.dart';

/// アプリの外側を包む「殻」（Phase 16c-1）。
///
/// 16c-1 では **何も変えずに** `MaterialApp.home` と [PixivViewerHome] の間に
/// 1 枚挟むだけ。ボトムナビも AppBar も [Scaffold] も持たない。
/// - 殻が [Scaffold] を持たないため、内側の [PixivViewerHome] の
///   `Scaffold` / `ScaffoldMessenger` がそのまま機能する（二重化しない）。
/// - ネストした [Navigator] は 16c-1 では導入しない（Android 戻るボタンの
///   挙動を変えないため）。16c-2 でボトムナビ移譲に合わせて導入する。
///
/// 16c-2 以降はここに `bottomNavigationBar` と複数タブを追加していく。
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.tabs});

  /// タブの内容。`null` の場合は本番構成（16c-1 では [PixivViewerHome] のみ）。
  ///
  /// テストで差し替え可能にするために公開している。本番では
  /// `const [PixivViewerHome()]` を使う。
  final List<Widget>? tabs;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 現在表示中のタブインデックス。16c-1 は常に 0（ホームのみ）。
  ///
  /// 16c-2 でボトムナビが追加されたら `final` を外し、タブ切替で
  /// 書き換える形にする（それまでは不変であることを型で表明する）。
  final int _index = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs ?? const [PixivViewerHome()];
    return IndexedStack(index: _index, children: tabs);
  }
}
