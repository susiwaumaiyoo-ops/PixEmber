import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';

/// ダウンロードキュー管理画面
///
/// 永続化されたダウンロードジョブ（download_queue_groups / download_queues）を
/// 一覧表示し、以下を提供する:
/// - ジョブのステータス・進捗・エラー理由表示
/// - 個別操作: 一時停止 / 再開 / キャンセル / リトライ
/// - 全体操作: 全停止 / リトライ全 / 完了クリア
/// - ストレージ使用量（downloaded_illust の件数 + novel_text の容量）
///
/// Web ではダウンロード不可（DownloadService.enqueueXxx が null を返す）。
/// この画面自体はキュー状態の閲覧・操作が可能。
class DownloadQueueScreen extends StatefulWidget {
  const DownloadQueueScreen({super.key});

  @override
  State<DownloadQueueScreen> createState() => _DownloadQueueScreenState();
}

class _DownloadQueueScreenState extends State<DownloadQueueScreen> {
  List<Map<String, dynamic>> _groups = [];
  bool _isLoading = true;
  int _completedCount = 0;
  int _novelCacheBytes = 0;
  final DownloadService _svc = DownloadService();

  @override
  void initState() {
    super.initState();
    _setupCallbacks();
    _load();
  }

  void _setupCallbacks() {
    _svc.onProgress = (groupId, pageCompleted, pageTotal, progress) {
      // 進捗が変わったら再描画（デバウンスは Future.microtask 相当で十分軽量）
      if (mounted) _scheduleRefresh();
    };
    _svc.onComplete = (groupId, workId, workType) {
      if (mounted) _scheduleRefresh();
    };
    _svc.onError = (groupId, workId, workType, errorCode, errorMessage) {
      if (mounted) _scheduleRefresh();
    };
  }

