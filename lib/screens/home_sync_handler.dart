import 'home_screen_state.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        // signIn() が null/false を返した場合（OAuth クライアント未設定など）は
        // 例外ではなく黙って失敗するため、原因を明示する
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'ログインできませんでした。Google Cloud Console で '
              'OAuth クライアント（パッケージ名 com.example.pixiv_viewer ＋ '
              '署名鍵の SHA-1）の登録と Drive API の有効化が必要です。',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('ログイン失敗：$e')));
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
    if (state.loggedInEmail == null) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: Colors.teal.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
        ),
        child: ListTile(
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.cloud_upload,
              color: Colors.tealAccent,
              size: 24,
            ),
          ),
          title: const Text(
            'Google ドライブ同期（パーソナルクラウド）',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: const Text(
            '履歴・お気に入り・購読データをクラウドで管理',
            style: TextStyle(color: Colors.white60, fontSize: 11),
          ),
          trailing: const Icon(
            Icons.arrow_forward_ios,
            color: Colors.white54,
            size: 16,
          ),
          onTap: _handleGoogleLogin,
        ),
      );
    }

    // 最終同期日時のフォーマット
    String? lastSyncDisplay;
    if (state.lastSyncTimestamp != null) {
      try {
        final dt = DateTime.parse(state.lastSyncTimestamp!).toLocal();
        lastSyncDisplay =
            '最終同期: ${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {
        lastSyncDisplay = '最終同期: ${state.lastSyncTimestamp}';
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ヘッダー：アカウント情報
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.1),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.teal.withValues(alpha: 0.2),
                  child: const Icon(
                    Icons.person,
                    color: Colors.tealAccent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ログイン中',
                        style: TextStyle(
                          color: Colors.tealAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        state.loggedInEmail!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
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

          const SizedBox(height: 12),

          // 説明テキスト + 最終同期日時
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '履歴・フォルダ・購読タグを Google ドライブ（appDataFolder）と同期',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
                if (lastSyncDisplay != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    lastSyncDisplay,
                    style: TextStyle(
                      color: Colors.tealAccent.withValues(alpha: 0.8),
                      fontSize: 11,
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
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.tealAccent.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '前回の復元結果',
                      style: TextStyle(
                        color: Colors.tealAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: state.lastSyncSummary!.entries.map((e) {
                        return Text(
                          '${e.key}: +${e.value}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 12),

          // ボタン行：バックアップ / 復元
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                // クラウドにバックアップ（送信）
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: state.isBackingUp || state.isRestoring
                        ? null
                        : _handleGoogleBackup,
                    icon: state.isBackingUp
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Icon(Icons.cloud_upload, size: 18),
                    label: Text(
                      state.isBackingUp ? 'バックアップ中...' : 'クラウドにバックアップ（送信）',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.isBackingUp
                          ? Colors.teal.withValues(alpha: 0.6)
                          : Colors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // クラウドから復元（受信）
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: state.isBackingUp || state.isRestoring
                        ? null
                        : _handleGoogleRestore,
                    icon: state.isRestoring
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Icon(Icons.cloud_download, size: 18),
                    label: Text(
                      state.isRestoring ? 'データマージ中...' : 'クラウドから復元（受信）',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.isRestoring
                          ? Colors.blue.withValues(alpha: 0.6)
                          : Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
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

          const SizedBox(height: 12),

          // ログアウトボタン
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: state.isBackingUp || state.isRestoring
                    ? null
                    : _handleGoogleLogout,
                icon: const Icon(Icons.logout, color: Colors.white54, size: 18),
                label: const Text(
                  'ログアウト',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
