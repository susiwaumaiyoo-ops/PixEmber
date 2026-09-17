// 重複・近似重複画像検出画面（Phase 6）。
//
// ダウンロード済み画像をスキャンして重複を検出し、確認付きで削除する。
// 1. 「スキャン」で全画像の SHA-256 + dHash 指紋を計算（image_fingerprints / DB v21）。
//    スキャンは中断可能（再開時は未解析分のみ処理）。
// 2. 検出結果を「完全一致」「近似」タブで表示。
// 3. 削除は各画像ごとに確認ダイアログを必須とする（自動削除なし）。
//
// 削除実行は download_queues / downloaded_illust / ファイル実体の 3点を
// 整合性維持しつつ行い、外部アプリによるファイル欠損も再スキャンで修復される。

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../services/database_service.dart';
import '../services/download_service.dart';
import '../services/duplicate_detection_service.dart';
import '../utils/empty_image_message.dart';

class DuplicateFinderScreen extends StatefulWidget {
  const DuplicateFinderScreen({super.key});

  @override
  State<DuplicateFinderScreen> createState() => _DuplicateFinderScreenState();
}

class _DuplicateFinderScreenState extends State<DuplicateFinderScreen> {
  List<Map<String, dynamic>> _items = [];
  final Map<int, ImageFingerprint> _prints = {};
  bool _isLoading = true;
  bool _isScanning = false;
  bool _scanCancelled = false;
  int _scanDone = 0;
  int _scanTotal = 0;

