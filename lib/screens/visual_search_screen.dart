// 視覚類似画像検索画面（Phase 5）。
//
// ダウンロード済みイラストのローカル画像から視覚的に似た作品を探す。
// 1. 「インデックス構築」で未解析の画像に特徴ベクトル（image_embeddings / DB v20）を生成。
// 2. グリッド内の画像をタップ → その画像と類似する画像を類似度順に表示。
//
// エンコーダは VisualEncoder 抽象に差し替え可能（現状は ColorGridEncoder）。
// 画像解析はすべて Isolate で実行し UI をブロックしない。

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../services/database_novel.dart' show getDownloadedIllustsList;
import '../services/database_service.dart';
import '../services/visual_search_service.dart';

class VisualSearchScreen extends StatefulWidget {
  const VisualSearchScreen({super.key});

  @override
  State<VisualSearchScreen> createState() => _VisualSearchScreenState();
}

class _VisualSearchScreenState extends State<VisualSearchScreen> {
  List<Map<String, dynamic>> _items = [];
  final Set<int> _indexedIds = <int>{};
  bool _isLoading = true;
  bool _isIndexing = false;
  int _indexDone = 0;
  int _indexTotal = 0;

  /// 検索結果（illust_id / local_path / similarity）。
  List<Map<String, dynamic>> _results = [];

  /// これ未満の類似度は候補から除外する。
  static const double _minSimilarity = 0.4;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final all = await getDownloadedIllustsList();
      final items = <Map<String, dynamic>>[];
      for (final e in all) {
        final p = (e['local_path'] as String?) ?? '';
        if (p.isEmpty || p.startsWith('novel_text:')) continue;
        if (!await File(p).exists()) continue;
        items.add(e);
      }
      final embeddings = await DatabaseService().getAllImageEmbeddings();
      if (!mounted) return;
      setState(() {
        _items = items;
        _indexedIds
          ..clear()
          ..addAll(embeddings.map((r) => r['illust_id'] as int));
        _results = [];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _snack('読み込みに失敗しました: $e');
    }
  }

  int get _unindexedCount =>
      _items.where((e) => !_indexedIds.contains(e['illust_id'] as int)).length;

  /// 未インデックスの画像に特徴ベクトルを生成する。
  /// 1件ずつ Isolate で処理し、失敗した画像はスキップして継続する。
  Future<void> _buildIndex() async {
    final targets = _items
        .where((e) => !_indexedIds.contains(e['illust_id'] as int))
        .toList();
    if (targets.isEmpty) {
      _snack('すべての画像はインデックス済みです');
      return;
    }
    setState(() {
      _isIndexing = true;
      _indexDone = 0;
      _indexTotal = targets.length;
    });
    const encoder = ColorGridEncoder();
    for (final item in targets) {
      final illustId = item['illust_id'] as int;
      final path = item['local_path'] as String;
      try {
        final bytes = await File(path).readAsBytes();
        final vec = await Isolate.run(() => decodeAndEncode(bytes, encoder));
        if (vec != null) {
          await DatabaseService().saveImageEmbedding(
            illustId: illustId,
            embedding: float32ToBytes(vec),
            dim: vec.length,
          );
          _indexedIds.add(illustId);
        }
      } catch (e) {
        debugPrint('視覚インデックス生成スキップ illustId=$illustId: $e');
      }
      if (mounted) setState(() => _indexDone++);
    }
    if (mounted) setState(() => _isIndexing = false);
    _snack('インデックス構築完了（$_indexDone / $_indexTotal 件）');
  }

  /// タップされた画像に類似する画像を検索する。
  Future<void> _search(Map<String, dynamic> item) async {
    final illustId = item['illust_id'] as int;
    if (!_indexedIds.contains(illustId)) {
      _snack('この画像は未インデックスです。先にインデックスを構築してください');
      return;
    }
    final path = item['local_path'] as String;
    const encoder = ColorGridEncoder();
    try {
      final bytes = await File(path).readAsBytes();
      final query = await Isolate.run(() => decodeAndEncode(bytes, encoder));
      if (query == null) {
        _snack('画像を解析できませんでした');
        return;
      }
      final all = await DatabaseService().getAllImageEmbeddings();
      final ranked = await Isolate.run(
        () => rankBySimilarity(
          all,
          query,
          queryIllustId: illustId,
          minSimilarity: _minSimilarity,
          limit: 30,
        ),
      );
      // illust_id → ローカル行情復元（検索対象画面にある画像のみ表示）。
      final byId = <int, Map<String, dynamic>>{
        for (final e in _items) e['illust_id'] as int: e,
      };
      final results = <Map<String, dynamic>>[];
      for (final r in ranked) {
        final id = r['illust_id'] as int;
        final src = byId[id];
        if (src == null) continue;
        results.add({
          'illust_id': id,
          'local_path': src['local_path'],
          'similarity': r['similarity'],
        });
      }
      if (!mounted) return;
      setState(() => _results = results);
      if (results.isEmpty) _snack('類似画像が見つかりませんでした');
    } catch (e) {
      _snack('検索に失敗しました: $e');
    }
  }

  void _clearResults() {
    setState(() => _results = []);
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
    final unindexed = _unindexedCount;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _results.isNotEmpty ? '類似画像（${_results.length}件）' : '視覚類似検索',
        ),
        backgroundColor: isDark ? const Color(0xFF222222) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 0.5,
        actions: [
          if (_results.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: '画像選択に戻る',
              onPressed: _clearResults,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '再読込',
            onPressed: _isLoading || _isIndexing ? null : _load,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isIndexing
          ? _buildIndexingProgress()
          : _items.isEmpty
          ? Center(
              child: Text(
                'ダウンロード済み画像がありません\n（イラストをダウンロードすると検索対象になります）',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            )
          : _results.isNotEmpty
          ? _buildGrid(isDark, _results, isResult: true)
          : _buildGrid(isDark, _items, isResult: false),
      floatingActionButton:
          !_isIndexing &&
              !_isLoading &&
              _results.isEmpty &&
              _items.isNotEmpty &&
              unindexed > 0
          ? FloatingActionButton.extended(
              onPressed: _buildIndex,
              icon: const Icon(Icons.auto_fix_high),
              label: Text('インデックス構築（$unindexed 件）'),
            )
          : null,
    );
  }

  Widget _buildIndexingProgress() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            '画像を解析中... $_indexDone / $_indexTotal',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            '処理はバックグラウンドで行われます（失敗した画像はスキップ）',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(
    bool isDark,
    List<Map<String, dynamic>> items, {
    required bool isResult,
  }) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final illustId = item['illust_id'] as int;
        final path = (item['local_path'] as String?) ?? '';
        final similarity = item['similarity'] as double?;
        final indexed = _indexedIds.contains(illustId);
        return GestureDetector(
          onTap: isResult ? () => _search(item) : () => _search(item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: isDark
                            ? Colors.grey.shade800
                            : Colors.grey.shade300,
                        child: const Icon(
                          Icons.broken_image,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                    if (!isResult && !indexed)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.warning_amber,
                            size: 12,
                            color: Colors.amber,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                similarity != null
                    ? '${(similarity * 100).toStringAsFixed(0)}%'
                    : 'ID: $illustId',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }
}
