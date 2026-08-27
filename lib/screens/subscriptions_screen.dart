import 'package:flutter/material.dart';

import '../services/database_service.dart';
import '../services/subscription_sync_service.dart';
import 'subscription_new_items_screen.dart';

/// ローカル購読タグ一覧画面。
///
/// 旧実装（subscriptions_screen.dart）は外部バックエンド（Python サーバー）の
/// host を受け取り /api/subscriptions* を http 呼び出ししていたが、本画面は
/// それを削除し、Flutter/Dart 単体で端末内 SQLite（subscribed_tags テーブル）
/// から購読タグを管理する。Python サーバーや host 指定は一切持たない。
///
/// フェーズ2 で「新着チェック機能」を追加: 各タグごとに Pixiv 検索（新着順）を
/// 呼び出し、前回チェック時点より新しい作品数を last_new_count に記録する。
class SubscriptionsScreen extends StatefulWidget {
  /// タップ時に親（ホーム画面）でタグ検索を実行するためのコールバック (tag, type)。
  final Function(String, String)? onTagSelected;

  const SubscriptionsScreen({super.key, this.onTagSelected});

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  List<Map<String, dynamic>> _tags = [];
  bool _isLoading = false;
  bool _isSyncing = false;
  final Map<int, bool> _checking = {};
  final Map<int, String?> _errors = {};

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  Future<void> _loadTags() async {
    setState(() => _isLoading = true);
    try {
      final rows = await DatabaseService().getSubscribedTags();
      if (mounted) {
        setState(() => _tags = rows);
      }
    } catch (e) {
      _showSnackBar('購読タグの読み込みに失敗しました: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _removeTag(Map<String, dynamic> tag) async {
    final int? id = tag['id'] as int?;
    if (id == null) return;
    final String name = tag['tag']?.toString() ?? '';
    try {
      await DatabaseService().removeSubscribedTag(id);
      if (mounted) {
        setState(() {
          _tags.removeWhere((element) => element['id'] == id);
          _checking.remove(id);
          _errors.remove(id);
        });
      }
      _showSnackBar('「$name」の購読を解除しました');
    } catch (e) {
      _showSnackBar('購読解除に失敗しました: $e');
    }
  }

  Map<String, dynamic>? _findTag(int id) {
    for (final t in _tags) {
      if (t['id'] == id) return t;
    }
    return null;
  }

  void _updateTagRow(SubscriptionSyncOneResult r) {
    final idx = _tags.indexWhere((t) => t['id'] == r.id);
    if (idx >= 0) {
      _tags[idx] = {
        ..._tags[idx],
        'last_checked_at': r.lastCheckedAt,
        'last_newest_date': r.lastNewestDate,
        'last_new_count': r.newCount,
      };
    }
  }

  /// 全タグの新着チェックを実行する。
  Future<void> _syncAll() async {
    if (_isSyncing || _tags.isEmpty) return;
    setState(() {
      _isSyncing = true;
      _errors.clear();
      for (final t in _tags) {
        final id = t['id'] as int?;
        if (id != null) _checking[id] = true;
      }
    });
    final summary = await SubscriptionSyncService().syncAll(
      _tags,
      onResult: (r) {
        if (!mounted) return;
        setState(() {
          _checking[r.id] = false;
          if (r.success) {
            _updateTagRow(r);
          } else {
            _errors[r.id] = r.errorMessage;
          }
        });
      },
    );
    if (!mounted) return;
    setState(() => _isSyncing = false);
    _showSnackBar(
      summary.error == 0
          ? '新着チェック完了：新着 ${summary.totalNew} 件'
          : 'チェック完了（${summary.error}件失敗）：新着 ${summary.totalNew} 件',
    );
  }

  /// 単一タグの再試行。
  Future<void> _syncOne(int id) async {
    final tag = _findTag(id);
    if (tag == null) return;
    setState(() {
      _checking[id] = true;
      _errors.remove(id);
    });
    final r = await SubscriptionSyncService().checkTag(tag);
    if (!mounted) return;
    setState(() {
      _checking[id] = false;
      if (r.success) {
        _updateTagRow(r);
      } else {
        _errors[id] = r.errorMessage;
      }
    });
  }

  Future<void> _onTagTap(Map<String, dynamic> tag) async {
    final int? id = tag['id'] as int?;
    final String name = tag['tag']?.toString() ?? '';
    final String type = tag['type']?.toString() ?? 'illust';
    if (name.isEmpty) return;

    // 未読の新着キャッシュがある場合は、従来の検索連携の代わりに
    // 新着作品一覧画面へ遷移する（既存UXの検索フローを壊さず、かつ
    // 新着フィードへ即座にアクセスできるよう分岐させる）。
    if (id != null) {
      final unread = await DatabaseService().getSubscriptionUnreadCountByTag();
      final count = unread[id] ?? 0;
      if (count > 0) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                SubscriptionNewItemsScreen(subscribedTagId: id, tagName: name),
          ),
        );
        // 戻った際にバッジ等へ反映させるため親へ通知は行わず、
        // 必要に応じてスナックバー等は出さない。
        return;
      }
    }

