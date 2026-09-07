/// ハイブリッド「似た作品」推薦サービス（感動機能パック Phase D）。
///
/// 複数の類似軸（意味 / タグ / 視覚）を 0..1 に正規化して重み付け統合し、
/// ローカル（DB）と API（pixiv 関連作品）の候補を (type, workId) で重複排除して
/// 統合ランキングを返す。計算の核心は純粋関数（テスト容易）に寄せ、
/// DB / API / モデル取得はサービス側に閉じ込める。
///
/// 軸と既定の重み:
/// - 意味 (semantic): Ruri embedding のコサイン類似度。既定 0.5
/// - タグ (tag):      タグ集合の Jaccard 係数。既定 0.3
/// - 視覚 (visual):   イラストのみ ColorGrid 特徴のコサイン類似度。既定 0.2
///
/// 同一作者・同一シリーズは推薦軸ではなく「別セクション」として UI に返す
/// （本サービスでは similarWorks からは除外し、sameAuthor/sameSeries に分離）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../illust_model.dart';
import '../novel_model.dart';
import 'database_search.dart';
import 'database_service.dart';
import 'embedding_service.dart';
import 'illust_document_text.dart';
import 'novel_document_text.dart';
import 'pixiv_api_service.dart';
import 'ruri_model_manager.dart';
import 'recommendation_math.dart';
import 'visual_search_service.dart' as visual;

// ============================================================
// データ型
// ============================================================

/// 類似軸の重み設定（合計は 1.0 前後を想定。0 以下の軸は無効）。
class SimilarWeights {
  final double semantic;
  final double tag;
  final double visual;

  const SimilarWeights({
    this.semantic = 0.5,
    this.tag = 0.3,
    this.visual = 0.2,
  });

  /// 正の重みの合計（正規化用）。0 以下しか無い場合は 1.0。
  double get activeSum {
    final s =
        (semantic > 0 ? semantic : 0.0) +
        (tag > 0 ? tag : 0.0) +
        (visual > 0 ? visual : 0.0);
    return s <= 0 ? 1.0 : s;
  }
}

/// 「似た作品」候補1件。
class SimilarWork {
  final int workId;

  /// 'novel' または 'illust'。
  final String type;

  /// 統合スコア（0..1）。
  final double score;

  /// 軸ごとの 0..1 スコア（未取得/非対応は 0）。
  final double semanticScore;
  final double tagScore;
  final double visualScore;

  /// 'local' または 'api'。
  final String source;

  /// 「なぜ似ているか」の一行理由。
  final String reason;

  /// DB 行または API モデルの Map（カード描画に利用）。
  final Map<String, dynamic> row;

  const SimilarWork({
    required this.workId,
    required this.type,
    required this.score,
    required this.semanticScore,
    required this.tagScore,
    required this.visualScore,
    required this.source,
    required this.reason,
    required this.row,
  });
}

/// 「似た作品」構築結果。
class SimilarWorksResult {
  /// 統合・除外・重複排除後の候補（スコア降順）。
  final List<SimilarWork> works;

  /// 同一作者の作品（参考セクション）。
  final List<SimilarWork> sameAuthor;

  /// 同一シリーズの作品（参考セクション）。
  final List<SimilarWork> sameSeries;

  /// AI モデル（意味軸）が利用可能だったか。
  final bool modelReady;

  /// 意味軸の対象作品があったか（0 件ならタグ/視覚のみ）。
  final bool semanticAvailable;

  const SimilarWorksResult({
    required this.works,
    required this.sameAuthor,
    required this.sameSeries,
    required this.modelReady,
    required this.semanticAvailable,
  });
}

// ============================================================
// 純粋関数（テスト可能）
// ============================================================

/// タグ集合の Jaccard 係数（|A∩B| / |A∪B|）。両方空なら 0。
double tagJaccard(List<String> a, List<String> b) {
  final sa = a.where((t) => t.isNotEmpty).toSet();
  final sb = b.where((t) => t.isNotEmpty).toSet();
  if (sa.isEmpty && sb.isEmpty) return 0.0;
  final inter = sa.intersection(sb).length;
  final union = sa.union(sb).length;
  if (union == 0) return 0.0;
  return inter / union;
}

/// 生の意味類似度（Ruri cosine は理論上 -1..1）を 0..1 に正規化。
double normalizeSemantic(double cosineSim) {
  if (cosineSim.isNaN) return 0.0;
  return ((cosineSim + 1.0) / 2.0).clamp(0.0, 1.0);
}

/// 視覚・タグなど既に 0..1 に近い値を安全に 0..1 にクランプして正規化。
double normalize01(double v) {
  if (v.isNaN) return 0.0;
  return v.clamp(0.0, 1.0);
}