  List<DuplicateGroup> _exactGroups = [];
  List<DuplicateGroup> _nearGroups = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final all = await DatabaseService().getDownloadedIllustsList();
      final items = <Map<String, dynamic>>[];
      for (final e in all) {
        final p = (e['local_path'] as String?) ?? '';
        if (p.isEmpty || p.startsWith('novel_text:')) continue;
        if (!await File(p).exists()) continue;
        items.add(e);
      }
      final rows = await DatabaseService().getAllImageFingerprints();
      final prints = <int, ImageFingerprint>{};
      final byId = <int, String>{
        for (final e in items)
          e['illust_id'] as int: (e['local_path'] as String?) ?? '',
      };
      for (final r in rows) {
        final id = r['illust_id'] as int;
        final path = byId[id];
        if (path == null) continue; // 既にファイルが無い指紋は無視
        prints[id] = ImageFingerprint(
          illustId: id,
          localPath: path,
          sha256Hex: r['sha256'] as String,
          dhash: r['dhash'] as int,
        );
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _prints
          ..clear()
          ..addAll(prints);
        _isLoading = false;
      });
      _updateGroups();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _snack('読み込みに失敗しました: $e');
    }
  }

  int get _unscannedCount =>
      _items.where((e) => !_prints.containsKey(e['illust_id'] as int)).length;

  /// 指紋リストから重複グループを再計算して反映する。
  void _updateGroups() {
    final all = _prints.values.toList();
    final exact = findDuplicateGroups(all, exact: true);
    final near = findDuplicateGroups(all, exact: false, maxHammingDistance: 4);
    // 近似タブでは完全一致を除いて表示（完全一致は専用タブで見えるため）。
    final exactSets = exact
        .map((g) => g.members.map((m) => m.illustId).toSet())
        .toSet();
    final nearOnly = <DuplicateGroup>[];
    for (final g in near) {
      final ids = g.members.map((m) => m.illustId).toSet();
      if (exactSets.any((s) => s.containsAll(ids))) continue;
      nearOnly.add(g);
    }
    setState(() {
      _exactGroups = exact;
      _nearGroups = nearOnly;
    });
  }

  /// 未スキャンの画像に指紋を計算する。中断ボタンで途中終了可能。
  Future<void> _scan() async {
    final targets = _items
        .where((e) => !_prints.containsKey(e['illust_id'] as int))
        .toList();
    if (targets.isEmpty) {
      _snack('すべての画像はスキャン済みです');
      return;
    }
    setState(() {
      _isScanning = true;
      _scanCancelled = false;
      _scanDone = 0;
      _scanTotal = targets.length;
    });
    for (final item in targets) {
      if (_scanCancelled) break;
      final illustId = item['illust_id'] as int;
      final path = (item['local_path'] as String?) ?? '';
      try {
        final bytes = await File(path).readAsBytes();
        final fp = await Isolate.run(
          () => computeFingerprint(
            illustId: illustId,
            localPath: path,
            bytes: bytes,
          ),
        );
        if (fp != null) {
          await DatabaseService().saveImageFingerprint(
            illustId: fp.illustId,
            sha256: fp.sha256Hex,
            dhash: fp.dhash,
          );
          _prints[fp.illustId] = fp;
        }
      } catch (e) {
        debugPrint('指紋計算スキップ illustId=$illustId: $e');
      }
      if (mounted) setState(() => _scanDone++);
    }
    if (mounted) setState(() => _isScanning = false);
    _updateGroups();
    _snack(
      _scanCancelled
          ? 'スキャンを中断しました（$_scanDone / $_scanTotal 件）'
          : 'スキャン完了（$_scanDone / $_scanTotal 件）',
    );
  }

  /// 削除確認ダイアログ → ファイル・キュー・指紋の整合性維持で削除。
  Future<void> _confirmAndDelete(ImageFingerprint fp) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('画像を削除'),
        content: Text(
          'この画像ファイルを削除しますか？\n'
          'ID: ${fp.illustId}\n'
          'パス: ${fp.localPath}\n\n'
          'この操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final file = File(fp.localPath);
      if (await file.exists()) {
        await file.delete();
      }
      await DatabaseService().deleteImageFingerprint(fp.illustId);
      // 外部削除検出と同じ修復経路でキュー/本棚の整合性を保つ。
      await DownloadService().integrityCheck();
      if (!mounted) return;
      _prints.remove(fp.illustId);
      _snack('削除しました');
      _load();
    } catch (e) {
      _snack('削除に失敗しました: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unscanned = _unscannedCount;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('重複画像の検出'),
          backgroundColor: isDark ? const Color(0xFF222222) : Colors.white,
          foregroundColor: isDark ? Colors.white : Colors.black,
          elevation: 0.5,
          bottom: TabBar(
            labelColor: isDark ? Colors.white : Colors.black,
            tabs: [
              Tab(text: '完全一致 (${_exactGroups.length})'),
              Tab(text: '近似 (${_nearGroups.length})'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _isScanning
            ? _buildScanProgress()
            : _items.isEmpty
            ? Center(
                child: Text(
                  'ダウンロード済み画像がありません',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              )
            : _items.length == 1
            ? Center(
                child: Text(
                  buildEmptyImageMessage(_items.length, '重複検出')!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              )
            : TabBarView(
                children: [
                  _buildGroupList(_exactGroups, exact: true),
                  _buildGroupList(_nearGroups, exact: false),
                ],
              ),
        floatingActionButton:
            !_isScanning && !_isLoading && _items.isNotEmpty && unscanned > 0
            ? FloatingActionButton.extended(
                onPressed: _scan,
                icon: const Icon(Icons.find_replace),
                label: Text('スキャン（残り $unscanned 件）'),
              )
            : null,
      ),
    );
  }

  Widget _buildScanProgress() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            '画像を解析中... $_scanDone / $_scanTotal',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => setState(() => _scanCancelled = true),
            child: const Text('中断'),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupList(List<DuplicateGroup> groups, {required bool exact}) {
    if (groups.isEmpty) {
      final scanned = _prints.length;
      return Center(
        child: Text(
          scanned == 0 ? '未スキャンです\n「スキャン」ボタンで重複を検出できます' : '重複は見つかりませんでした',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 14),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return Card(
          color: const Color(0xFF1E1E1E),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exact
                      ? '完全一致（${group.members.length} 枚）'
                      : '近似（${group.members.length} 枚・類似度参照）',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < group.members.length; i++)
                  _buildMemberTile(group, i),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMemberTile(DuplicateGroup group, int index) {
    final fp = group.members[index];
    final reference = group.members.first.dhash;
    final ham = hammingDistance(reference, fp.dhash);
    final sim = similarityPercent(ham);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Image.file(
              File(fp.localPath),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: Colors.grey.shade800,
                child: const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ID: ${fp.illustId}',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                Text(
                  !group.exact && index > 0 ? '類似度: $sim%' : 'SHA-256 一致',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'この画像を削除',
            onPressed: () => _confirmAndDelete(fp),
          ),
        ],
      ),
    );
  }
}
