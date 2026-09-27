import 'package:flutter/material.dart';

import '../screens/home_screen_state.dart';
import '../theme/app_spacing.dart';

/// ホームのコンテンツ種別（イラスト / 小説 / フィーリング発掘）を
/// 選ぶセグメントコントロール（Phase 16c-2a / 17c / 17h）。
///
/// 16c-1 までは [Scaffold.bottomNavigationBar] の [NavigationBar] が
/// この役割だった。16c-2 で殻（[AppShell]）がボトムナビを所有するため、
/// コンテンツ種別の切替は AppBar の UI へ移動した。
///
/// - 選択値・切替の判定は全て [PixivViewerHomeState] が持つため、
///   この Widget は状態を持たない（新しい状態を増やさない）。
/// - ラベル・アイコン・セグメント順は旧 [NavigationBar] と同一。
/// - 選択中アイコンは表示しない（`showSelectedIcon: false`）。
///
/// 17c: 検索目的地を削除してフィーリング発掘の抑止（`showFeelingDiscovery`）
/// は不要になった。常に 3 セグメントを表示する。
///
/// 17h: 17e の「スクロール連動の折りたたみ」は実機で不安定だったため撤回した
/// （[HomeContentModeSelectorCollapse] は削除）。代わりに `compact: true` で
/// [AppBar.title] の右側に常駐する小型ピルを追加した。スクロールに連動する
/// 動きを持たないので、モード切替は常に到達可能で、検索バー・本文は
/// 最初から上に詰まる。
class HomeContentModeSelector extends StatelessWidget {
  const HomeContentModeSelector({
    super.key,
    required this.currentIndex,
    required this.onModeSelected,
    this.compact = false,
  });

  /// 現在選択中のモードインデックス
  /// （[PixivViewerHomeState.illustIndex] / [PixivViewerHomeState.novelIndex] /
  /// [PixivViewerHomeState.feelingDiscoveryIndex] のいずれか）。
  final int currentIndex;

  /// モードが選択されたときに呼ばれる。`changeTab` に渡す。
  final ValueChanged<int> onModeSelected;

  /// 17h: [AppBar.title] の行内に収まる小型表示か。
  ///
  /// `false` のときは AppBar 直下の標準セグメント（ラベルは完全名）。
  /// `true` のときは高さ [compactHeight] のピルで、ラベルは1文字に短縮するが
  /// [Tooltip] / Semantics には完全名を保持する。
  final bool compact;

  /// 標準モードの推定高（テストの実測を最優先するが、安全側の目安）。
  static const double preferredHeight = 64;

  /// compact モードの高さ。48 は Android タップターゲットの最小基準。
  /// （compact でも基準を満たすことで、テストの tap-target 検証を弱めない）
  static const double compactHeight = 48;

  /// 17h: compact モードで使う短縮ラベル（UI 上の表示のみ）。
  static const Map<int, String> _compactLabels = {
    PixivViewerHomeState.illustIndex: '絵',
    PixivViewerHomeState.novelIndex: '文',
    PixivViewerHomeState.feelingDiscoveryIndex: '感',
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'コンテンツ種別の切り替え',
      child: Padding(
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
                vertical: AppSpacing.sm,
              ),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          // compact 時ははみ出しを防ぐため小さくする。
          style: compact
              ? const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity(horizontal: -3, vertical: -3),
                )
              : null,
          segments: [
            for (final (index, label, icon) in [
              (PixivViewerHomeState.illustIndex, 'イラスト', Icons.image_outlined),
              (PixivViewerHomeState.novelIndex, '小説', Icons.book_outlined),
              (
                PixivViewerHomeState.feelingDiscoveryIndex,
                'フィーリング発掘',
                Icons.auto_awesome_outlined,
              ),
            ])
              ButtonSegment<int>(
                value: index,
                icon: Icon(icon),
                // compact では1文字に短縮するが、Tooltip で完全名を保持する。
                label: Tooltip(
                  message: label,
                  child: Text(compact ? _compactLabels[index]! : label),
                ),
              ),
          ],
          selected: {currentIndex},
          onSelectionChanged: (selection) => onModeSelected(selection.first),
        ),
      ),
    );
  }
}