/// 「なぜ似ているか」の一行理由を生成。
///
/// 支配的な軸（重み×スコアの寄与が最大）を理由として返す。
/// 全て 0 なら API 由来なら「関連作品」、ローカルなら「関連作品」を返す。
String buildReason({
  required double semanticScore,
  required double tagScore,
  required double visualScore,
  required SimilarWeights weights,
  required String type,
}) {
  final sContrib =
      semanticScore * (weights.semantic > 0 ? weights.semantic : 0);
  final tContrib = tagScore * (weights.tag > 0 ? weights.tag : 0);
  final vContrib = visualScore * (weights.visual > 0 ? weights.visual : 0);

  if (sContrib <= 0 && tContrib <= 0 && vContrib <= 0) {
    return '関連作品';
  }
  if (sContrib >= tContrib && sContrib >= vContrib) {
    return '内容が似ています';
  }
  if (tContrib >= sContrib && tContrib >= vContrib) {
    return 'タグが似ています';
  }
  return type == 'illust' ? '絵柄が似ています' : '内容が似ています';
}

/// (type, workId) で重複排除（先勝ち）。既存の同一キーがあればスキップ。
List<SimilarWork> dedupeByWork(List<SimilarWork> items) {
  final seen = <String>{};
  final out = <SimilarWork>[];
  for (final w in items) {
    final key = '${w.type}:${w.workId}';
    if (seen.add(key)) out.add(w);
  }
  return out;
}

// ============================================================
// サービス（シングルトン）
// ============================================================

/// ハイブリッド「似た作品」構築サービス（シングルトン）。
///
/// テスト時は [SimilarWorksService.testWith] で差し替える。
class SimilarWorksService {
  static final SimilarWorksService _instance = SimilarWorksService._internal();
  factory SimilarWorksService() => _instance;
  SimilarWorksService._internal();

  /// テスト用差し替え（null で本物に戻す）。
  @visibleForTesting
  static SimilarWorksService? testInstance;

  /// テスト用インスタンスを返すファクトリ。
  static SimilarWorksService resolve() => testInstance ?? _instance;

  /// API 関連作品のスコア（0..1）。1件目 0.7、以降逓減して 0.4 まで。
  double apiScoreForIndex(int index) {
    final v = 0.7 - index * 0.02;
    return v < 0.4 ? 0.4 : (v > 1.0 ? 1.0 : v);
  }

  /// 小説に対する「似た作品」を構築。
  ///
  /// - [excludeRead]: 既読（history）を除外するか。
  /// - [excludeMuted]: ミュート作者/作品を除外するか。
  Future<SimilarWorksResult> buildForNovel(
    Novel novel, {
    SimilarWeights weights = const SimilarWeights(),
    int limit = 10,
    bool excludeRead = true,
    bool excludeMuted = true,
  }) async {
    return _build(
      workId: novel.id,
      type: 'novel',
      tags: novel.tags,
      authorId: novel.author.id,
      seriesId: novel.series?.id ?? 0,
      semanticDocText: buildNovelDocumentText(novel),
      weights: weights,
      limit: limit,
      excludeRead: excludeRead,
      excludeMuted: excludeMuted,
    );
  }

  /// イラストに対する「似た作品」を構築（視覚軸あり）。
  Future<SimilarWorksResult> buildForIllust(
    Illust illust, {
    SimilarWeights weights = const SimilarWeights(),
    int limit = 10,
    bool excludeRead = true,
    bool excludeMuted = true,
  }) async {
    return _build(
      workId: illust.id,
      type: 'illust',
      tags: illust.tags,
      authorId: illust.author.id,
      seriesId: 0,
      semanticDocText: buildIllustDocumentText(illust),
      weights: weights,
      limit: limit,
      excludeRead: excludeRead,
      excludeMuted: excludeMuted,
      illust: illust,
    );
  }

  Future<SimilarWorksResult> _build({
    required int workId,
    required String type,
    required List<String> tags,
    required int authorId,
    required int seriesId,
    required String semanticDocText,
    required SimilarWeights weights,
    required int limit,
    required bool excludeRead,
    required bool excludeMuted,
    Illust? illust,
  }) async {
    // Failsafe: any unexpected exception (DB not ready, corrupted model,
    // plugin missing on some platform, ...) must never crash the UI.
    // Return an empty tag-based fallback result and log instead.
    try {
      return await _buildInternal(
        workId: workId,
        type: type,
        tags: tags,
        authorId: authorId,
        seriesId: seriesId,
        semanticDocText: semanticDocText,
        weights: weights,
        limit: limit,
        excludeRead: excludeRead,
        excludeMuted: excludeMuted,
        illust: illust,
      );
    } catch (e, st) {
      debugPrint('[SimilarWorks] build failed (fallback to tag-only): $e');
      debugPrint(st.toString());
      return SimilarWorksResult(
        works: const [],
        sameAuthor: const [],
        sameSeries: const [],
        modelReady: false,
        semanticAvailable: false,
      );
    }
  }

