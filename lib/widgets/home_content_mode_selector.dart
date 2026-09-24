import 'package:flutter/material.dart';

import '../screens/home_screen_state.dart';
import '../theme/app_spacing.dart';

/// ホームのコンテンツ種別（イラスト / 小説 / フィーリング発掘）を
/// 選ぶセグメントコントロール（Phase 16c-2a / 17c）。
///
/// 16c-1 までは [Scaffold.bottomNavigationBar] の [NavigationBar] が
/// この役割だった。16c-2 で殻（[AppShell]）がボトムナビを所有するため、
/// コンテンツ種別の切替は AppBar 直下の二位置 UI へ移動した。
///
/// - 選択値・切替の判定は全て [PixivViewerHomeState] が持つため、
///   この Widget は状態を持たない（新しい状態を増やさない）。
/// - ラベル・アイコン・セグメント順は旧 [NavigationBar] と同一。
/// - 選択中アイコンは表示しない（`showSelectedIcon: false`）。
///
/// 17c: 検索目的地を削除してフィーリング発掘の抑止（`showFeelingDiscovery`）
/// は不要になった。常に 3 セグメントを表示する。
///
/// 17e: [HomeContentModeSelectorCollapse] で包むと、本文の縦スクロール量に
/// 連動して高さが縮む（省スペース化）。本物の SliverAppBar + floating は
/// ボディ構造の載せ替えが大きすぎるため、PreferredSize の高さをアニメーション
/// させる形で等価な体感を実現する。
class HomeContentModeSelector extends StatelessWidget {
  const HomeContentModeSelector({
    super.key,
    required this.currentIndex,
    required this.onModeSelected,
  });

  /// 現在選択中のモードインデックス
  /// （[PixivViewerHomeState.illustIndex] / [PixivViewerHomeState.novelIndex] /
  /// [PixivViewerHomeState.feelingDiscoveryIndex] のいずれか）。
  final int currentIndex;

  /// モードが選択されたときに呼ばれる。`changeTab` に渡す。
  final ValueChanged<int> onModeSelected;

  /// AppBar の `bottom` に指定するための推定高さ。
  ///
  /// 実高さはテキストスケールに依存するため、実測（テスト）を最優先するが、
  /// PreferredSize が小さすぎると中身が AppBar にめり込むので
  /// 安全側（大きめ）に取る。
  static const double preferredHeight = 64;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'コンテンツ種別の切り替え',
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding,
          vertical: AppSpacing.sm,
        ),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: PixivViewerHomeState.illustIndex,
              icon: Icon(Icons.image_outlined),
              label: Text('イラスト'),
            ),
            ButtonSegment(
              value: PixivViewerHomeState.novelIndex,
              icon: Icon(Icons.book_outlined),
              label: Text('小説'),
            ),
            ButtonSegment(
              value: PixivViewerHomeState.feelingDiscoveryIndex,
              icon: Icon(Icons.auto_awesome_outlined),
              label: Text('フィーリング発掘'),
            ),
          ],
          selected: {currentIndex},
          onSelectionChanged: (selection) => onModeSelected(selection.first),
        ),
      ),
    );
  }
}

/// 17e: [HomeContentModeSelector] を包み、縦スクロール量に応じて高さを縮める。
///
/// [AppBar.bottom] には [PreferredSizeWidget] しか指定できないため、
/// [SizeTransition] を直接は渡せない。このラッパーが [PreferredSize] の
/// `preferredSize.height` をアニメーション値に合わせて縮めることで、
/// セレクターが「スクロールで隠れる」体感を与える。完全に折りたたまれた
/// 状態でもタッチ判定が残らないよう、高さ 0 のときは自身を描画しない。
class HomeContentModeSelectorCollapse extends StatelessWidget
    implements PreferredSizeWidget {
  const HomeContentModeSelectorCollapse({
    super.key,
    required this.collapse,
    required this.currentIndex,
    required this.onModeSelected,
  });

  /// 折りたたみ量（0.0 = 展開 / 1.0 = 完全に折りたたみ）。
  final Animation<double> collapse;

  final int currentIndex;

  final ValueChanged<int> onModeSelected;

  @override
  Size get preferredSize => Size.fromHeight(
    (1.0 - collapse.value) * HomeContentModeSelector.preferredHeight,
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: collapse,
      builder: (context, child) {
        final height =
            (1.0 - collapse.value) * HomeContentModeSelector.preferredHeight;
        return SizedBox(
          height: height,
          child: ClipRect(
            child: OverflowBox(
              minHeight: HomeContentModeSelector.preferredHeight,
              maxHeight: HomeContentModeSelector.preferredHeight,
              alignment: Alignment.topCenter,
              child: child!,
            ),
          ),
        );
      },
      child: HomeContentModeSelector(
        currentIndex: currentIndex,
        onModeSelected: onModeSelected,
      ),
    );
  }
}
