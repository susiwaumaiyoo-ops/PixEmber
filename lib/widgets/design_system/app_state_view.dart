import 'package:flutter/material.dart';

/// empty / error / loading の統一表示（Phase 16b-2a）。
///
/// 画面ごとにスタイルがばらついていた空状態・エラー・ローディング表示を
/// 統一する。ビジネス例外やAPIサービスは内部で扱わない。
enum AppStateViewType { empty, error, loading }

class AppStateView extends StatelessWidget {
  const AppStateView({
    super.key,
    required this.type,
    this.icon,
    this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.centered = true,
  });

  /// 表示種別。
  final AppStateViewType type;

  /// 任意のアイコン。未指定時は種別の既定値。
  final IconData? icon;

  /// 任意のタイトル。
  final String? title;

  /// 任意のメッセージ。
  final String? message;

  /// action ボタンのラベル。[onAction] とともに指定した場合のみ表示。
  final String? actionLabel;

  /// action ボタンのコールバック。[actionLabel] とともに指定した場合のみ表示。
  final VoidCallback? onAction;

  /// true（既定）で画面中央寄せ。リスト内配置等では false を指定。
  final bool centered;

  IconData get _defaultIcon {
    switch (type) {
      case AppStateViewType.empty:
        return Icons.inbox_outlined;
      case AppStateViewType.error:
        return Icons.error_outline;
      case AppStateViewType.loading:
        return Icons.hourglass_empty;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final isloading = type == AppStateViewType.loading;
    final isError = type == AppStateViewType.error;

    final content = Column(
      mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
      mainAxisAlignment: centered
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (isloading)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: CircularProgressIndicator(color: colorScheme.primary),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Icon(
              icon ?? _defaultIcon,
              size: 48,
              color: isError ? colorScheme.error : colorScheme.onSurfaceVariant,
            ),
          ),
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              title!,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurface,
              ),
            ),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              message!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (actionLabel != null && onAction != null)
          FilledButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );

    if (!centered) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: content,
      );
    }
    return Center(
      child: Padding(padding: const EdgeInsets.all(20), child: content),
    );
  }
}
