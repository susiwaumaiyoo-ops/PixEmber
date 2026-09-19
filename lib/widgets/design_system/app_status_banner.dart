import 'package:flutter/material.dart';

/// info / success / warning / error の軽量通知（Phase 16b-2a）。
///
/// 画面内に常駐させる状態表示用。SnackBar の代替ではない。
/// 各状態は対応する container/onContainer ペアを使用する。
enum AppStatusType { info, success, warning, error }

class AppStatusBanner extends StatelessWidget {
  const AppStatusBanner({
    super.key,
    required this.type,
    required this.title,
    this.message,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.margin,
  });

  /// 種別（色ペアの決定に使用）。
  final AppStatusType type;

  /// 必須のタイトル。
  final String title;

  /// 任意のメッセージ。
  final String? message;

  /// 任意のアイコン。未指定時は種別の既定値。
  final IconData? icon;

  /// action のラベル。[onAction] とともに指定した場合のみ表示。
  final String? actionLabel;

  /// action のコールバック。[actionLabel] とともに指定した場合のみ表示。
  final VoidCallback? onAction;

  /// 外側余白。未指定時はなし。
  final EdgeInsetsGeometry? margin;

  IconData get _defaultIcon {
    switch (type) {
      case AppStatusType.info:
        return Icons.info_outline;
      case AppStatusType.success:
        return Icons.check_circle_outline;
      case AppStatusType.warning:
        return Icons.warning_amber_outlined;
      case AppStatusType.error:
        return Icons.error_outline;
    }
  }

  ({Color container, Color onContainer, Color icon}) _colors(
    ColorScheme scheme,
  ) {
    switch (type) {
      case AppStatusType.info:
        return (
          container: scheme.surfaceContainerHighest,
          onContainer: scheme.onSurface,
          icon: scheme.onSurfaceVariant,
        );
      case AppStatusType.success:
        return (
          container: scheme.secondaryContainer,
          onContainer: scheme.onSecondaryContainer,
          icon: scheme.secondary,
        );
      case AppStatusType.warning:
        return (
          container: scheme.tertiaryContainer,
          onContainer: scheme.onTertiaryContainer,
          icon: scheme.tertiary,
        );
      case AppStatusType.error:
        return (
          container: scheme.errorContainer,
          onContainer: scheme.onErrorContainer,
          icon: scheme.error,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _colors(theme.colorScheme);

    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? _defaultIcon, size: 20, color: colors.icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    message!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onContainer,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(
                actionLabel!,
                style: TextStyle(color: colors.onContainer),
              ),
            ),
        ],
      ),
    );

    final banner = Material(
      color: colors.container,
      elevation: 0,
      borderRadius: BorderRadius.circular(16),
      child: content,
    );

    if (margin == null) return banner;
    return Padding(padding: margin!, child: banner);
  }
}
