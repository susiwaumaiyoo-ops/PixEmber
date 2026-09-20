import 'package:flutter/material.dart';

import '../utils/home_search_ui_mode.dart';
import 'home_screen_state.dart';

/// Phase 3: コンテンツソース切替チップ（おすすめ / 新着 / フォロー / ブックマーク）。
///
/// - ソース切替時はキーワード検索結果を破棄して閲覧モードへ
/// - ランキングはチップに出さずサブモード(2)として別導線で共存させる
/// - 未ログインでフォロー/ブックマークを選んだ場合はクラッシュせずログイン誘導
/// - 16c-4a: 末尾に「AIレコメンド」導線チップを追加（旧 Drawer からの移設）。
///   これは [HomeContentSource] ではなく別画面への push 導線。
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
        itemCount: sources.length + 1,
        itemBuilder: (ctx, idx) {
          // 16c-4a: 末尾の要素は AIレコメンド導線チップ（選択状態を持たない）。
          if (idx == sources.length) {
            return _AiRecommendChip(
              colorScheme: colorScheme,
              onTap: state.openAiRecommendFeed,
            );
          }
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

/// 16c-4a: ホームのソースチップ列末尾に置く AIレコメンド導線チップ。
///
/// [HomeContentSource] とは無関係に [AiRecommendFeedScreen] へ push する
/// 導線専用（フィードの差し替えは行わない）。
class _AiRecommendChip extends StatelessWidget {
  const _AiRecommendChip({required this.colorScheme, required this.onTap});

  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: ChoiceChip(
        avatar: Icon(Icons.auto_awesome, size: 14, color: colorScheme.primary),
        label: Text(
          'AIレコメンド',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
        ),
        selected: false,
        backgroundColor: colorScheme.surfaceContainerHighest,
        elevation: 0,
        side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.4)),
        onSelected: (sel) => onTap(),
      ),
    );
  }
}
