import 'dart:async';

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:pixiv_viewer/services/google_drive_service.dart';
import 'package:pixiv_viewer/theme/app_spacing.dart';
import 'package:pixiv_viewer/utils/datetime_format.dart';
import 'package:pixiv_viewer/widgets/design_system/app_state_view.dart';
import 'package:pixiv_viewer/widgets/design_system/app_status_banner.dart';
import 'package:pixiv_viewer/widgets/design_system/app_success_check.dart';

/// Google Drive バックアップ管理画面。
///
/// - 複数バックアップの一覧表示（ファイル名・作成日時・サイズ）
/// - 各バックアップの復元 / 削除（いずれも確認ダイアログ必須）
/// - プルリフレッシュ
/// - 上部の「今すぐバックアップ」ボタン（タイムスタンプ付き新規作成）
/// - ログイン状態・ロード中・空・エラー・処理中の各状態
class BackupManagerScreen extends StatefulWidget {
  const BackupManagerScreen({super.key});

  @override
  State<BackupManagerScreen> createState() => _BackupManagerScreenState();
}

class _BackupManagerScreenState extends State<BackupManagerScreen> {
  final GoogleDriveService _drive = GoogleDriveService();

  List<drive.File> _backups = <drive.File>[];
  bool _isLoading = false;
  bool _isProcessing = false;
  String? _errorMessage;
  String? _lastActionMessage;

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    if (!_drive.isLoggedIn) {
      final ok = await _safeRun(() => _drive.signInSilently());
      if (ok != true) {
        // 未ログインはそのまま表示（ログインプロンプトを出す）
        if (mounted) setState(() {});
        return;
      }
    }
    await _loadBackups();
  }

  Future<void> _loadBackups() async {
    if (_isLoading || _isProcessing) return;
    if (!_drive.isLoggedIn) {
      if (mounted) {
        setState(() {
          _backups = <drive.File>[];
          _errorMessage = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }
    try {
      final list = await _drive.listBackups();
      if (mounted) {
        setState(() {
          _backups = list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'バックアップ一覧の取得に失敗しました: $e';
        });
      }
    }
  }

  /// 例外をキャッチして null を返す安全実行ヘルパ。
  Future<T?> _safeRun<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'エラー: $e');
      }
      return null;
    }
  }

  String _formatSize(String? size) {
    if (size == null) return 'サイズ不明';
    final bytes = int.tryParse(size);
    if (bytes == null) return 'サイズ不明';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime? dt) =>
      DateTimeFormat.formatReadable(dt?.toIso8601String());

  Future<void> _createBackup() async {
    if (_isProcessing) return;
    if (!_drive.isLoggedIn) {
      await _promptSignIn();
      return;
    }
    final confirmed = await _confirmDialog(
      title: '今すぐバックアップ',
      content: '現在のブックマーク・履歴・設定を新しいバックアップとして保存します。よろしいですか？',
      okLabel: 'バックアップ',
    );
    if (confirmed != true) return;

    if (mounted) setState(() => _isProcessing = true);
    try {
      await _drive.backupNamed();
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _lastActionMessage = 'バックアップを作成しました';
        });
      }
      await _loadBackups();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _errorMessage = 'バックアップ作成に失敗しました: $e';
        });
      }
    }
  }

  Future<void> _restoreBackup(drive.File file) async {
    if (_isProcessing) return;
    final id = file.id;
    if (id == null) return;
    final confirmed = await _confirmDialog(
      title: 'このバックアップから復元',
      content:
          '「${file.name ?? 'バックアップ'}」からデータを復元します。\n\n現在のローカルデータはバックアップの内容で上書き（マージ）されます。続行しますか？',
      okLabel: '復元する',
      isDanger: true,
    );
    if (confirmed != true) return;

    if (mounted) setState(() => _isProcessing = true);
    try {
      final result = await _drive.restoreFromId(id);
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _lastActionMessage = result != null
              ? '復元が完了しました（小説: ${result['novels'] ?? 0} 件 等）'
              : '復元が完了しました';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _errorMessage = '復元に失敗しました: $e';
        });
      }
    }
  }

  Future<void> _deleteBackup(drive.File file) async {
    if (_isProcessing) return;
    final id = file.id;
    if (id == null) return;
    final confirmed = await _confirmDialog(
      title: 'バックアップを削除',
      content:
          '「${file.name ?? 'バックアップ'}」を削除します。\n\n削除したバックアップは元に戻せません。本当に削除しますか？',
      okLabel: '削除する',
      isDanger: true,
    );
    if (confirmed != true) return;

    if (mounted) setState(() => _isProcessing = true);
    try {
      await _drive.deleteBackup(id);
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _lastActionMessage = 'バックアップを削除しました';
        });
      }
      await _loadBackups();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _errorMessage = '削除に失敗しました: $e';
        });
      }
    }
  }

  Future<void> _promptSignIn() async {
    final confirmed = await _confirmDialog(
      title: 'Google アカウント連携',
      content: 'バックアップを操作するには Google アカウントへの連携が必要です。連携しますか？',
      okLabel: '連携する',
    );
    if (confirmed != true) return;
    final ok = await _safeRun(() => _drive.signIn());
    if (ok == true) {
      await _loadBackups();
    } else {
      if (mounted) setState(() => _errorMessage = 'Google アカウントへの連携に失敗しました');
    }
  }

  Future<bool?> _confirmDialog({
    required String title,
    required String content,
    required String okLabel,
    bool isDanger = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: isDanger
                ? TextButton.styleFrom(foregroundColor: colorScheme.error)
                : null,
            child: Text(okLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final loggedIn = _drive.isLoggedIn;

    return Scaffold(
      appBar: AppBar(
        title: const Text('バックアップ管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: (_isLoading || _isProcessing) ? null : _loadBackups,
          ),
        ],
      ),
      body: Column(
        children: [
          // 上部: サインイン状態 + 今すぐバックアップ
          AppStatusBanner(
            type: loggedIn ? AppStatusType.success : AppStatusType.info,
            title: loggedIn ? 'Google アカウント接続済み' : 'Google アカウント未連携',
            message: loggedIn ? _drive.userEmail : null,
            margin: const EdgeInsets.all(AppSpacing.lg),
          ),
          if (loggedIn)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.backup),
                  label: const Text('今すぐバックアップ'),
                  onPressed: _isProcessing ? null : _createBackup,
                ),
              ),
            ),
          if (_lastActionMessage != null)
            AppStatusBanner(
              type: AppStatusType.success,
              title: _lastActionMessage!,
              leading: AppSuccessCheck(
                size: 20,
                visible: _lastActionMessage != null,
              ),
              margin: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
            ),
          if (_errorMessage != null)
            AppStatusBanner(
              type: AppStatusType.error,
              title: _errorMessage!,
              margin: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
            ),
          const Divider(height: 1),
          Expanded(child: _buildBody(loggedIn, colorScheme)),
        ],
      ),
    );
  }

  Widget _buildBody(bool loggedIn, ColorScheme colorScheme) {
    if (!loggedIn) {
      return AppStateView(
        type: AppStateViewType.empty,
        icon: Icons.account_circle,
        title: 'Google アカウントに連携してください',
        actionLabel: 'Google アカウント連携',
        onAction: _isProcessing ? null : _promptSignIn,
      );
    }

    if (_isLoading) {
      return const AppStateView(type: AppStateViewType.loading);
    }

    if (_backups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadBackups,
        child: ListView(
          children: [
            const SizedBox(height: 80),
            AppStateView(
              type: AppStateViewType.empty,
              icon: Icons.cloud_off,
              title: 'バックアップがまだありません',
              message: '上部の「今すぐバックアップ」から作成できます',
              centered: false,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadBackups,
      child: ListView.separated(
        itemCount: _backups.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final file = _backups[index];
          return ListTile(
            leading: Icon(Icons.backup, color: colorScheme.primary),
            title: Text(file.name ?? 'バックアップ'),
            subtitle: Text(
              '${_formatDate(file.modifiedTime)} ・ ${_formatSize(file.size)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.restore, color: colorScheme.tertiary),
                  tooltip: '復元',
                  onPressed: (_isProcessing || _isLoading)
                      ? null
                      : () => _restoreBackup(file),
                ),
                IconButton(
                  icon: Icon(Icons.delete, color: colorScheme.error),
                  tooltip: '削除',
                  onPressed: (_isProcessing || _isLoading)
                      ? null
                      : () => _deleteBackup(file),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
