/// AIレコメンドフィードのオーケストレーター（UI非依存）。
///
/// [EmbeddingService] / [DatabaseService] / [PixivApiService] を組み合わせ、
/// 嗜好ベクトル構築 → ローカル候補検索 → API候補取得 → 統合・除外・多様性制御
/// までを行う。計算の核心は [recommendation_math.dart] の純粋関数に委ねる。
///
/// UI層（[AiRecommendFeedScreen]）はこのサービスの結果を表示するのみ。
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../illust_model.dart';
import '../novel_model.dart';
import 'database_history.dart';
import 'database_search.dart';
import 'database_service.dart';
import 'embedding_service.dart';
import 'illust_document_text.dart';
import 'novel_document_text.dart';
import 'pixiv_api_service.dart';
import 'recommendation_math.dart';
import 'ruri_model_manager.dart';

/// レコメンドフィード1回分の構築結果。
class RecommendFeedResult {
  /// 統合・除外・多様性制御後の候補リスト（スコア降順）。
  final List<RecommendCandidate> candidates;

  /// AI モデルが利用可能（導入済み・初期化済み）か。
  final bool modelReady;

  /// 埋め込みカバレッジ率（0.0〜1.0）。候補全体に対する埋め込み所有率。
  final double coverageRatio;

  /// API のみのフォールバック表示か（モデル未導入・履歴不足等）。
  final bool isFallback;

  /// フィード再計算用の nextOffset（API おすすめのページネーション）。
  final int? nextNovelOffset;
  final int? nextIllustOffset;

  const RecommendFeedResult({
    required this.candidates,
    required this.modelReady,
    required this.coverageRatio,
    required this.isFallback,
    this.nextNovelOffset,
    this.nextIllustOffset,
  });
}

/// レコメンド設定（SharedPreferences で永続化）。
class RecommendSettings {
  final double historyWeight;
  final double favoriteWeight;
  final int historyLimit;
  final double minSimilarity;
  final int deferEmbedGenLimit;
  final int localSearchLimit;

  const RecommendSettings({
    this.historyWeight = 1.0,
    this.favoriteWeight = 2.0,
    this.historyLimit = 30,
    this.minSimilarity = 0.4,
    this.deferEmbedGenLimit = 30,
    this.localSearchLimit = 40,
  });

  static const _kHistoryWeight = 'recfeed_history_weight';
  static const _kFavoriteWeight = 'recfeed_favorite_weight';
  static const _kHistoryLimit = 'recfeed_history_limit';
  static const _kMinSimilarity = 'recfeed_min_similarity';
  static const _kDeferEmbedGenLimit = 'recfeed_defer_embed_gen_limit';
  static const _kLocalSearchLimit = 'recfeed_local_search_limit';

  static Future<RecommendSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return RecommendSettings(
      historyWeight: prefs.getDouble(_kHistoryWeight) ?? 1.0,
      favoriteWeight: prefs.getDouble(_kFavoriteWeight) ?? 2.0,
      historyLimit: prefs.getInt(_kHistoryLimit) ?? 30,
      minSimilarity: prefs.getDouble(_kMinSimilarity) ?? 0.4,
      deferEmbedGenLimit: prefs.getInt(_kDeferEmbedGenLimit) ?? 30,
      localSearchLimit: prefs.getInt(_kLocalSearchLimit) ?? 40,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kHistoryWeight, historyWeight);
    await prefs.setDouble(_kFavoriteWeight, favoriteWeight);
    await prefs.setInt(_kHistoryLimit, historyLimit);
    await prefs.setDouble(_kMinSimilarity, minSimilarity);
    await prefs.setInt(_kDeferEmbedGenLimit, deferEmbedGenLimit);
    await prefs.setInt(_kLocalSearchLimit, localSearchLimit);
  }

  RecommendSettings copyWith({
    double? historyWeight,
    double? favoriteWeight,
    int? historyLimit,
  }) => RecommendSettings(
    historyWeight: historyWeight ?? this.historyWeight,
    favoriteWeight: favoriteWeight ?? this.favoriteWeight,
    historyLimit: historyLimit ?? this.historyLimit,
    minSimilarity: minSimilarity,
    deferEmbedGenLimit: deferEmbedGenLimit,
    localSearchLimit: localSearchLimit,
  );
}

