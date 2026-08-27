import 'dart:async';

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:pixiv_viewer/services/google_drive_service.dart';
import 'package:pixiv_viewer/utils/datetime_format.dart';

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
                ? TextButton.styleFrom(foregroundColor: Colors.red)
                : null,
            child: Text(okLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          Container(
            padding: const EdgeInsets.all(16),
            color: isDark ? Colors.grey[850] : Colors.grey[100],
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loggedIn ? 'Google アカウント接続済み' : 'Google アカウント未連携',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (loggedIn && _drive.userEmail != null)
                        Text(
                          _drive.userEmail!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.backup),
                  label: const Text('今すぐバックアップ'),
                  onPressed: (_isProcessing || !loggedIn)
                      ? (_isProcessing ? null : () => _promptSignIn())
                      : _createBackup,
                ),
              ],
            ),
          ),
          if (_lastActionMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.green.withValues(alpha: 0.1),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_lastActionMessage!)),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _lastActionMessage = null),
                  ),
                ],
              ),
            ),
          if (_errorMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.red.withValues(alpha: 0.1),
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _errorMessage = null),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(child: _buildBody(loggedIn, isDark)),
        ],
      ),
    );
  }

  Widget _buildBody(bool loggedIn, bool isDark) {
    if (!loggedIn) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.account_circle, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Google アカウントに連携してください'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isProcessing ? null : _promptSignIn,
              child: const Text('Google アカウント連携'),
            ),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_backups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadBackups,
        child: ListView(
          children: const [
            SizedBox(height: 80),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('バックアップがまだありません'),
                  SizedBox(height: 8),
                  Text('上部の「今すぐバックアップ」から作成できます'),
                ],
              ),
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
            leading: const Icon(Icons.backup, color: Colors.pinkAccent),
            title: Text(file.name ?? 'バックアップ'),
            subtitle: Text(
              '${_formatDate(file.modifiedTime)} ・ ${_formatSize(file.size)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.restore, color: Colors.blue),
                  tooltip: '復元',
                  onPressed: (_isProcessing || _isLoading)
                      ? null
                      : () => _restoreBackup(file),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
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
