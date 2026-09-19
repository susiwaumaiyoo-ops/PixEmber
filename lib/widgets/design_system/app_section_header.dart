import 'package:flutter/material.dart';

/// セクション見出し（Phase 16b-2a）。
///
/// 画面ごとに微妙に異なっていた見出しのスタイル（bodySmall+bold / fontSize 13
/// 直書き / titleSmall 等）を統一する。上下余白は内部で過剰に持たず、
/// 親側から [AppSpacing.sectionGap] 等を指定可能。
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader(
    this.title, {
    super.key,
    this.icon,
    this.subtitle,
    this.trailing,
    this.padding,
  });

  /// 必須の見出しテキスト。
  final String title;

  /// 任意のアイコン（タイトルの左）。
  final IconData? icon;

  /// 任意のサブテキスト（タイトルの下、onSurfaceVariant）。
  final String? subtitle;

  /// 任意の右側Widget（アイコンボタン等）。
  final Widget? trailing;

  /// 外側余白。未指定時はなし（親側で sectionGap を指定する）。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final header = Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );

    return header;
  }
}