/// AIレコメンドフィード構築サービス（シングルトン）。
///
/// UI から分離されており、純粋なデータ変換のみを行う。
/// キャッシュとして嗜好ベクトルをモデルID単位でメモリ保持する。
class RecommendationService {
  static final RecommendationService _instance =
      RecommendationService._internal();
  factory RecommendationService() => _instance;
  RecommendationService._internal();

  /// 嗜好ベクトルのメモリキャッシュ。
  /// キー = "novel:{modelId}" / "illust:{modelId}"
  final Map<String, Float32List> _vectorCache = {};

  /// キャッシュを無効化（履歴/お気に入り変更時・モデル切替時に呼ぶ）。
  void invalidateCache() => _vectorCache.clear();

  /// AI モデルが利用可能（導入済み）か。
  Future<bool> isModelReady() async {
    try {
      return await RuriModelManager().isModelReady();
    } catch (_) {
      return false;
    }
  }

  /// 小説・イラストそれぞれの嗜好ベクトルを取得（キャッシュ付き）。
  ///
  /// モデル未導入・初期化失敗・履歴不足の場合は null を返す。
  Future<(Float32List? novelVec, Float32List? illustVec)>
  loadPreferenceVectors() async {
    if (!await isModelReady()) return (null, null);

    final embeddingService = EmbeddingService();
    if (!embeddingService.isInitialized) {
      try {
        await embeddingService.initialize();
      } catch (_) {
        return (null, null);
      }
    }
    if (!embeddingService.isInitialized) return (null, null);

    final modelId = RuriModelManager.embeddingModelId;
    final novelKey = 'novel:$modelId';
    final illustKey = 'illust:$modelId';

    Float32List? novelVec = _vectorCache[novelKey];
    Float32List? illustVec = _vectorCache[illustKey];

    if (novelVec == null) {
      novelVec = await _buildVectorForType(
        type: 'novel',
        embeddingService: embeddingService,
        modelId: modelId,
      );
      if (novelVec != null) _vectorCache[novelKey] = novelVec;
    }
    if (illustVec == null) {
      illustVec = await _buildVectorForType(
        type: 'illust',
        embeddingService: embeddingService,
        modelId: modelId,
      );
      if (illustVec != null) _vectorCache[illustKey] = illustVec;
    }

    return (novelVec, illustVec);
  }

  /// 指定タイプの嗜好ベクトルを構築。
  Future<Float32List?> _buildVectorForType({
    required String type,
    required EmbeddingService embeddingService,
    required String modelId,
  }) async {
    final db = await DatabaseService().database;
    final settings = await RecommendSettings.load();

    // 履歴から直近N件のユニーク work_id を取得
    final historyRows = await searchDistinctHistoryByWork(
      db: db,
      type: type,
      limit: settings.historyLimit,
    );
    if (historyRows.isEmpty) return null;

    // お気に入り（folder_items）から work_id を取得。
    // getFolderItems は folderId が必須のため、全フォルダを取得して
    // それぞれのアイテムを集約する。
    final favWorkIds = <int>{};
    final folders = await DatabaseService().getFoldersList();
    for (final folder in folders) {
      final folderId = folder['id'];
      if (folderId is! int) continue;
      final items = await DatabaseService().getFolderItems(
        folderId: folderId,
        type: type,
        limit: 200,
      );
      for (final r in items) {
        final wid = r['work_id'];
        if (wid is int && wid > 0) favWorkIds.add(wid);
      }
    }
    final favWorkIdList = favWorkIds.toList();

    // 履歴の work_id
    final historyWorkIds = historyRows
        .map((r) => r['work_id'])
        .whereType<int>()
        .where((id) => id > 0)
        .toList();

    // 埋め込みを取得（novel_embeddings / illust_embeddings から直接SELECT）
    final embTable = type == 'novel' ? 'novel_embeddings' : 'illust_embeddings';
    final allWorkIds = <int>{...historyWorkIds, ...favWorkIdList};
    if (allWorkIds.isEmpty) return null;

    final placeholders = List.filled(allWorkIds.length, '?').join(',');
    final embRows = await db.query(
      embTable,
      columns: [
        'work_id',
        'embedding',
        'model_id',
        'model_version',
        'prefix_scheme_version',
      ],
      where:
          'work_id IN ($placeholders) AND model_id = ? AND model_version = ? AND prefix_scheme_version = ?',
      whereArgs: [
        ...allWorkIds,
        modelId,
        RuriModelManager.embeddingModelVersion,
        RuriModelManager.prefixSchemeVersion,
      ],
    );

    final embMap = <int, Float32List>{};
    for (final row in embRows) {
      final wid = row['work_id'] as int?;
      final embStr = row['embedding'] as String?;
      if (wid == null || embStr == null) continue;
      try {
        final list = (jsonDecode(embStr) as List).cast<num>();
        embMap[wid] = Float32List.fromList(
          list.map((e) => e.toDouble()).toList(),
        );
      } catch (_) {}
    }

    // 履歴ベクトル（新→旧順）
    final historyVectors = <Float32List>[];
    for (final row in historyRows) {
      final wid = row['work_id'] as int?;
      if (wid == null) continue;
      final v = embMap[wid];
      if (v != null) historyVectors.add(v);
    }

    // お気に入りベクトル
    final favoriteVectors = <Float32List>[];
    for (final wid in favWorkIdList) {
      final v = embMap[wid];
      if (v != null) favoriteVectors.add(v);
    }

    if (historyVectors.isEmpty && favoriteVectors.isEmpty) return null;

    return buildPreferenceVector(
      historyVectors: historyVectors,
      favoriteVectors: favoriteVectors,
      historyWeight: settings.historyWeight,
      favoriteWeight: settings.favoriteWeight,
    );
  }

