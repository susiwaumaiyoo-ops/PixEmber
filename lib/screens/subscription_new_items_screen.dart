import 'package:flutter/material.dart';

import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';
import '../utils/datetime_format.dart';
import '../widgets/pixiv_image.dart';
import 'illust_detail_state.dart';
import 'novel_detail_screen.dart';

/// 購読タグ 1 件の「新着作品一覧」画面。
///
/// subscription_new_items（新着チェック時に保存されたキャッシュ）を表示する。
/// - サムネイルは pixiv_image.dart 経由（Referer 付き）で表示する。
/// - 日時は utils/datetime_format.dart の共通フォーマットを使う。
/// - mutes テーブル（tag/user ミュート）と x_restrict によるフィルタを適用する。
class SubscriptionNewItemsScreen extends StatefulWidget {
  final int subscribedTagId;
  final String tagName;

  const SubscriptionNewItemsScreen({
    super.key,
    required this.subscribedTagId,
    required this.tagName,
  });

  @override
  State<SubscriptionNewItemsScreen> createState() =>
      _SubscriptionNewItemsScreenState();
}

class _SubscriptionNewItemsScreenState
    extends State<SubscriptionNewItemsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = false;
  bool _showR18 = false;
  // ミュートされた作者名（mutes の mute_type='user' の label/value）
  Set<String> _mutedAuthors = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final db = DatabaseService();
      final rows = await db.getSubscriptionNewItems(widget.subscribedTagId);
      final mutes = await db.getMutesList();
      final muted = <String>{};
      for (final m in mutes) {
        if (m['mute_type'] == 'user') {
          final label = m['label']?.toString();
          final value = m['value']?.toString();
          if (label != null && label.isNotEmpty) muted.add(label);
          if (value != null && value.isNotEmpty) muted.add(value);
        }
      }
      if (!mounted) return;
      setState(() {
        _items = rows;
        _mutedAuthors = muted;
      });
    } catch (e) {
      _showSnackBar('新着作品の読み込みに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// ミュート・x_restrict を反映した表示対象。
  List<Map<String, dynamic>> get _visibleItems => _items.where((it) {
    final xr = (it['x_restrict'] as int?) ?? 0;
    if (!_showR18 && xr > 0) return false;
    final author = it['author_name']?.toString() ?? '';
    if (author.isNotEmpty && _mutedAuthors.contains(author)) return false;
    return true;
  }).toList();

  Future<void> _markAllRead() async {
    try {
      await DatabaseService().markAllSubscriptionNewItemsRead(
        widget.subscribedTagId,
      );
      await _load();
      _showSnackBar('すべて既読にしました');
    } catch (e) {
      _showSnackBar('既読処理に失敗しました: $e');
    }
  }

  Future<void> _openItem(Map<String, dynamic> item) async {
    final int? rowId = item['id'] as int?;
    final int? workId = item['work_id'] as int?;
    final String type = item['type']?.toString() ?? 'illust';
    if (workId == null) return;

    // 遷移時に既読化
    if (rowId != null) {
      try {
        await DatabaseService().markSubscriptionNewItemRead(rowId);
      } catch (_) {
        // 既読化の失敗は遷移を妨げない
      }
    }

    try {
      final api = PixivApiService();
      if (type == 'novel') {
        final novel = await api.getNovelById(workId);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
        );
      } else {
        final illust = await api.getIllustById(workId);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => IllustDetailScreen(illust: illust)),
        );
      }
    } catch (e) {
      _showSnackBar('作品の取得に失敗しました: $e');
    }
    await _load();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.pink.shade700),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _visibleItems;
    return Scaffold(
      appBar: AppBar(
        title: Text('新着: ${widget.tagName}'),
        actions: [
          IconButton(
            tooltip: _showR18 ? 'R-18 を隠す' : 'R-18 を表示',
            icon: Icon(_showR18 ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showR18 = !_showR18),
          ),
          IconButton(
            tooltip: 'すべて既読にする',
            icon: const Icon(Icons.done_all),
            onPressed: _items.isEmpty ? null : _markAllRead,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) => _buildItemTile(items[index]),
              ),
            ),
    );
  }

  Widget _buildItemTile(Map<String, dynamic> item) {
    final isRead = ((item['is_read'] as int?) ?? 0) == 1;
    final url = item['preview_url']?.toString() ?? '';
    final title = item['title']?.toString() ?? '無題';
    final author = item['author_name']?.toString() ?? '';
    final created = DateTimeFormat.formatReadable(
      item['create_date']?.toString(),
    );
    final isNovel = item['type']?.toString() == 'novel';

    return ListTile(
      leading: SizedBox(
        width: 56,
        height: 56,
        child: url.isEmpty
            ? Container(
                color: Colors.grey.shade800,
                child: Icon(
                  isNovel ? Icons.menu_book : Icons.image,
                  color: Colors.white54,
                ),
              )
            // Referer 付き画像表示（pixiv_image の仕組み）
            : PixivImage(url: url, isThumbnail: true, fit: BoxFit.cover),
      ),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
          color: isRead ? Colors.grey : null,
        ),
      ),
      subtitle: Text('$author ・ $created'),
      trailing: isRead
          ? null
          : const Icon(Icons.circle, size: 10, color: Colors.pinkAccent),
      onTap: () => _openItem(item),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox, size: 64, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            const Text(
              '表示できる新着作品はありません',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _items.isEmpty
                  ? '購読タグ画面で新着チェックを実行すると、ここに新着作品が表示されます。'
                  : 'ミュート設定または R-18 フィルタにより全件が非表示になっています。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