  bool _refreshScheduled = false;
  void _scheduleRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    try {
      final db = DatabaseService();
      final groups = await db.getDownloadQueueGroups();
      final completed = await _svc.completedCount;
      final novelBytes = await db.getCachedNovelTextsTotalBytes();
      if (mounted) {
        setState(() {
          _groups = groups;
          _completedCount = completed;
          _novelCacheBytes = novelBytes;
        });
      }
    } catch (e) {
      debugPrint('ダウンロードキュー一覧の読み込みに失敗: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pauseGroup(int groupId) async {
    await _svc.pauseGroup(groupId);
    _load();
  }

  Future<void> _resumeGroup(int groupId) async {
    await _svc.resumeGroup(groupId);
    _load();
  }

  Future<void> _cancelGroup(int groupId, String title) async {
    final confirmed = await _confirmDialog(
      title: 'ダウンロードをキャンセル',
      content: '「$title」のダウンロードをキャンセルし、保存済みファイルを削除しますか？',
    );
    if (confirmed != true) return;
    try {
      await _svc.cancelGroup(groupId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('キャンセルしました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('キャンセルに失敗: $e')));
      }
    }
    _load();
  }

  Future<void> _retryGroup(int groupId) async {
    await _svc.retryGroup(groupId);
    _load();
  }

  Future<void> _stopAll() async {
    await _svc.stopAll();
    _load();
  }

  Future<void> _retryAll() async {
    for (final g in _groups) {
      final status = g['status'] as String?;
      if (status == 'failed' || status == 'canceled') {
        await _svc.retryGroup(g['id'] as int);
      }
    }
    _load();
  }

  Future<void> _clearFinished() async {
    final confirmed = await _confirmDialog(
      title: '完了済みをクリア',
      content: '完了・失敗・キャンセル済みのジョブを全て削除しますか？',
    );
    if (confirmed != true) return;
    await _svc.clearFinished();
    _load();
  }

  Future<bool?> _confirmDialog({
    required String title,
    required String content,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'pending':
        return Icons.schedule;
      case 'running':
        return Icons.downloading;
      case 'paused':
        return Icons.pause_circle_outline;
      case 'completed':
        return Icons.check_circle;
      case 'failed':
        return Icons.error_outline;
      case 'canceled':
        return Icons.cancel;
      default:
        return Icons.help_outline;
    }
  }

  Color _statusColor(String status, ThemeData theme) {
    switch (status) {
      case 'completed':
        return Colors.green;
      case 'failed':
        return Colors.red;
      case 'canceled':
        return Colors.grey;
      case 'running':
        return theme.colorScheme.primary;
      case 'paused':
        return Colors.orange;
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'pending':
        return '待機中';
      case 'running':
        return 'ダウンロード中';
      case 'paused':
        return '一時停止';
      case 'completed':
        return '完了';
      case 'failed':
        return '失敗';
      case 'canceled':
        return 'キャンセル';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ダウンロードキュー'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '再読込',
            onPressed: _load,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'stop_all':
                  _stopAll();
                  break;
                case 'retry_all':
                  _retryAll();
                  break;
                case 'clear_finished':
                  _clearFinished();
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'stop_all',
                child: ListTile(
                  leading: Icon(Icons.stop),
                  title: Text('全て停止'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: 'retry_all',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('失敗を全てリトライ'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: 'clear_finished',
                child: ListTile(
                  leading: Icon(Icons.delete_sweep),
                  title: Text('完了済みをクリア'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : kIsWeb
          ? _buildWebUnsupported()
          : _groups.isEmpty
          ? _buildEmpty(theme)
          : _buildList(theme, isDark),
    );
  }

  Widget _buildWebUnsupported() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Web版ではダウンロードできません',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'この環境ではファイル保存がサポートされていません。\n'
              'ネイティブアプリ（Android / iOS / デスクトップ）でご利用ください。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_done,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text('ダウンロードキューは空です', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'イラスト詳細画面や小説詳細画面から\nダウンロードできます',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme, bool isDark) {
    return Column(
      children: [
        _buildSummary(theme),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              itemCount: _groups.length,
              itemBuilder: (ctx, index) {
                final group = _groups[index];
                return _buildGroupTile(group, theme);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummary(ThemeData theme) {
    final pending = _groups
        .where((g) => g['status'] == 'pending' || g['status'] == 'running')
        .length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Row(
        children: [
          const Icon(Icons.download, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'キュー: $pending 件 / 完了: $_completedCount 件',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (_novelCacheBytes > 0)
            Text(
              '小説キャッシュ: ${_formatBytes(_novelCacheBytes)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGroupTile(Map<String, dynamic> group, ThemeData theme) {
    final groupId = group['id'] as int;
    final status = (group['status'] as String?) ?? 'pending';
    final title = (group['title'] as String?) ?? 'タイトル不明';
    final authorName = (group['author_name'] as String?) ?? '';
    final workId = (group['work_id'] as int?) ?? 0;
    final pageTotal = (group['page_total'] as int?) ?? 1;
    final pageCompleted = (group['page_completed'] as int?) ?? 0;
    final errorCode = group['error_code'] as String?;
    final errorMessage = group['error_message'] as String?;
    final retryCount = (group['retry_count'] as int?) ?? 0;
    final maxRetry = (group['max_retry'] as int?) ?? 3;

    final progress = pageTotal > 0 ? pageCompleted / pageTotal : 0.0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ヘッダー行: アイコン + タイトル + ステータス
            Row(
              children: [
                Icon(
                  _statusIcon(status),
                  color: _statusColor(status, theme),
                  size: 28,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '[${group['work_type'] ?? 'illust'}] #$workId'
                        '${authorName.isNotEmpty ? ' · $authorName' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    _statusLabel(status),
                    style: TextStyle(
                      color: _statusColor(status, theme),
                      fontSize: 12,
                    ),
                  ),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 進捗バー
            if (status == 'running' ||
                status == 'pending' ||
                status == 'paused')
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: status == 'running' ? null : progress,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$pageCompleted / $pageTotal ページ'
                    '${status == 'running' ? ' (ダウンロード中...)' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else if (status == 'completed')
              Text(
                '$pageTotal ページ完了',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else if (status == 'failed')
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'エラー: ${errorCode ?? "unknown"}'
                    '${errorMessage != null && errorMessage.isNotEmpty ? " - $errorMessage" : ""}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.red,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (retryCount > 0)
                    Text(
                      'リトライ: $retryCount / $maxRetry',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            // 操作ボタン
            const SizedBox(height: 8),
            _buildActionButtons(groupId, status, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(int groupId, String status, ThemeData theme) {
    final buttons = <Widget>[];

    switch (status) {
      case 'pending':
      case 'running':
        buttons.add(
          _actionButton(
            icon: Icons.pause,
            label: '一時停止',
            onTap: () => _pauseGroup(groupId),
            theme: theme,
          ),
        );
        buttons.add(
          _actionButton(
            icon: Icons.cancel,
            label: 'キャンセル',
            onTap: () => _cancelGroup(groupId, ''),
            theme: theme,
            destructive: true,
          ),
        );
        break;
      case 'paused':
        buttons.add(
          _actionButton(
            icon: Icons.play_arrow,
            label: '再開',
            onTap: () => _resumeGroup(groupId),
            theme: theme,
          ),
        );
        buttons.add(
          _actionButton(
            icon: Icons.cancel,
            label: 'キャンセル',
            onTap: () => _cancelGroup(groupId, ''),
            theme: theme,
            destructive: true,
          ),
        );
        break;
      case 'failed':
        buttons.add(
          _actionButton(
            icon: Icons.refresh,
            label: 'リトライ',
            onTap: () => _retryGroup(groupId),
            theme: theme,
          ),
        );
        buttons.add(
          _actionButton(
            icon: Icons.delete,
            label: '削除',
            onTap: () => _cancelGroup(groupId, ''),
            theme: theme,
            destructive: true,
          ),
        );
        break;
      case 'canceled':
        buttons.add(
          _actionButton(
            icon: Icons.refresh,
            label: '再ダウンロード',
            onTap: () => _retryGroup(groupId),
            theme: theme,
          ),
        );
        buttons.add(
          _actionButton(
            icon: Icons.delete,
            label: '削除',
            onTap: () => _cancelGroup(groupId, ''),
            theme: theme,
            destructive: true,
          ),
        );
        break;
      case 'completed':
        buttons.add(
          _actionButton(
            icon: Icons.delete_outline,
            label: 'リストから削除',
            onTap: () async {
              await DownloadService().cancelGroup(groupId);
              _load();
            },
            theme: theme,
          ),
        );
        break;
    }

    return Wrap(spacing: 8, runSpacing: 4, children: buttons);
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required ThemeData theme,
    bool destructive = false,
  }) {
    final color = destructive ? Colors.red : theme.colorScheme.primary;
    return ActionChip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label, style: TextStyle(color: color)),
      onPressed: onTap,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