  /// メイン: フィード候補を構築する。
  ///
  /// [novelOffset] / [illustOffset] は API おすすめのページネーション。
  /// [cancel] が true になったら処理を中断する。
  Future<RecommendFeedResult> buildFeed({
    int? novelOffset,
    int? illustOffset,
    ValueNotifier<bool>? cancel,
  }) async {
    final settings = await RecommendSettings.load();
    final modelReady = await isModelReady();

    // モデル未導入 → API フォールバック
    if (!modelReady) {
      return _buildApiFallbackFeed(
        novelOffset: novelOffset,
        illustOffset: illustOffset,
      );
    }

    // 嗜好ベクトル取得
    final (novelVec, illustVec) = await loadPreferenceVectors();

    // 履歴不足（ベクトル構築不可）→ API フォールバック
    if (novelVec == null && illustVec == null) {
      return _buildApiFallbackFeed(
        novelOffset: novelOffset,
        illustOffset: illustOffset,
      );
    }

    final db = await DatabaseService().database;

    // ローカル候補検索
    List<Map<String, dynamic>> localNovels = [];
    List<Map<String, dynamic>> localIllusts = [];
    if (novelVec != null) {
      try {
        localNovels = await searchNovelsByEmbedding(
          db: db,
          userEmbedding: novelVec,
          limit: settings.localSearchLimit,
          minSimilarity: settings.minSimilarity,
        );
      } catch (e) {
        debugPrint('[RecFeed] local novel search failed: $e');
      }
    }
    if (illustVec != null) {
      try {
        localIllusts = await searchIllustsByEmbedding(
          db: db,
          userEmbedding: illustVec,
          limit: settings.localSearchLimit,
          minSimilarity: settings.minSimilarity,
        );
      } catch (e) {
        debugPrint('[RecFeed] local illust search failed: $e');
      }
    }

    if (cancel?.value == true) {
      return const RecommendFeedResult(
        candidates: [],
        modelReady: true,
        coverageRatio: 0,
        isFallback: false,
      );
    }

    // API 候補取得
    final api = PixivApiService();
    List<Map<String, dynamic>> apiNovels = [];
    List<Map<String, dynamic>> apiIllusts = [];
    int? nextNovelOffset;
    int? nextIllustOffset;
    try {
      final novelResult = await api.getNovelRecommend(offset: novelOffset ?? 0);
      apiNovels = novelResult.items.map((n) => n.toJson()).toList();
      nextNovelOffset = novelResult.nextOffset;
    } catch (e) {
      debugPrint('[RecFeed] api novel recommend failed: $e');
    }
    try {
      final illustResult = await api.getRecommend(offset: illustOffset ?? 0);
      apiIllusts = illustResult.items.map((i) => i.toJson()).toList();
      nextIllustOffset = illustResult.nextOffset;
    } catch (e) {
      debugPrint('[RecFeed] api illust recommend failed: $e');
    }

    // 統合
    final merged = mergeAndRank(
      localNovels: localNovels,
      localIllusts: localIllusts,
      apiNovels: apiNovels,
      apiIllusts: apiIllusts,
      maxPerSource: 30,
    );

    // 除外リスト構築
    final (readIds, mutedAuthorIds, mutedWorkIds, deletedIds) =
        await _buildExclusionSets();

    // 除外
    final filtered = excludeFiltered(
      candidates: merged,
      readWorkIds: readIds,
      mutedAuthorIds: mutedAuthorIds,
      mutedWorkIds: mutedWorkIds,
      deletedWorkIds: deletedIds,
    );

    // 多様性制御
    final diversified = suppressAuthorSeriesBias(candidates: filtered);

    // カバレッジ計算
    final withEmbedding = diversified.where((c) => c.source == 'local').length;
    final total = diversified.length;
    final coverage = total == 0 ? 0.0 : withEmbedding / total;

    // 遅延埋め込み生成（UI非ブロック）
    _deferredEmbeddingGeneration(
      apiNovels: apiNovels,
      apiIllusts: apiIllusts,
      settings: settings,
    );

    // Phase N2: 推薦理由を取り付ける
    final withReasons = await _attachReasons(diversified);

    return RecommendFeedResult(
      candidates: withReasons,
      modelReady: true,
      coverageRatio: coverage,
      isFallback: false,
      nextNovelOffset: nextNovelOffset,
      nextIllustOffset: nextIllustOffset,
    );
  }