  Future<SimilarWorksResult> _buildInternal({
    required int workId,
    required String type,
    required List<String> tags,
    required int authorId,
    required int seriesId,
    required String semanticDocText,
    required SimilarWeights weights,
    required int limit,
    required bool excludeRead,
    required bool excludeMuted,
    Illust? illust,
  }) async {
    final db = await DatabaseService().database;

    // ---- 除外集合 ----
    final (readIds, mutedAuthorIds, mutedWorkIds) = await _exclusionSets(
      excludeRead: excludeRead,
      excludeMuted: excludeMuted,
    );

    // ---- 意味軸: 対象作品の embedding（なければ生成） ----
    Float32List? queryVec;
    bool modelReady = false;
    if (weights.semantic > 0) {
      // Skip the semantic axis entirely when the embedding model is not
      // installed: initializing EmbeddingService would fail anyway, so
      // never let that failure surface as an exception to the UI.
      final present = await _isModelPresentQuietly();
      if (present) {
        queryVec = await _getQueryEmbedding(type, workId, semanticDocText);
        modelReady = queryVec != null;
      }
    }

    // ---- ローカル候補（意味 + タグ + 視覚） ----
    final Map<int, _Acc> acc = {};

    // 意味
    bool semanticAvailable = false;
    if (queryVec != null) {
      final rows = type == 'novel'
          ? await searchNovelsByEmbedding(
              db: db,
              userEmbedding: queryVec,
              limit: 60,
              minSimilarity: 0.0,
            )
          : await searchIllustsByEmbedding(
              db: db,
              userEmbedding: queryVec,
              limit: 60,
              minSimilarity: 0.0,
            );
      for (final r in rows) {
        final id = _idOf(r);
        if (id == 0 || id == workId) continue;
        final sim = (r['similarity'] as num?)?.toDouble() ?? 0.0;
        final a = acc.putIfAbsent(id, () => _Acc(row: r));
        a.semantic = normalizeSemantic(sim);
        semanticAvailable = true;
      }
    }

    // タグ（tags_json を LIKE で緩く候補収集 → 厳密 Jaccard）
    if (weights.tag > 0 && tags.isNotEmpty) {
      final tagRows = await _collectTagCandidates(db, type, tags, workId);
      for (final r in tagRows) {
        final id = _idOf(r);
        if (id == 0) continue;
        final candTags = _tagsOf(r);
        final a = acc.putIfAbsent(id, () => _Acc(row: r));
        a.tag = normalize01(tagJaccard(tags, candTags));
      }
    }

    // 視覚（イラストのみ・ColorGrid）
    if (weights.visual > 0 && type == 'illust') {
      final visScores = await _visualScores(illust);
      visScores.forEach((id, v) {
        if (id == workId) return;
        final a = acc.putIfAbsent(id, () => _Acc());
        a.visual = normalize01(v);
      });
    }

    // ---- ローカル候補を SimilarWork 化 ----
    final local = <SimilarWork>[];
    acc.forEach((id, a) {
      if (id == workId) return;
      if (a.row == null) return; // メタデータが無いと描画できない
      final score = _combine(a, weights);
      if (score <= 0) return;
      local.add(
        SimilarWork(
          workId: id,
          type: type,
          score: score,
          semanticScore: a.semantic,
          tagScore: a.tag,
          visualScore: a.visual,
          source: 'local',
          reason: buildReason(
            semanticScore: a.semantic,
            tagScore: a.tag,
            visualScore: a.visual,
            weights: weights,
            type: type,
          ),
          row: a.row!,
        ),
      );
    });

    // ---- API 候補 ----
    final apiWorks = <SimilarWork>[];
    if (type == 'illust') {
      try {
        final rel = await PixivApiService().getIllustRelated(workId);
        for (int i = 0; i < rel.length; i++) {
          final item = rel[i];
          if (item.id == workId) continue;
          final sc = apiScoreForIndex(i);
          apiWorks.add(
            SimilarWork(
              workId: item.id,
              type: 'illust',
              score: sc,
              semanticScore: 0,
              tagScore: normalize01(tagJaccard(tags, item.tags)),
              visualScore: 0,
              source: 'api',
              reason: '関連作品',
              row: item.toJson(),
            ),
          );
        }
      } catch (e) {
        debugPrint('[SimilarWorks] getIllustRelated failed (ignored): $e');
      }
    }

    // ---- 統合・重複排除（local 優先 = 先勝ち） ----
    var merged = dedupeByWork([...local, ...apiWorks]);

    // ---- 除外（既読/ミュート）。recommendation_math の純粋関数を再利用 ----
    final asCandidates = merged
        .map(
          (w) => RecommendCandidate(
            workId: w.workId,
            type: w.type,
            score: w.score,
            source: w.source,
            row: w.row,
          ),
        )
        .toList();
    final kept = excludeFiltered(
      candidates: asCandidates,
      readWorkIds: excludeRead ? readIds : <int>{},
      mutedAuthorIds: excludeMuted ? mutedAuthorIds : <int>{},
      mutedWorkIds: excludeMuted ? mutedWorkIds : <int>{},
      deletedWorkIds: <int>{},
    );
    final keepKeys = kept.map((c) => '${c.type}:${c.workId}').toSet();
    merged = merged
        .where((w) => keepKeys.contains('${w.type}:${w.workId}'))
        .toList();

    // ---- 同一作者・同一シリーズを分離（推薦軸からは外す） ----
    final works = <SimilarWork>[];
    final sameAuthor = <SimilarWork>[];
    final sameSeries = <SimilarWork>[];
    for (final w in merged) {
      final c = RecommendCandidate(
        workId: w.workId,
        type: w.type,
        score: w.score,
        source: w.source,
        row: w.row,
      );
      if (seriesId != 0 && c.seriesId == seriesId) {
        sameSeries.add(w);
      } else if (authorId != 0 && c.authorId == authorId) {
        sameAuthor.add(w);
      } else {
        works.add(w);
      }
    }

    works.sort((a, b) => b.score.compareTo(a.score));
    sameAuthor.sort((a, b) => b.score.compareTo(a.score));
    sameSeries.sort((a, b) => b.score.compareTo(a.score));

    return SimilarWorksResult(
      works: works.take(limit).toList(),
      sameAuthor: sameAuthor.take(limit).toList(),
      sameSeries: sameSeries.take(limit).toList(),
      modelReady: modelReady,
      semanticAvailable: semanticAvailable,
    );
  }

