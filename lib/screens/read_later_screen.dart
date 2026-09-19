import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';
import '../theme/app_spacing.dart';
import '../utils/datetime_format.dart';
import '../widgets/design_system/app_state_view.dart';
import '../widgets/pixiv_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'novel_detail_screen.dart';
import 'novel_reader_screen.dart';
import '../services/series_progress_service.dart';
import '../services/read_later_organize_service.dart';

/// あとで読む（小説）一覧画面。
///
/// タブ: すべて / 未読 / 読書中 / 読了。各タブに件数バッジを表示。
/// ステータス 0:未読 / 1:読書中 / 2:読了。
class ReadLaterScreen extends StatefulWidget {
  const ReadLaterScreen({super.key});

  @override
  State<ReadLaterScreen> createState() => _ReadLaterScreenState();
}

class _ReadLaterScreenState extends State<ReadLaterScreen>
    with SingleTickerProviderStateMixin {
  static const List<int?> _tabs = [null, 0, 1, 2];

  late TabController _tabController;
  final Map<int?, List<Map<String, dynamic>>> _cache = {};
  bool _isLoading = false;
  bool _showR18 = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadAll();
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final status = _tabs[_tabController.index];
    if (!_cache.containsKey(status)) _load(status);
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    try {
      for (final status in _tabs) {
        _cache[status] = await DatabaseService().getReadLaterList(
          status: status,
        );
      }
    } catch (e) {
      _showSnackBar('一覧の読み込みに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _load(int? status) async {
    try {
      _cache[status] = await DatabaseService().getReadLaterList(status: status);
      if (mounted) setState(() {});
    } catch (e) {
      _showSnackBar('一覧の読み込みに失敗しました: $e');
    }
  }

  List<Map<String, dynamic>> _visibleItems(int? status) {
    final items = _cache[status] ?? [];
    if (_showR18) return items;
    return items.where((e) => (e['x_restrict'] as int? ?? 0) == 0).toList();
  }

  Future<void> _openItem(Map<String, dynamic> item) async {
    final workId = item['work_id'] as int;
    final status = item['status'] as int? ?? 0;

    // 未読を開いたら「読書中」へ自動遷移
    if (status == 0) {
      await DatabaseService().updateReadLaterStatus(workId, 1);
    }

    try {
      final novel = await PixivApiService().getNovelById(workId);
      if (!mounted) return;
      // 未読は詳細画面、読書中/読了は直接リーダー再開
      if (status == 0) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
        );
      } else {
        // 読書中/読了から再開：保存済みの最終位置を SharedPreferences に書き込み、
        // NovelReaderScreen 起動時にそれを読み込んで該当ページへ再開する。
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        await prefs.setInt(
          'novel_page_$workId',
          (item['last_page'] as int? ?? 0),
        );
        await prefs.setDouble(
          'novel_offset_$workId',
          (item['last_offset'] as num? ?? 0).toDouble(),
        );
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => NovelReaderScreen(novel: novel)),
        );
      }
    } catch (e) {
      _showSnackBar('小説の取得に失敗しました: $e');
    } finally {
      _loadAll();
    }
  }

  Future<void> _removeItem(Map<String, dynamic> item) async {
    final workId = item['work_id'] as int;
    final title = (item['title'] as String?) ?? '';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF222222),
        title: const Text('削除の確認', style: TextStyle(color: Colors.white)),
        content: Text(
          '「$title」をあとで読むから削除しますか？',
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
              '削除',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await DatabaseService().removeReadLater(workId);
    _showSnackBar('削除しました');
    _loadAll();
  }

  Future<void> _setStatus(Map<String, dynamic> item, int status) async {
    final workId = item['work_id'] as int;
    await DatabaseService().updateReadLaterStatus(workId, status);
    final label = status == 0
        ? '未読'
        : status == 1
        ? '読書中'
        : '読了';
    _showSnackBar('$label に変更しました');
    _loadAll();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.pink.shade700),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('あとで読む'),
        backgroundColor: Colors.black87,
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: [
            Tab(text: 'すべて (${_visibleItems(null).length})'),
            Tab(text: '未読 (${_visibleItems(0).length})'),
            Tab(text: '読書中 (${_visibleItems(1).length})'),
            Tab(text: '読了 (${_visibleItems(2).length})'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_fix_high, color: Colors.pinkAccent),
            onPressed: _showOrganizeSheet,
            tooltip: 'あとで読む整理提案',
          ),
          IconButton(
            icon: Icon(
              _showR18 ? Icons.visibility : Icons.visibility_off,
              color: _showR18 ? Colors.pinkAccent : Colors.white70,
            ),
            onPressed: () => setState(() => _showR18 = !_showR18),
            tooltip: _showR18 ? 'R-18 を表示' : 'R-18 を非表示',
          ),
        ],
      ),
      body: _isLoading
          ? const AppStateView(type: AppStateViewType.loading)
          : TabBarView(
              controller: _tabController,
              children: _tabs.map((status) => _buildList(status)).toList(),
            ),
    );
  }

  Widget _buildList(int? status) {
    final items = _visibleItems(status);
    if (items.isEmpty) return _buildEmptyState(status);
    return RefreshIndicator(
      onRefresh: () => _load(status),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: items.length,
        separatorBuilder: (_, index) => const Divider(height: 1),
        itemBuilder: (context, index) => _buildItemTile(items[index]),
      ),
    );
  }

  Widget _buildEmptyState(int? status) {
    final label = status == 0
        ? '未読の作品'
        : status == 1
        ? '読書中の作品'
        : status == 2
        ? '読了した作品'
        : '作品';
    return AppStateView(
      type: AppStateViewType.empty,
      icon: Icons.menu_book,
      title: '$label はまだありません',
    );
  }

  Widget _buildItemTile(Map<String, dynamic> item) {
    final workId = item['work_id'] as int;
    final title = (item['title'] as String?) ?? '';
    final author = (item['author_name'] as String?) ?? '';
    final coverUrl = (item['cover_url'] as String?) ?? '';
    final textLength = (item['text_length'] as int? ?? 0);
    final status = item['status'] as int? ?? 0;
    final addedAt = item['added_at'] as String?;
    final lastOpenedAt = item['last_opened_at'] as String?;
    final tagsJson = item['tags_json'] as String?;

    final tags = <String>[];
    if (tagsJson != null && tagsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(tagsJson) as List<dynamic>;
        tags.addAll(decoded.map((e) => e.toString()));
      } catch (_) {
        // タグ解析失敗は無視
      }
    }

    final subtitleParts = <String>[
      author,
      if (textLength > 0) '$textLength 文字',
    ];
    if (status == 1) {
      // 変更3: 読書中項目に進捗率を表示（0.0=未開始, 1.0=読了済み）。
      final progress = (item['progress'] as num? ?? 0).toDouble();
      subtitleParts.add(
        progress >= 0.999 ? '読了済み' : '読了 ${(progress * 100).round()}%',
      );
      if (lastOpenedAt != null) {
        subtitleParts.add(
          '最終閲覧: ${DateTimeFormat.formatReadable(lastOpenedAt)}',
        );
      }
    } else if (addedAt != null) {
      subtitleParts.add('登録: ${DateTimeFormat.formatReadable(addedAt)}');
    }

    return Dismissible(
      key: ValueKey('read_later_$workId'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.redAccent,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        await _removeItem(item);
        return false; // 自前でリストを再構築するため常に false
      },
      child: ListTile(
        leading: SizedBox(
          width: 48,
          height: 64,
          child: coverUrl.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: PixivImage(
                    url: coverUrl,
                    fit: BoxFit.cover,
                    isThumbnail: true,
                    errorWidget: const Icon(Icons.book, color: Colors.grey),
                  ),
                )
              : const Icon(Icons.book, color: Colors.grey),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _statusChip(status),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitleParts.where((e) => e.isNotEmpty).join(' ・ '),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (status == 1) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(
                  value: (item['progress'] as num? ?? 0).toDouble().clamp(
                    0.0,
                    1.0,
                  ),
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Colors.pinkAccent,
                  ),
                  minHeight: 3,
                ),
              ),
            ],
            if (tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  tags.take(3).join('  '),
                  style: const TextStyle(
                    color: Colors.pinkAccent,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        onTap: () => _openItem(item),
        onLongPress: () => _showItemMenu(item),
      ),
    );
  }

  /// ローカルの novels テーブルから series_id を引く（Phase N3）。
  /// read_later 行自体には series 情報が無いためここで補完する。
  Future<int> _seriesIdForWork(int workId) async {
    try {
      final db = await DatabaseService().database;
      final rows = await db.rawQuery(
        'SELECT series_id FROM novels WHERE id = ?',
        [workId],
      );
      if (rows.isEmpty) return 0;
      return (rows.first['series_id'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// シリーズの次の未読話へジャンプ（Phase N3）。取得中は SnackBar で指示。
  Future<void> _openSeriesNext(Map<String, dynamic> item, int seriesId) async {
    if (seriesId <= 0) {
      _showSnackBar('この作品はシリーズに属していません');
      return;
    }
    _showSnackBar('シリーズの続きを探しています…');
    try {
      final progress = await SeriesProgressService().fetch(seriesId);
      final next = progress?.nextUnreadWork;
      if (next == null) {
        _showSnackBar('このシリーズは全話読了済みです');
        return;
      }
      if (!mounted) return;
      if (next.id == item['work_id']) {
        // 次が自分自身（現在話）ならリーダーを再開
        await _openItem(item);
        return;
      }
      final novel = await PixivApiService().getNovelById(next.id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => NovelDetailScreen(novel: novel)),
      );
    } catch (e) {
      if (mounted) _showSnackBar('シリーズの取得に失敗しました: $e');
    }
  }

  Future<void> _showItemMenu(Map<String, dynamic> item) async {
    final status = item['status'] as int? ?? 0;
    final seriesId = await _seriesIdForWork(item['work_id'] as int);
    if (!mounted) return; // async gap 後の context 使用を mounted でガード
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF222222),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (seriesId > 0)
              ListTile(
                leading: const Icon(
                  Icons.play_circle_outline,
                  color: Colors.pinkAccent,
                ),
                title: const Text(
                  'シリーズの続きへ',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _openSeriesNext(item, seriesId);
                },
              ),
            if (status != 0)
              ListTile(
                leading: const Icon(Icons.remove_done, color: Colors.white70),
                title: const Text(
                  '未読に戻す',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _setStatus(item, 0);
                },
              ),
            if (status != 2)
              ListTile(
                leading: const Icon(Icons.done_all, color: Colors.white70),
                title: const Text(
                  '読了にする',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _setStatus(item, 2);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text(
                '削除',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.pop(context);
                _removeItem(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 整理提案シートを開く（Phase N5）。dry-run の提案表示のみで、
  /// フォルダ作成はシート内の「採用」ボタン押下の明示的操作時のみ行う。
  void _showOrganizeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => const _OrganizeProposalSheet(),
    );
  }

  Widget _statusChip(int status) {
    final data = switch (status) {
      1 => (label: '読書中', color: Colors.blueAccent),
      2 => (label: '読了', color: Colors.green),
      _ => (label: '未読', color: Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: data.color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        data.label,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

// あとで読む整理提案シート（非AI機能パック Phase N5）。
class _OrganizeProposalSheet extends StatefulWidget {
  const _OrganizeProposalSheet();

  @override
  State<_OrganizeProposalSheet> createState() => _OrganizeProposalSheetState();
}

class _OrganizeProposalSheetState extends State<_OrganizeProposalSheet> {
  OrganizeProposal? _proposal;
  bool _loading = true;
  List<OrganizeGroup> _visible = [];
  final Map<String, TextEditingController> _nameControllers = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _nameControllers.values) {
      c.dispose();
    }
    _nameControllers.clear();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await ReadLaterOrganizeService().buildProposal();
      if (!mounted) return;
      setState(() {
        _proposal = p;
        _visible = p.groups;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  TextEditingController _controllerFor(OrganizeGroup g) => _nameControllers
      .putIfAbsent(g.id, () => TextEditingController(text: g.suggestedName));

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.pink.shade700),
    );
  }

  /// 「採用」: フォルダを作成し、グループの作品を追加（唯一の書き込み経路）。
  Future<void> _adopt(OrganizeGroup g) async {
    final name = _controllerFor(g).text.trim();
    if (name.isEmpty) {
      _showSnackBar('フォルダ名を入力してください');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final moved = await ReadLaterOrganizeService().adoptGroup(
        folderName: name,
        items: g.items,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text('「$name」フォルダに $moved 件を追加しました'),
          backgroundColor: Colors.pink.shade700,
        ),
      );
      navigator.pop();
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('フォルダの作成に失敗しました'),
          backgroundColor: Colors.pink.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = _proposal?.semanticMode ?? false;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.folder_copy, color: Colors.pinkAccent),
                  const SizedBox(width: 8),
                  const Text(
                    'あとで読む整理提案',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      semantic ? '意味モード（埋め込み）' : '簡易モード（タグ頻度）',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'グループは自動で移動しません。「採用」を押したグループのみが対応フォルダに追加されます。',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
            const Divider(height: 16, color: Colors.white24),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Colors.pinkAccent,
                      ),
                    )
                  : _visible.isEmpty
                  ? const Center(
                      child: Text(
                        '提案できるグループはありません',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _visible.length,
                      itemBuilder: (context, i) => _buildGroupTile(_visible[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupTile(OrganizeGroup g) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_fix_high,
                color: Colors.pinkAccent,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                g.suggestedName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${g.items.length}件',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            g.items.take(2).map((i) => i.title).join('、'),
            style: const TextStyle(color: Colors.grey, fontSize: 11),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controllerFor(g),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'フォルダ名',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
              filled: true,
              fillColor: Colors.black.withValues(alpha: 0.3),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _visible.remove(g);
                      _nameControllers[g.id]?.dispose();
                      _nameControllers.remove(g.id);
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  child: const Text('スキップ'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _adopt(g),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.pinkAccent,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text(
                    '採用（フォルダに追加）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