  /// API のみのフォールバックフィードを構築。
  Future<RecommendFeedResult> _buildApiFallbackFeed({
    int? novelOffset,
    int? illustOffset,
  }) async {
    final api = PixivApiService();
    List<Map<String, dynamic>> apiNovels = [];
    List<Map<String, dynamic>> apiIllusts = [];
    int? nextNovelOffset;
    int? nextIllustOffset;
    try {
      final novelResult = await api.getNovelRecommend(offset: novelOffset ?? 0);
      apiNovels = novelResult.items.map((n) => n.toJson()).toList();
      nextNovelOffset = novelResult.nextOffset;
    } catch (_) {}
    try {
      final illustResult = await api.getRecommend(offset: illustOffset ?? 0);
      apiIllusts = illustResult.items.map((i) => i.toJson()).toList();
      nextIllustOffset = illustResult.nextOffset;
    } catch (_) {}

    final merged = mergeAndRank(
      localNovels: [],
      localIllusts: [],
      apiNovels: apiNovels,
      apiIllusts: apiIllusts,
    );

    final (readIds, mutedAuthorIds, mutedWorkIds, deletedIds) =
        await _buildExclusionSets();
    final filtered = excludeFiltered(
      candidates: merged,
      readWorkIds: readIds,
      mutedAuthorIds: mutedAuthorIds,
      mutedWorkIds: mutedWorkIds,
      deletedWorkIds: deletedIds,
    );
    final diversified = suppressAuthorSeriesBias(candidates: filtered);

    // Phase N2: 推薦理由を取り付ける（フォールバック時はタグ・作者ベースのみ）
    final withReasons = await _attachReasons(diversified);

    return RecommendFeedResult(
      candidates: withReasons,
      modelReady: false,
      coverageRatio: 0,
      isFallback: true,
      nextNovelOffset: nextNovelOffset,
      nextIllustOffset: nextIllustOffset,
    );
  }

  /// 除外用の ID 集を構築。
  /// - 既読: history テーブルの work_id 全て
  /// - ミュート作者: mutes の mute_type='author' の value
  /// - ミュート作品: mutes の mute_type='work' の value
  /// - 削除済み: DB に存在しない（getNovelMeta/getIllustMeta で null）→ ここでは空集合
  ///   （除外は表示時の FutureBuilder 相当で行うのが本来だが、ここでは history ベース）
  Future<(Set<int>, Set<int>, Set<int>, Set<int>)> _buildExclusionSets() async {
    final db = await DatabaseService().database;

    // 既読 = history の work_id 全件
    final historyRows = await db.query('history', columns: ['work_id']);
    final readIds = historyRows
        .map((r) => r['work_id'])
        .whereType<int>()
        .where((id) => id > 0)
        .toSet();

    // ミュート
    final mutes = await DatabaseService().getMutesList();
    final mutedAuthorIds = <int>{};
    final mutedWorkIds = <int>{};
    for (final m in mutes) {
      final muteType = m['mute_type'] as String?;
      final value = m['value'];
      if (value == null) continue;
      final id = value is int
          ? value
          : (value is num ? value.toInt() : int.tryParse(value.toString()));
      if (id == null || id == 0) continue;
      if (muteType == 'author') {
        mutedAuthorIds.add(id);
      } else if (muteType == 'work') {
        mutedWorkIds.add(id);
      }
    }

    return (readIds, mutedAuthorIds, mutedWorkIds, <int>{});
  }

