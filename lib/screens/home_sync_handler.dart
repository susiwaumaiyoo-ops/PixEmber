import 'home_screen_state.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/google_drive_service.dart';
import '../theme/app_spacing.dart';
import '../utils/datetime_format.dart';

/// Googleドライブ同期関連メソッドを管理するクラス
class HomeSyncHandler {
  final PixivViewerHomeState state;

  HomeSyncHandler(this.state);

  // ローディングダイアログの表示
  void _showLoadingDialog() {
    showDialog(
      context: state.uiContext,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );
  }

  // ローディングダイアログの非表示
  void _hideLoadingDialog(NavigatorState navigator) {
    navigator.pop();
  }

  // Google ドライブへのバックアップ
  Future<void> _handleGoogleBackup() async {
    final navigator = Navigator.of(state.uiContext, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(state.uiContext);
    state.applyState(() => state.isBackingUp = true);
    _showLoadingDialog();
    try {
      final success = await state.driveService.backupJSON();
      _hideLoadingDialog(navigator);
      state.applyState(() => state.isBackingUp = false);
      if (success) {
        final now = DateTime.now().toIso8601String();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('GOOGLE_DRIVE_LAST_SYNC', now);
        state.applyState(() => state.lastSyncTimestamp = now);
        messenger.showSnackBar(const SnackBar(content: Text('バックアップ完了しました！')));
      }
    } catch (e) {
      _hideLoadingDialog(navigator);
      state.applyState(() => state.isBackingUp = false);
      messenger.showSnackBar(SnackBar(content: Text('バックアップ失敗：$e')));
    }
  }

  // Google ドライブからの復元
  Future<void> _handleGoogleRestore() async {
    final navigator = Navigator.of(state.uiContext, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(state.uiContext);
    state.applyState(() => state.isRestoring = true);
    _showLoadingDialog();
    try {
      final summary = await state.driveService.restoreJSON();
      _hideLoadingDialog(navigator);
      state.applyState(() => state.isRestoring = false);
      if (summary != null) {
        final now = DateTime.now().toIso8601String();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('GOOGLE_DRIVE_LAST_SYNC', now);
        state.applyState(() {
          state.lastSyncTimestamp = now;
          state.lastSyncSummary = summary;
        });
        final totalAdded = summary.values.fold<int>(0, (sum, v) => sum + v);
        messenger.showSnackBar(
          SnackBar(content: Text('復元完了しました！追加/更新：$totalAdded 件')),
        );
      }
    } catch (e) {
      _hideLoadingDialog(navigator);
      state.applyState(() => state.isRestoring = false);
      messenger.showSnackBar(SnackBar(content: Text('復元失敗：$e')));
    }
  }

  // Google ドライブへのログイン
  Future<void> _handleGoogleLogin() async {
    final messenger = ScaffoldMessenger.of(state.uiContext);
    try {
      await state.driveService.signIn();
      if (state.driveService.isLoggedIn) {
        state.applyState(() {
          state.loggedInEmail = state.driveService.signedInEmail;
        });
        messenger.showSnackBar(
          const SnackBar(content: Text('Google ドライブにログインしました')),
        );
      } else {
        // null 返却（キャンセル）/ 例外による失敗のいずれでも、
        // 実エラー（code/message/details）から短い診断を生成して表示する。
        final msg =
            'Googleドライブログイン失敗：'
            '${describeSignInError(state.driveService.lastSignInError)}';
        messenger.showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 8)),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('ログイン失敗：${describeSignInError(e)}'),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  // Google ドライブからのログアウト
  Future<void> _handleGoogleLogout() async {
    await state.driveService.signOut();
    if (state.isMounted) {
      state.applyState(() {
        state.loggedInEmail = null;
      });
    }
  }

  // Googleドライブ同期セクションのUI
  Widget buildGoogleDriveSyncSection() {
    final theme = Theme.of(state.uiContext);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    if (state.loggedInEmail == null) {
      return Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: colorScheme.secondary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.secondary.withValues(alpha: 0.3),
          ),
        ),
        child: ListTile(
          leading: Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: colorScheme.secondary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.cloud_upload,
              color: colorScheme.secondary,
              size: 24,
            ),
          ),
          title: Text(
            'Google ドライブ同期（パーソナルクラウド）',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: Text(
            '履歴・お気に入り・購読データをクラウドで管理',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: Icon(
            Icons.arrow_forward_ios,
            color: colorScheme.onSurfaceVariant,
            size: 16,
          ),
          onTap: _handleGoogleLogin,
        ),
      );
    }

    // 最終同期日時のフォーマット（Phase 10b: 共通 DateTimeFormat に集約）
    String? lastSyncDisplay;
    if (state.lastSyncTimestamp != null) {
      final formatted = DateTimeFormat.formatReadable(state.lastSyncTimestamp);
      lastSyncDisplay = formatted.isEmpty ? null : '最終同期: $formatted';
    }

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.secondary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー：アカウント情報
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: colorScheme.secondary.withValues(alpha: 0.1),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: colorScheme.secondary.withValues(alpha: 0.2),
                  child: Icon(
                    Icons.person,
                    color: colorScheme.secondary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ログイン中',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.secondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        state.loggedInEmail!,
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          // 説明テキスト + 最終同期日時
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '履歴・フォルダ・購読タグを Google ドライブ（appDataFolder）と同期',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (lastSyncDisplay != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    lastSyncDisplay,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.secondary.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 前回の同期サマリー表示
          if (state.lastSyncSummary != null &&
              state.lastSyncSummary!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: colorScheme.secondary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colorScheme.secondary.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '前回の復元結果',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.md,
                      runSpacing: AppSpacing.xs,
                      children: state.lastSyncSummary!.entries.map((e) {
                        return Text(
                          '${e.key}: +${e.value}',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: AppSpacing.md),

          // ボタン行：バックアップ / 復元
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: [
                // クラウドにバックアップ（送信）
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: state.isBackingUp || state.isRestoring
                        ? null
                        : _handleGoogleBackup,
                    icon: state.isBackingUp
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                colorScheme.onSecondary,
                              ),
                            ),
                          )
                        : const Icon(Icons.cloud_upload, size: 18),
                    label: Text(
                      state.isBackingUp ? 'バックアップ中...' : 'クラウドにバックアップ（送信）',
                      style: textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.isBackingUp
                          ? colorScheme.secondary.withValues(alpha: 0.6)
                          : colorScheme.secondary,
                      foregroundColor: colorScheme.onSecondary,
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.md,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                // クラウドから復元（受信）
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: state.isBackingUp || state.isRestoring
                        ? null
                        : _handleGoogleRestore,
                    icon: state.isRestoring
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                colorScheme.onTertiary,
                              ),
                            ),
                          )
                        : const Icon(Icons.cloud_download, size: 18),
                    label: Text(
                      state.isRestoring ? 'データマージ中...' : 'クラウドから復元（受信）',
                      style: textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.isRestoring
                          ? colorScheme.tertiary.withValues(alpha: 0.6)
                          : colorScheme.tertiary,
                      foregroundColor: colorScheme.onTertiary,
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.md,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          // ログアウトボタン
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: state.isBackingUp || state.isRestoring
                    ? null
                    : _handleGoogleLogout,
                icon: Icon(
                  Icons.logout,
                  color: colorScheme.onSurfaceVariant,
                  size: 18,
                ),
                label: Text(
                  'ログアウト',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: colorScheme.outlineVariant),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}
