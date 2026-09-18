import 'package:flutter/material.dart';

import '../utils/home_search_ui_mode.dart';
import 'home_screen_state.dart';

/// Phase 3: コンテンツソース切替チップ（おすすめ / 新着 / フォロー / ブックマーク）。
///
/// - ソース切替時はキーワード検索結果を破棄して閲覧モードへ
/// - ランキングはチップに出さずサブモード(2)として別導線で共存させる
/// - 未ログインでフォロー/ブックマークを選んだ場合はクラッシュせずログイン誘導
class HomeSearchSourceChips extends StatelessWidget {
  const HomeSearchSourceChips({super.key, required this.state});

  final PixivViewerHomeState state;

  @override
  Widget build(BuildContext context) {
    const sources = HomeContentSource.values;
    // ランキング・検索結果中は選択なし（null）で表示する。
    final selected = state.activeContentSource;
    final colorScheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: sources.length,
        itemBuilder: (ctx, idx) {
          final source = sources[idx];
          final isSelected = source == selected;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: ChoiceChip(
                label: Text(
                  source.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected
                        ? colorScheme.onPrimary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
                selected: isSelected,
                selectedColor: colorScheme.primary.withValues(alpha: 0.35),
                backgroundColor: colorScheme.surfaceContainerHighest,
                elevation: isSelected ? 2 : 0,
                side: BorderSide(
                  color: isSelected
                      ? colorScheme.primary.withValues(alpha: 0.6)
                      : Colors.transparent,
                ),
                onSelected: (sel) {
                  if (!sel) return;
                  state.onContentSourceSelected(source);
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