  /// API 候補のうち埋め込み未生成の作品をバックグラウンドで生成（上限付き）。
  /// UI をブロックしない（await しない）。
  void _deferredEmbeddingGeneration({
    required List<Map<String, dynamic>> apiNovels,
    required List<Map<String, dynamic>> apiIllusts,
    required RecommendSettings settings,
  }) {
    unawaited(
      Future(() async {
        final embeddingService = EmbeddingService();
        if (!embeddingService.isInitialized) return;

        // 小説
        final novelIds = apiNovels
            .map((m) => m['id'])
            .whereType<int>()
            .where((id) => id > 0)
            .take(settings.deferEmbedGenLimit)
            .toList();
        if (novelIds.isNotEmpty) {
          try {
            final missing = await DatabaseService().getWorkIdsWithoutEmbedding(
              novelIds,
            );
            for (final workId in missing.take(settings.deferEmbedGenLimit)) {
              try {
                final json = apiNovels.firstWhere((m) => m['id'] == workId);
                final novel = Novel.fromJson(json);
                final text = buildNovelDocumentText(novel);
                final vector = await embeddingService.encodeDocument(text);
                await DatabaseService().saveNovelEmbedding(
                  workId: workId,
                  embedding: vector,
                );
                await DatabaseService().saveNovel(novel);
              } catch (e) {
                debugPrint(
                  '[RecFeed] deferred novel embed failed for $workId: $e',
                );
              }
            }
          } catch (e) {
            debugPrint('[RecFeed] deferred novel embed batch failed: $e');
          }
        }

        // イラスト
        final illustIds = apiIllusts
            .map((m) => m['id'])
            .whereType<int>()
            .where((id) => id > 0)
            .take(settings.deferEmbedGenLimit)
            .toList();
        if (illustIds.isNotEmpty) {
          try {
            final missing = await DatabaseService()
                .getIllustIdsWithoutEmbedding(illustIds);
            for (final workId in missing.take(settings.deferEmbedGenLimit)) {
              try {
                final json = apiIllusts.firstWhere((m) => m['id'] == workId);
                final illust = Illust.fromJson(json);
                final text = buildIllustDocumentText(illust);
                final vector = await embeddingService.encodeDocument(text);
                await DatabaseService().saveIllustEmbedding(
                  workId: workId,
                  embedding: vector,
                );
                await DatabaseService().saveIllustMeta(illust);
              } catch (e) {
                debugPrint(
                  '[RecFeed] deferred illust embed failed for $workId: $e',
                );
              }
            }
          } catch (e) {
            debugPrint('[RecFeed] deferred illust embed batch failed: $e');
          }
        }
      }),
    );
  }

