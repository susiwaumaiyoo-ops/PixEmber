import 'package:flutter/material.dart';

import '../../theme/app_spacing.dart';

/// フラットなコンテンツ面（Phase 16b-2a）。
///
/// 背景 [ColorScheme.surfaceContainer]・枠 [ColorScheme.outlineVariant] 1px・
/// elevation 0・角丸 20・既定 padding [AppSpacing.cardPadding]。
/// [onTap] がある場合のみ InkWell を持ち、それ以外は装飾を持たない
/// 汎用の「面」として振る舞う。ビジネスロジックは持たない。
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.margin,
    this.radius,
    this.borderColor,
    this.backgroundColor,
  });

  /// 面の内容。
  final Widget child;

  /// 指定した場合のみ InkWell を持つ（タップフィードバックが必要な面）。
  final VoidCallback? onTap;

  /// 内側余白。未指定時は [AppSpacing.cardPadding]。
  final EdgeInsetsGeometry? padding;

  /// 外側余白。未指定時はなし。
  final EdgeInsetsGeometry? margin;

  /// 角丸。未指定時は 20。
  final double? radius;

  /// 枠色。未指定時は [ColorScheme.outlineVariant]。
  final Color? borderColor;

  /// 背景色。未指定時は [ColorScheme.surfaceContainer]。
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final r = radius ?? 20;

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(r),
      side: BorderSide(color: borderColor ?? colorScheme.outlineVariant),
    );

    final content = Padding(
      padding: padding ?? const EdgeInsets.all(AppSpacing.cardPadding),
      child: child,
    );

    final panel = Material(
      color: backgroundColor ?? colorScheme.surfaceContainer,
      elevation: 0,
      shape: shape,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );

    if (margin == null) return panel;
    return Padding(padding: margin!, child: panel);
  }
}