  /// 除外集合（既読・ミュート）。
  Future<(Set<int>, Set<int>, Set<int>)> _exclusionSets({
    required bool excludeRead,
    required bool excludeMuted,
  }) async {
    final readIds = <int>{};
    final mutedAuthorIds = <int>{};
    final mutedWorkIds = <int>{};
    try {
      if (excludeRead) {
        final rows = await (await DatabaseService().database).query(
          'history',
          columns: ['work_id'],
        );
        for (final r in rows) {
          final id = r['work_id'];
          if (id is int && id > 0) readIds.add(id);
        }
      }
      if (excludeMuted) {
        final mutes = await DatabaseService().getMutesList();
        for (final m in mutes) {
          final t = m['mute_type'] as String?;
          final v = m['value'];
          final id = v is int
              ? v
              : (v is num ? v.toInt() : int.tryParse(v.toString()));
          if (id == null || id == 0) continue;
          if (t == 'author') mutedAuthorIds.add(id);
          if (t == 'work') mutedWorkIds.add(id);
        }
      }
    } catch (e) {
      debugPrint('[SimilarWorks] exclusion sets failed (ignored): $e');
    }
    return (readIds, mutedAuthorIds, mutedWorkIds);
  }

  /// 対象作品のクエリ embedding。既存を優先し、無ければオンデマンド生成して保存。
  Future<Float32List?> _getQueryEmbedding(
    String type,
    int workId,
    String docText,
  ) async {
    try {
      final svc = EmbeddingService();
      if (!svc.isInitialized) {
        await svc.initialize();
      }
      if (!svc.isInitialized) return null;

      // 既存保存を優先
      if (type == 'novel') {
        final rows = await (await DatabaseService().database).query(
          'novel_embeddings',
          columns: ['embedding'],
          where: 'work_id = ?',
          whereArgs: [workId],
          limit: 1,
        );
        final existing = _decodeEmbedding(rows);
        if (existing != null) return existing;
        final v = await svc.encodeDocument(docText);
        await DatabaseService().saveNovelEmbedding(
          workId: workId,
          embedding: v,
        );
        return v;
      } else {
        final rows = await (await DatabaseService().database).query(
          'illust_embeddings',
          columns: ['embedding'],
          where: 'work_id = ?',
          whereArgs: [workId],
          limit: 1,
        );
        final existing = _decodeEmbedding(rows);
        if (existing != null) return existing;
        final v = await svc.encodeDocument(docText);
        await DatabaseService().saveIllustEmbedding(
          workId: workId,
          embedding: v,
        );
        return v;
      }
    } catch (e) {
      debugPrint('[SimilarWorks] query embedding unavailable: $e');
      return null;
    }
  }

