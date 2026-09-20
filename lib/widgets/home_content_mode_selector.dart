import 'package:flutter/material.dart';

import '../screens/home_screen_state.dart';
import '../theme/app_spacing.dart';

/// ホームのコンテンツ種別（イラスト / 小説 / フィーリング発掘）を
/// 選ぶセグメントコントロール（Phase 16c-2a）。
///
/// 16c-1 までは [Scaffold.bottomNavigationBar] の [NavigationBar] が
/// この役割だった。16c-2 で殻（[AppShell]）がボトムナビを所有するため、
/// コンテンツ種別の切替は AppBar 直下の二位置 UI へ移動した。
///
/// - 選択値・切替の判定は全て [PixivViewerHomeState] が持つため、
///   この Widget は状態を持たない（新しい状態を増やさない）。
/// - ラベル・アイコン・セグメント順は旧 [NavigationBar] と同一。
/// - 選択中アイコンは表示しない（`showSelectedIcon: false`）。
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