    widget.onTagSelected?.call(name, type);
    if (!mounted) return;
    Navigator.pop(context); // ホームへ戻り、親側で検索を実行
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.pink.shade700),
    );
  }

  String _formatCreatedAt(String? createdAt) {
    if (createdAt == null || createdAt.isEmpty) return '日付不明';
    try {
      final dt = DateTime.parse(createdAt).toLocal();
      final y = dt.year;
      final m = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$y/$m/$d $hh:$mm';
    } catch (_) {
      return createdAt;
    }
  }

  IconData _typeIcon(String type) {
    switch (type) {
      case 'novel':
        return Icons.menu_book;
      case 'illust':
      default:
        return Icons.palette;
    }
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'novel':
        return Colors.orangeAccent;
      case 'illust':
      default:
        return Colors.blueAccent;
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'novel':
        return '小説';
      case 'illust':
      default:
        return 'イラスト';
    }
  }

  /// タグ行の新着チェック状態を表示する。
  Widget _buildStatusLine(Map<String, dynamic> tag) {
    final int? id = tag['id'] as int?;
    final bool checking = id != null && (_checking[id] ?? false);
    final String? error = id != null ? _errors[id] : null;
    final int newCount = (tag['last_new_count'] as int? ?? 0);
    final String? lastChecked = tag['last_checked_at'] as String?;

    if (checking) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: const [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.pinkAccent,
              ),
            ),
            SizedBox(width: 6),
            Text('確認中...', style: TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 12, color: Colors.redAccent),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'チェック失敗',
                style: TextStyle(color: Colors.redAccent, fontSize: 11),
              ),
            ),
            if (id != null)
              InkWell(
                onTap: () => _syncOne(id),
                child: const Text(
                  '再試行',
                  style: TextStyle(
                    color: Colors.pinkAccent,
                    fontSize: 11,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.update, size: 12, color: Colors.grey.shade500),
          const SizedBox(width: 4),
          Text(
            lastChecked == null || lastChecked.isEmpty
                ? '未チェック'
                : '最終: ${_formatCreatedAt(lastChecked)}',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
          ),
          if (newCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.pinkAccent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '新着 $newCount',
                style: const TextStyle(
                  color: Colors.pinkAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('購読タグ'),
        backgroundColor: const Color(0xFF1A1A1A),
        actions: [
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.pinkAccent,
                    ),
                  )
                : const Icon(Icons.autorenew),
            onPressed: _isSyncing || _tags.isEmpty ? null : _syncAll,
            tooltip: '全タグ新着チェック',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading || _isSyncing ? null : _loadTags,
            tooltip: 'リスト更新',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.pinkAccent),
            )
          : _tags.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              onRefresh: _syncAll,
              color: Colors.pinkAccent,
              child: ListView.separated(
                padding: const EdgeInsets.all(12.0),
                itemCount: _tags.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final tag = _tags[index];
                  final String name = tag['tag']?.toString() ?? '';
                  final String type = tag['type']?.toString() ?? 'illust';
                  final String createdAt = _formatCreatedAt(
                    tag['created_at']?.toString(),
                  );

                  return Card(
                    color: const Color(0xFF1E1E1E),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: _typeColor(type).withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Dismissible(
                      key: Key('sub_tag_${tag['id']}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(
                          Icons.delete_outline,
                          color: Colors.redAccent,
                        ),
                      ),
                      confirmDismiss: (direction) async {
                        return await _confirmRemove(name);
                      },
                      onDismissed: (_) => _removeTag(tag),
                      child: InkWell(
                        onTap: () => _onTagTap(tag),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 12.0,
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: _typeColor(
                                  type,
                                ).withValues(alpha: 0.2),
                                radius: 20,
                                child: Icon(
                                  _typeIcon(type),
                                  color: _typeColor(type),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _typeColor(
                                              type,
                                            ).withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            _typeLabel(type),
                                            style: TextStyle(
                                              color: _typeColor(type),
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Icon(
                                          Icons.access_time_filled,
                                          size: 12,
                                          color: Colors.grey.shade500,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '登録: $createdAt',
                                          style: TextStyle(
                                            color: Colors.grey.shade400,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                    _buildStatusLine(tag),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                ),
                                tooltip: '購読解除',
                                onPressed: () =>
                                    _confirmRemove(name).then((ok) {
                                      if (ok == true) _removeTag(tag);
                                    }),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.stars_outlined, size: 80, color: Colors.pink.shade200),
            const SizedBox(height: 16),
            const Text(
              '購読中のタグはありません',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'イラスト・小説の詳細画面でタグを長押しすると、\nこの端末内（ローカル）に購読タグとして保存できます。\nタップでそのタグの検索ができます。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmRemove(String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF252525),
          title: const Text('購読の解除', style: TextStyle(color: Colors.white)),
          content: Text(
            '「$name」の購読を解除しますか？',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                '解除する',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    );
  }
}
