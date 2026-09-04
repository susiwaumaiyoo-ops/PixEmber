// あとで読む整理サービス（非AI機能パック Phase N5）。
//
// 設計:
// - 入力は read_later テーブル（tags_json スナップショット）と既存の
//   novel_embeddings（既に生成済みのベクトル）。ここではモデルを走らせず、
//   ネットワーク通信も追加しない。
// - embedding カバレッジが十分なら意味クラスタリング（貪欲centroid+cosine
//   閾値）、そうでなければ簡易モード（タグ頻度グループ）。
// - buildProposal は dry-run（読み取り専用）で DB には絶対に書き込まない。
// - フォルダ作成＋アイテム追加は adoptGroup のみで行い、UI はユーザーが
//   明示的に「採用」を押した場合にだけ呼ぶ（自動移動禁止）。

import 'dart:convert';
import 'dart:math' as math;

import 'database_service.dart';

/// あとで読むの1件（read_later 行の簡略化）。
class OrganizeItemData {
  final int workId;
  final String title;
  final String authorName;
  final String coverUrl;
  final List<String> tags;

  /// クラスタリング時にセット（semantic モード用）。
  List<double>? embedding;

  OrganizeItemData({
    required this.workId,
    required this.title,
    this.authorName = '',
    this.coverUrl = '',
    this.tags = const [],
    this.embedding,
  });
}

/// 整理提案の1グループ。
class OrganizeGroup {
  final String id;
  final String suggestedName;
  final String basis; // 'tag' | 'semantic' | 'rest'
  final List<OrganizeItemData> items;

  const OrganizeGroup({
    required this.id,
    required this.suggestedName,
    required this.basis,
    required this.items,
  });
}

/// 整理提案の結果（dry-run・採用時に再クエリしないようアイテム同梱）。
class OrganizeProposal {
  final List<OrganizeGroup> groups;
  final bool semanticMode;
  final int totalItems;

  const OrganizeProposal({
    required this.groups,
    required this.semanticMode,
    required this.totalItems,
  });
}

/// 純粋関数: タグ頻度グループ化。
///
/// タグを頻度順（同点は名前順）に並べ、各作品は「まだ未割り当ての先頭の
/// グループ」に割り当てる（1作品が属するのは高々1グループ）。
/// 未割り当ての作品は「その他」グループに入る。
List<OrganizeGroup> groupByTags(
  List<OrganizeItemData> items, {
  int maxGroups = 6,
  int minSize = 2,
}) {
  if (items.isEmpty) return const [];
  final tagCount = <String, int>{};
  for (final it in items) {
    for (final t in it.tags) {
      tagCount[t] = (tagCount[t] ?? 0) + 1;
    }
  }
  final tags = tagCount.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  final groups = <OrganizeGroup>[];
  final assigned = <int>{};
  for (final e in tags) {
    if (groups.length >= maxGroups) break;
    final memberItems = items
        .where((it) => it.tags.contains(e.key) && !assigned.contains(it.workId))
        .toList();
    if (memberItems.length < minSize) continue;
    for (final m in memberItems) {
      assigned.add(m.workId);
    }
    groups.add(
      OrganizeGroup(
        id: 'tag:${e.key}',
        suggestedName: e.key,
        basis: 'tag',
        items: memberItems,
      ),
    );
  }
  final rest = items.where((it) => !assigned.contains(it.workId)).toList();
  if (rest.isNotEmpty) {
    groups.add(
      OrganizeGroup(
        id: 'rest',
        suggestedName: 'その他',
        basis: 'rest',
        items: rest,
      ),
    );
  }
  return groups;
}

/// 純粋関数: グループ名候補（最頻タグ・同点なら上位2つを'・'で結合・無ければ「混合」）。
String suggestGroupName(List<String> tags) {
  if (tags.isEmpty) return '混合';
  final count = <String, int>{};
  for (final t in tags) {
    count[t] = (count[t] ?? 0) + 1;
  }
  final entries = count.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  final top = entries.first;
  final tied = entries.where((e) => e.value == top.value).toList();
  if (tied.length >= 2) {
    return '${tied[0].key}・${tied[1].key}';
  }
  return top.key;
}