  /// 埋め込みカバレッジ率を計算（ガイダンス表示用）。
  /// novels / illusts テーブルの全件に対する埋め込み保有率。
  Future<double> embeddingCoverageRatio() async {
    final db = await DatabaseService().database;
    final modelId = RuriModelManager.embeddingModelId;

    final novelTotal =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM novels'),
        ) ??
        0;
    final novelEmb =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM novel_embeddings WHERE model_id = ?',
            [modelId],
          ),
        ) ??
        0;

    final illustTotal =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM illusts'),
        ) ??
        0;
    final illustEmb =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM illust_embeddings WHERE model_id = ?',
            [modelId],
          ),
        ) ??
        0;

    final total = novelTotal + illustTotal;
    final emb = novelEmb + illustEmb;
    if (total == 0) return 0;
    return emb / total;
  }

  // ==================== Phase N2: 推薦理由 ====================

  /// 理由コンテキストを読み込む（履歴＋お気に入り＋タグ）。クエリ失敗は許容。
  Future<_ReasonContext> _loadReasonContext() async {
    final db = await DatabaseService().database;
    final historyRows = await searchDistinctHistoryByWork(db: db, limit: 100);
    final knownAuthorNames = <String>{};
    final recentNovelIds = <int>[];
    final recentIllustIds = <int>[];
    final recentTitles = <int, String>{};
    for (final r in historyRows) {
      final name = (r['author_name'] as String? ?? '').trim();
      if (name.isNotEmpty) knownAuthorNames.add(name);
      final wid = (r['work_id'] as num?)?.toInt() ?? 0;
      if (wid <= 0) continue;
      final title = (r['title'] as String? ?? '').trim();
      if (title.isNotEmpty) recentTitles[wid] = title;
      if ((r['type'] as String? ?? '') == 'illust') {
        recentIllustIds.add(wid);
      } else {
        recentNovelIds.add(wid);
      }
    }
    final favNovelIds = <int>{};
    final favIllustIds = <int>{};
    try {
      final favRows = await db.rawQuery(
        'SELECT DISTINCT work_id, type FROM folder_items',
      );
      for (final r in favRows) {
        final wid = (r['work_id'] as num?)?.toInt() ?? 0;
        if (wid <= 0) continue;
        if ((r['type'] as String? ?? '') == 'illust') {
          favIllustIds.add(wid);
        } else {
          favNovelIds.add(wid);
        }
      }
    } catch (e) {
      debugPrint('[RecFeed] favorites query failed: $e');
    }
    return _ReasonContext(
      recentNovels: await _workRefs(
        db,
        'novel',
        recentNovelIds,
        titles: recentTitles,
      ),
      recentIllusts: await _workRefs(
        db,
        'illust',
        recentIllustIds,
        titles: recentTitles,
      ),
      favoriteNovels: await _workRefs(db, 'novel', favNovelIds.toList()),
      favoriteIllusts: await _workRefs(db, 'illust', favIllustIds.toList()),
      knownAuthorNames: knownAuthorNames,
    );
  }

  /// novels/illusts テーブルを ID 指定で参照し作品参照を構築する。
  Future<List<RecentWorkRef>> _workRefs(
    Database db,
    String type,
    List<int> ids, {
    Map<int, String>? titles,
  }) async {
    if (ids.isEmpty) return const [];
    final table = type == 'illust' ? 'illusts' : 'novels';
    final ph = List.filled(ids.length, '?').join(',');
    final meta = <int, Map<String, dynamic>>{};
    try {
      final rows = await db.query(
        table,
        columns: ['id', 'title', 'author_name', 'tags_json', 'tags'],
        where: 'id IN ($ph)',
        whereArgs: ids,
      );
      for (final r in rows) {
        final id = r['id'] as int?;
        if (id != null) meta[id] = r;
      }
    } catch (_) {
      return const [];
    }
    final refs = <RecentWorkRef>[];
    for (final id in ids) {
      final m = meta[id];
      if (m == null) continue;
      final historyTitle = titles?[id];
      refs.add(
        RecentWorkRef(
          workId: id,
          title: (historyTitle != null && historyTitle.isNotEmpty)
              ? historyTitle
              : (m['title'] as String? ?? '').trim(),
          authorName: (m['author_name'] as String? ?? '').trim(),
          tags: extractTagsFromRow(m),
        ),
      );
    }
    return refs;
  }

  /// 候補に推薦理由を取り付ける（失敗時はそのまま返す）。
  Future<List<RecommendCandidate>> _attachReasons(
    List<RecommendCandidate> candidates,
  ) async {
    if (candidates.isEmpty) return candidates;
    try {
      final ctx = await _loadReasonContext();
      return candidates.map((c) {
        final isNovel = c.type == 'novel';
        return c.copyWith(
          reasons: buildRecommendationReason(
            candidate: c,
            recentWorks: isNovel ? ctx.recentNovels : ctx.recentIllusts,
            favoriteWorks: isNovel ? ctx.favoriteNovels : ctx.favoriteIllusts,
            knownAuthorNames: ctx.knownAuthorNames,
          ),
        );
      }).toList();
    } catch (e) {
      debugPrint('[RecFeed] recommendation reason build failed: $e');
      return candidates;
    }
  }
}

/// 理由コンテキスト（履歴・お気に入りの作品＋既知作者名）。
class _ReasonContext {
  final List<RecentWorkRef> recentNovels;
  final List<RecentWorkRef> recentIllusts;
  final List<RecentWorkRef> favoriteNovels;
  final List<RecentWorkRef> favoriteIllusts;
  final Set<String> knownAuthorNames;

  const _ReasonContext({
    required this.recentNovels,
    required this.recentIllusts,
    required this.favoriteNovels,
    required this.favoriteIllusts,
    required this.knownAuthorNames,
  });
}
