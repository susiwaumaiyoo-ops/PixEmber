import 'package:flutter/material.dart';
import '../novel_model.dart';
import '../illust_model.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import 'novel_reader_screen.dart';
import '../utils/datetime_format.dart';

/// オフライン本棚画面
///
/// DB 内の小説本文キャッシュ（novel_text）を一覧表示し、
/// オフラインで小説リーダーを開けるよう導線を提供する。
/// またキャッシュ容量の確認・古いキャッシュの一括削除・個別スワイプ削除が可能。
class OfflineBookshelfScreen extends StatefulWidget {
  const OfflineBookshelfScreen({super.key});

  @override
  State<OfflineBookshelfScreen> createState() => _OfflineBookshelfScreenState();
}

class _OfflineBookshelfScreenState extends State<OfflineBookshelfScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = true;
  int _totalBytes = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      // 整合性検証: 外部アプリによるファイル削除を検出し DB を修復
      try {
        final repaired = await DownloadService().integrityCheck();
        if (repaired > 0 && mounted) {
          debugPrint('オフライン本棚: $repaired 件の欠損ファイルを検出・修復');
        }
      } catch (e) {
        debugPrint('整合性検証に失敗（続行）: $e');
      }

      final db = DatabaseService();
      final items = await db.getCachedNovelTexts();
      final total = await db.getCachedNovelTextsTotalBytes();
      if (mounted) {
        setState(() {
          _items = items;
          _totalBytes = total;
        });
      }
    } catch (e) {
      debugPrint('オフライン本棚の読み込みに失敗: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// キャッシュ行から小説を開く。novels メタデータがあればそこから完全な Novel を
  /// 構築し、なければキャッシュ行の最小情報から Novel を組み立てる（オフライン対応）。
  Future<void> _openItem(Map<String, dynamic> item) async {
    final workId = item['work_id'] as int;
    final db = DatabaseService();
    Novel? novel = await db.getNovelMeta(workId);
    // 最小メタデータでオフライン用 Novel を構築
    novel ??= Novel(
      id: workId,
      title: (item['title'] as String?) ?? 'タイトル不明',
      caption: '',
      author: Author(
        id: 0,
        name: (item['author_name'] as String?) ?? '作者不明',
        account: '',
      ),
      tags: const [],
      coverUrl: '',
      textCount: 0,
      wordCount: (item['char_count'] as int?) ?? 0,
      textLength: (item['char_count'] as int?) ?? 0,
      pageCount: 1,
      createDate: '',
      totalView: 0,
      totalBookmarks: 0,
      isBookmarked: false,
    );
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NovelReaderScreen(novel: novel!)),
    );
    // 閲覧後は削除等で件数が変わる可能性があるため再読込
    _load();
  }

  Future<void> _deleteItem(int workId) async {
    try {
      await DatabaseService().deleteCachedNovelText(workId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('キャッシュを削除しました')));
      }
    } catch (e) {
      debugPrint('キャッシュ削除に失敗: $e');
    }
    _load();
  }

  Future<void> _deleteOld(int days) async {
    final count = await DatabaseService().deleteOldCachedNovelTexts(
      beforeDays: days,
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$count 件のキャッシュを削除しました')));
    }
    _load();
  }

  String _formatMB(int bytes) {
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('オフライン本棚'),
        backgroundColor: isDark ? const Color(0xFF222222) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 0.5,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.cleaning_services),
            tooltip: 'キャッシュ整理',
            onSelected: (value) {
              if (value == '30') {
                _confirmDelete(() => _deleteOld(30), '30日以上前のキャッシュをすべて削除しますか？');
              } else if (value == 'all') {
                _confirmDelete(() => _deleteOld(0), 'すべてのキャッシュを削除しますか？');
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: '30', child: Text('30日以上前のキャッシュを削除')),
              PopupMenuItem(value: 'all', child: Text('すべて削除')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade100,
            child: Text(
              'キャッシュ数: ${_items.length} 件 ／ 概算サイズ: ${_formatMB(_totalBytes)}',
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white70 : Colors.black87,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? Center(
                    child: Text(
                      'キャッシュされた小説はありません\n（小説を読むと自動でキャッシュされます）',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                  )
                : ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, idx) {
                      final item = _items[idx];
                      final workId = item['work_id'] as int;
                      final title = (item['title'] as String?) ?? 'タイトル不明';
                      final author = (item['author_name'] as String?) ?? '作者不明';
                      final updatedAt = item['updated_at'] as String?;
                      final charCount = (item['char_count'] as int?) ?? 0;
                      final dateLabel =
                          updatedAt != null && updatedAt.isNotEmpty
                          ? DateTimeFormat.formatReadable(updatedAt)
                          : '日時不明';
                      return Dismissible(
                        key: ValueKey('cache_$workId'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.redAccent,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        confirmDismiss: (direction) async {
                          return await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('キャッシュ削除'),
                                  content: Text('「$title」のキャッシュを削除しますか？'),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(false),
                                      child: const Text('キャンセル'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(true),
                                      child: const Text('削除'),
                                    ),
                                  ],
                                ),
                              ) ??
                              false;
                        },
                        onDismissed: (_) => _deleteItem(workId),
                        child: ListTile(
                          leading: const Icon(Icons.menu_book),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14),
                          ),
                          subtitle: Text(
                            '$author ・ $dateLabel ・ $charCount文字',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openItem(item),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
    Future<void> Function() action,
    String message,
  ) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('確認'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('削除'),
              ),
            ],
          ),
        ) ??
        false;
    if (ok && mounted) await action();
  }
}