  /// Model presence check that never throws (quietly degrades to false).
  Future<bool> _isModelPresentQuietly() async {
    try {
      return await RuriModelManager().isModelPresent();
    } catch (e) {
      debugPrint('[SimilarWorks] model presence check failed (ignored): $e');
      return false;
    }
  }

  Float32List? _decodeEmbedding(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return null;
    final raw = rows.first['embedding'];
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return Float32List.fromList(
        decoded.map((e) => (e as num).toDouble()).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  /// タグ候補を収集（tags_json LIKE OR）。自身は除外。
  Future<List<Map<String, dynamic>>> _collectTagCandidates(
    Database db,
    String type,
    List<String> tags,
    int selfId,
  ) async {
    final table = type == 'novel' ? 'novels' : 'illusts';
    final conditions = <String>[];
    final args = <Object>[];
    for (final t in tags.toSet()) {
      final tr = t.trim();
      if (tr.length <= 1) continue;
      conditions.add('tags_json LIKE ?');
      args.add('%"$tr"%');
    }
    if (conditions.isEmpty) return [];
    try {
      final rows = await db.query(
        table,
        where: conditions.join(' OR '),
        whereArgs: args,
        limit: 100,
      );
      return rows.where((r) => _idOf(r) != selfId).toList();
    } catch (e) {
      debugPrint('[SimilarWorks] tag candidates failed (ignored): $e');
      return [];
    }
  }

  /// 視覚スコア（image_embeddings の ColorGrid）。対象が未解析なら空。
  Future<Map<int, double>> _visualScores(Illust? illust) async {
    final out = <int, double>{};
    if (illust == null) return out;
    try {
      final all = await DatabaseService().getAllImageEmbeddings();
      if (all.isEmpty) return out;
      // 対象作品の特徴ベクトルを探す
      Map<String, dynamic>? selfRow;
      for (final r in all) {
        if ((r['illust_id'] as int?) == illust.id) {
          selfRow = r;
          break;
        }
      }
      if (selfRow == null) return out;
      final selfBytes = selfRow['embedding'];
      if (selfBytes is! List<int>) return out;
      final selfVec = visual.bytesToFloat32(Uint8List.fromList(selfBytes));
      for (final r in all) {
        final id = r['illust_id'] as int?;
        if (id == null || id == illust.id) continue;
        final b = r['embedding'];
        if (b is! List<int>) continue;
        final sim = visual.cosineSimilarity(
          selfVec,
          visual.bytesToFloat32(Uint8List.fromList(b)),
        );
        out[id] = sim;
      }
    } catch (e) {
      debugPrint('[SimilarWorks] visual scores failed (ignored): $e');
    }
    return out;
  }

  /// 軸スコアを重み付け統合（0..1）。
  double _combine(_Acc a, SimilarWeights w) {
    final sum = w.activeSum;
    final s = (w.semantic > 0 ? w.semantic : 0) * a.semantic;
    final t = (w.tag > 0 ? w.tag : 0) * a.tag;
    final v = (w.visual > 0 ? w.visual : 0) * a.visual;
    return ((s + t + v) / sum).clamp(0.0, 1.0);
  }

  int _idOf(Map<String, dynamic> row) {
    final v = row['id'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  List<String> _tagsOf(Map<String, dynamic> row) {
    // API モデル形式: tags: [{name:..}] or [String]
    final t = row['tags'];
    if (t is List) {
      return t
          .map((e) {
            if (e is Map) return e['name']?.toString() ?? '';
            return e.toString();
          })
          .where((s) => s.isNotEmpty)
          .toList();
    }
    // DB 行形式: tags_json (JSON array string)
    final tj = row['tags_json'];
    if (tj is String && tj.isNotEmpty) {
      try {
        return List<String>.from(jsonDecode(tj) as List);
      } catch (_) {}
    }
    final ts = row['tags'];
    if (ts is String && ts.isNotEmpty) return ts.split(',');
    return const [];
  }
}

/// 集計用の内部アキュムレータ（軸スコアと元データ行を保持）。
class _Acc {
  double semantic = 0.0;
  double tag = 0.0;
  double visual = 0.0;
  Map<String, dynamic>? row;
  _Acc({this.row});
}
