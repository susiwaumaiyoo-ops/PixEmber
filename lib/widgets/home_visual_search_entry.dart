import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import 'design_system/app_panel.dart';

/// 検索ワークスペース内の「似た画像を探す」導線（Phase 16c-3c）。
///
/// 従来は Drawer の項目だった [VisualSearchScreen] への導線を
/// 検索サーフェスに置き直す。既存の文言をそのまま再利用する:
///
/// - title: 「似た画像を探す」
/// - subtitle: 「画像の特徴から近い作品を検索」
///
/// 本ウィジェットは導線の表示とタップのコールバックだけを担い、
/// 検索ロジック・API 呼び出しは一切持たない（画面の push も
/// 呼び出し元 ([PixivViewerHomeState._openVisualSearch]) が行う）。
class HomeVisualSearchEntry extends StatelessWidget {
  const HomeVisualSearchEntry({super.key, required this.onTap});

  /// 導線がタップされたときの処理（[VisualSearchScreen] の push）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: AppPanel(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(Icons.image_search, color: colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('似た画像を探す', style: TextStyle(fontSize: 15)),
                  Text('画像の特徴から近い作品を検索', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