double _cosine(List<double> a, List<double> b) {
  if (a.isEmpty || a.length != b.length) return 0;
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na <= 0 || nb <= 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// 純粋関数: 貪欲 centroid クラスタリング（embedding なしアイテムはクラスタに入れない）。
List<List<int>> clusterByEmbedding(
  List<OrganizeItemData> items, {
  double threshold = 0.4,
}) {
  final withVec = items
      .where((i) => i.embedding != null && i.embedding!.isNotEmpty)
      .toList();
  final clusters = <List<int>>[];
  final centroids = <List<double>>[];
  for (final it in withVec) {
    final v = it.embedding!;
    var best = -1;
    var bestSim = threshold;
    for (var c = 0; c < clusters.length; c++) {
      final sim = _cosine(v, centroids[c]);
      if (sim > bestSim) {
        bestSim = sim;
        best = c;
      }
    }
    if (best >= 0) {
      clusters[best].add(it.workId);
      final cen = centroids[best];
      final n = clusters[best].length;
      for (var k = 0; k < v.length; k++) {
        cen[k] = (cen[k] * (n - 1) + v[k]) / n;
      }
    } else {
      clusters.add([it.workId]);
      centroids.add(List<double>.of(v));
    }
  }
  return clusters;
}

/// 純粋関数: 小さいグループ（[minSize] 未満）を末尾「その他」へ統合。
List<List<int>> mergeSmall(List<List<int>> groups, {int minSize = 2}) {
  final out = <List<int>>[];
  final rest = <int>[];
  for (final g in groups) {
    if (g.length >= minSize) {
      out.add(g);
    } else {
      rest.addAll(g);
    }
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}

/// 純粋関数: semantic モードの採用判定（埋め込み3件以上かつカバレッジ60%以上）。
bool useSemanticMode(int total, int embedded) =>
    embedded >= 3 && total > 0 && embedded * 10 >= total * 6;

/// 純粋ステートマシン: 採用/スキップを記録し、実際に移動するプランを生成。
///
/// UI はこの buildPlan の結果のみを DB 書き込み（adoptGroup）に使うことで
/// 「dry-run と実行の分離」を保証する。
class OrganizeSession {
  final List<OrganizeGroup> groups;
  final Map<String, String> _adopted = {};
  final Set<String> _skipped = {};

  OrganizeSession(this.groups);

  void adopt(String groupId, String folderName) {
    _skipped.remove(groupId);
    _adopted[groupId] = folderName;
  }

  void skip(String groupId) {
    _adopted.remove(groupId);
    _skipped.add(groupId);
  }

  List<({String folderName, List<int> workIds})> buildPlan() {
    final byId = {for (final g in groups) g.id: g};
    final plan = <({String folderName, List<int> workIds})>[];
    for (final e in _adopted.entries) {
      if (_skipped.contains(e.key)) continue;
      final g = byId[e.key];
      if (g == null) continue;
      plan.add((
        folderName: e.value,
        workIds: g.items.map((i) => i.workId).toList(),
      ));
    }
    return plan;
  }
}

List<double> _parseVec(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final d = jsonDecode(json);
    if (d is List) {
      return d.map((x) => (x as num).toDouble()).toList();
    }
  } catch (_) {}
  return const [];
}

List<String> _parseTags(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final d = jsonDecode(json);
    if (d is List) {
      return d.map((x) => x.toString()).toList();
    }
  } catch (_) {}
  return const [];
}

/// あとで読む整理サービス（シングルトン）。
class ReadLaterOrganizeService {
  static final ReadLaterOrganizeService _instance =
      ReadLaterOrganizeService._internal();
  factory ReadLaterOrganizeService() => _instance;
  ReadLaterOrganizeService._internal();

  /// 整理提案を構築（dry-run・読み取り専用）。
  Future<OrganizeProposal> buildProposal() async {
    final rows = await DatabaseService().getReadLaterList();
    final items = <OrganizeItemData>[];
    for (final r in rows) {
      final workId = (r['work_id'] as num?)?.toInt() ?? 0;
      if (workId <= 0) continue;
      items.add(
        OrganizeItemData(
          workId: workId,
          title: (r['title'] as String?) ?? 'タイトル不明',
          authorName: (r['author_name'] as String?) ?? '',
          coverUrl: (r['cover_url'] as String?) ?? '',
          tags: _parseTags(r['tags_json'] as String?),
        ),
      );
    }
    if (items.isEmpty) {
      return const OrganizeProposal(
        groups: [],
        semanticMode: false,
        totalItems: 0,
      );
    }

    // 既存の埋め込み（novel_embeddings）をローカルから読むだけ。
    final embByWork = <int, List<double>>{};
    try {
      final db = await DatabaseService().database;
      final embRows = await db.rawQuery(
        'SELECT work_id, embedding FROM novel_embeddings',
      );
      for (final r in embRows) {
        final workId = (r['work_id'] as num?)?.toInt() ?? 0;
        final vec = _parseVec(r['embedding'] as String?);
        if (workId > 0 && vec.isNotEmpty) embByWork[workId] = vec;
      }
    } catch (_) {}

    final embeddedCount = items
        .where((i) => embByWork.containsKey(i.workId))
        .length;
    final semantic = useSemanticMode(items.length, embeddedCount);

    final groups = <OrganizeGroup>[];
    if (semantic) {
      for (final i in items) {
        i.embedding = embByWork[i.workId];
      }
      final merged = mergeSmall(clusterByEmbedding(items));
      final byId = {for (final i in items) i.workId: i};
      for (final c in merged) {
        final memberItems = c
            .map((id) => byId[id])
            .whereType<OrganizeItemData>()
            .toList();
        if (memberItems.isEmpty) continue;
        final tags = memberItems.expand((i) => i.tags).toList();
        groups.add(
          OrganizeGroup(
            id: 'sem:${c.first}',
            suggestedName: suggestGroupName(tags),
            basis: 'semantic',
            items: memberItems,
          ),
        );
      }
    } else {
      groups.addAll(groupByTags(items));
    }
    return OrganizeProposal(
      groups: groups,
      semanticMode: semantic,
      totalItems: items.length,
    );
  }

  /// フォルダを作成し、グループの作品を追加（ユーザーが明示的に採用した場合のみ呼ばれる）。
  Future<int> adoptGroup({
    required String folderName,
    required List<OrganizeItemData> items,
  }) async {
    final db = DatabaseService();
    final folderId = await db.createFolder(folderName);
    var moved = 0;
    for (final it in items) {
      await db.addFolderItem(
        folderId: folderId,
        workId: it.workId,
        title: it.title,
        authorName: it.authorName,
        previewUrl: it.coverUrl,
        type: 'novel',
      );
      moved++;
    }
    return moved;
  }
}
