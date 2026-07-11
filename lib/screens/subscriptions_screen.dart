import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SubscriptionsScreen extends StatefulWidget {
  final String host;
  final Function(String, String)
  onTagSelected; // タップ時にホーム画面などでタグ検索を実行するためのコールバック (tagName, type)

  const SubscriptionsScreen({
    super.key,
    required this.host,
    required this.onTagSelected,
  });

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  List<dynamic> _subscriptions = [];
  bool _isLoading = false;
  bool _isSyncing = false;

  // バックグラウンド同期進捗状態
  Timer? _statusTimer;
  bool _isSyncRunning = false;
  int _syncTotal = 0;
  int _syncProgress = 0;
  String _syncStatusMessage = '';

  @override
  void initState() {
    super.initState();
    _fetchSubscriptions();
    _startStatusPolling(); // 起動時に実行中の同期があれば追跡する
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  // 同期状況のポーリング開始
  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      try {
        final response = await http.get(
          Uri.parse('${widget.host}/api/subscriptions/sync/status'),
        );
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final bool isRunning = data['is_running'] ?? false;
          final int total = data['total'] ?? 0;
          final int progress = data['progress'] ?? 0;
          final String statusMessage = data['status_message'] ?? '';

          if (mounted) {
            setState(() {
              _isSyncRunning = isRunning;
              _syncTotal = total;
              _syncProgress = progress;
              _syncStatusMessage = statusMessage;

              if (isRunning) {
                _isSyncing = true;
              }
            });
          }

          if (!isRunning) {
            timer.cancel();
            if (mounted) {
              setState(() {
                _isSyncing = false;
              });
              _fetchSubscriptions(); // 完了したらリストを最新化
            }
          }
        }
      } catch (e) {
        // サイレントにキャッチ（ポーリングなので一時的なエラーは無視）
      }
    });
  }

  // 購読タグ一覧を取得
  Future<void> _fetchSubscriptions() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final response = await http.get(
        Uri.parse('${widget.host}/api/subscriptions'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          if (!mounted) return;
          setState(() {
            _subscriptions = data['subscriptions'] ?? [];
          });
        }
      } else {
        _showSnackBar('購読タグ一覧の取得に失敗しました (HTTP ${response.statusCode})');
      }
    } catch (e) {
      _showSnackBar('通信エラーが発生しました: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 購読解除
  Future<void> _removeSubscription(String tagName, String type) async {
    try {
      final response = await http.post(
        Uri.parse('${widget.host}/api/subscriptions/remove'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'tag_name': tagName, 'type': type}),
      );
      if (response.statusCode == 200) {
        _showSnackBar('「$tagName」の購読を解除しました');
        _fetchSubscriptions();
      } else {
        _showSnackBar('購読解除に失敗しました (HTTP ${response.statusCode})');
      }
    } catch (e) {
      _showSnackBar('通信エラーが発生しました: $e');
    }
  }

  // 単一タグ同期
  Future<void> _syncSingle(int tagId, String tagName) async {
    setState(() {
      _isSyncing = true;
    });
    _showSnackBar(
      '「$tagName」のバックグラウンド同期を開始しました。',
      duration: const Duration(seconds: 2),
    );

    try {
      final response = await http.post(
        Uri.parse('${widget.host}/api/subscriptions/sync?tag_id=$tagId'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _showSnackBar(data['message'] ?? '同期処理を開始しました');
        _startStatusPolling(); // ポーリングを開始してUIを追跡
      } else {
        _showSnackBar('同期のトリガーに失敗しました (HTTP ${response.statusCode})');
      }
    } catch (e) {
      _showSnackBar('通信エラーが発生しました: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  // 全タグ一括同期
  Future<void> _syncAll() async {
    if (_subscriptions.isEmpty) {
      _showSnackBar('購読中のタグがありません');
      return;
    }
    setState(() {
      _isSyncing = true;
    });
    _showSnackBar(
      '全タグの一括バックグラウンド同期を開始しました。',
      duration: const Duration(seconds: 2),
    );

    try {
      final response = await http.post(
        Uri.parse('${widget.host}/api/subscriptions/sync'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _showSnackBar(data['message'] ?? '一括同期処理を開始しました');
        _startStatusPolling(); // ポーリングを開始してUIを追跡
      } else {
        _showSnackBar('一括同期のトリガーに失敗しました (HTTP ${response.statusCode})');
      }
    } catch (e) {
      _showSnackBar('通信エラーが発生しました: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  void _showSnackBar(
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        backgroundColor: Colors.pink.shade700,
      ),
    );
  }

  String _formatEpoch(int? epochSeconds) {
    if (epochSeconds == null || epochSeconds == 0) return '未同期';
    final dt = DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
    ).toLocal();
    final y = dt.year;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y/$m/$d $hh:$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('購読タグ自動同期・新着検知'),
        backgroundColor: const Color(0xFF1A1A1A),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _fetchSubscriptions,
            tooltip: 'リスト更新',
          ),
          if (_subscriptions.isNotEmpty)
            ElevatedButton.icon(
              onPressed: _isSyncing ? null : _syncAll,
              icon: const Icon(Icons.sync_alt, size: 16),
              label: const Text('すべて同期'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.pinkAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (_isSyncRunning)
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.pink.withValues(alpha: 0.1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _syncStatusMessage.isNotEmpty
                              ? _syncStatusMessage
                              : '同期中...',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        '${_syncTotal > 0 ? ((_syncProgress / _syncTotal) * 100).toStringAsFixed(0) : 0}% ($_syncProgress/$_syncTotal)',
                        style: const TextStyle(
                          color: Colors.pinkAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _syncTotal > 0 ? (_syncProgress / _syncTotal) : 0.0,
                    backgroundColor: Colors.grey.shade800,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.pinkAccent,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.pinkAccent),
                  )
                : _subscriptions.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.all(12.0),
                    itemCount: _subscriptions.length,
                    itemBuilder: (context, index) {
                      final sub = _subscriptions[index];
                      final int tagId = sub['id'];
                      final String tagName = sub['tag_name'] ?? '';
                      final String type = sub['type'] ?? 'illust';
                      final int? lastSynced = sub['last_synced_at'];
                      final int? latestId = sub['latest_work_id'];

                      final isIllust = type == 'illust';

                      return Card(
                        color: const Color(0xFF1E1E1E),
                        margin: const EdgeInsets.symmetric(vertical: 6.0),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isIllust
                                ? Colors.blue.withValues(alpha: 0.3)
                                : Colors.orange.withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                        child: InkWell(
                          onTap: () {
                            // タップしたら、このタグで即座にオフライン同等の高速キャッシュ検索を実行
                            widget.onTagSelected(tagName, type);
                            Navigator.pop(context); // 画面を閉じて検索結果へ戻る
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                              vertical: 12.0,
                            ),
                            child: Row(
                              children: [
                                // 種類アイコン
                                CircleAvatar(
                                  backgroundColor: isIllust
                                      ? Colors.blue.withValues(alpha: 0.2)
                                      : Colors.orange.withValues(alpha: 0.2),
                                  radius: 20,
                                  child: Icon(
                                    isIllust ? Icons.palette : Icons.menu_book,
                                    color: isIllust
                                        ? Colors.blueAccent
                                        : Colors.orangeAccent,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                // タグ名とステータス
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tagName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.access_time_filled,
                                            size: 12,
                                            color: Colors.grey.shade500,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '最終同期: ${_formatEpoch(lastSynced)}',
                                            style: TextStyle(
                                              color: Colors.grey.shade400,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (latestId != null &&
                                          latestId != 0) ...[
                                        const SizedBox(height: 2),
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.new_releases,
                                              size: 12,
                                              color: Colors.pinkAccent.shade100,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              '最新検知ID: $latestId',
                                              style: TextStyle(
                                                color: Colors.pink.shade100,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                // アクションボタン
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.sync,
                                        color: Colors.blueAccent,
                                      ),
                                      tooltip: 'このタグを同期',
                                      onPressed: _isSyncing
                                          ? null
                                          : () => _syncSingle(tagId, tagName),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.redAccent,
                                      ),
                                      tooltip: '購読解除',
                                      onPressed: () =>
                                          _showRemoveDialog(tagName, type),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
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
              'イラスト・小説の詳細画面から\nお気に入りのタグを「購読」登録すると、\n24時間サーバーがバックグラウンドで自動同期します。',
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

  void _showRemoveDialog(String tagName, String type) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF252525),
          title: const Text('購読の解除', style: TextStyle(color: Colors.white)),
          content: Text(
            '「$tagName」の購読を解除しますか？\nバックグラウンド自動同期の対象から外れます。',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _removeSubscription(tagName, type);
              },
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
