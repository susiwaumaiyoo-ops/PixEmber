import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

import 'database_search.dart';
import 'database_service.dart';
import 'embedding_service.dart';
import 'feeling_search_query.dart';
import 'illust_document_text.dart';
import 'novel_document_text.dart';
import 'rerank_service.dart';

/// フィーリング発掘 v2 のハイブリッド検索サービス。
///
/// パイプライン：
/// - Step A: hard filter（R-18 / AI / ブクマ / 文字数 / 除外キーワード・タグ）で SQL/local 絞り込み
/// - Step B: 2系統の候補取得
///     - semantic candidate: 埋め込み類似度 topN
///     - lexical candidate: タイトル/説明/タグ の LIKE
/// - Step C: work_id ベースで候補集合を統合
/// - Step D: 複合スコア（semantic/keyword/tag/metadata + bonus - exclude penalty）
/// - rerank: 高精度モード時のみ RerankService で再ランク（未導入ならスキップ）
/// - explanation: なぜヒットしたかの簡易説明を付与
class HybridSearchService {
  HybridSearchService._();

  static final HybridSearchService _instance = HybridSearchService._();
  factory HybridSearchService() => _instance;

  /// 構造化クエリで検索する。モデル未導入（semantic 不可）でも lexical のみで動作する。
  ///
  /// [query] 構造化検索条件。
  /// [modelReady] EmbeddingService が利用可能なら true（semantic 検索を実行）。
  /// 戻り値は novels 行 + finalScore + 内訳スコア + explanation を含む。
  Future<List<Map<String, dynamic>>> search(
    FeelingSearchQuery query, {
    required bool modelReady,
  }) async {
    final sw = Stopwatch()..start();
    if (kDebugMode) debugPrint('[AISearch][T+0ms] search_button_pressed');
    if (query.isEmpty) return [];

    // 検索対象種別で分岐（novel パスは既存挙動を維持）。
    if (query.workType == WorkType.illust) {
      return _searchIllust(query, modelReady: modelReady);
    }

    final db = await DatabaseService().database;
    if (kDebugMode) {
      debugPrint('[AISearch][T+${sw.elapsedMilliseconds}ms] db_ready');
    }

    // ---- Step A: hard filter ----
    // novels テーブルに対する SQL 絞り込み条件を構築
    final where = <String>[];
    final whereArgs = <Object>[];

    switch (query.r18Mode) {
      case R18Mode.all:
        break;
      case R18Mode.includeR18:
        break; // 絞り込みなし（R-18 を含む）
      case R18Mode.safeOnly:
        where.add('(x_restrict IS NULL OR x_restrict = 0)');
        break;
      case R18Mode.r18Only:
        where.add('x_restrict = 1');
        break;
    }

    switch (query.aiMode) {
      case AiMode.all:
        break;
      case AiMode.excludeAi:
        where.add('(novel_ai_type IS NULL OR novel_ai_type = 0)');
        break;
      case AiMode.aiOnly:
        where.add('novel_ai_type != 0');
        break;
    }

    if (query.minBookmarks != null) {
      where.add('total_bookmarks >= ?');
      whereArgs.add(query.minBookmarks!);
    }
    if (query.minTextLength != null) {
      where.add('text_length >= ?');
      whereArgs.add(query.minTextLength!);
    }
    if (query.maxTextLength != null) {
      where.add('(text_length IS NULL OR text_length <= ?)');
      whereArgs.add(query.maxTextLength!);
    }

    // モデル準備状況
    final embeddingService = EmbeddingService();
    final bool canSemantic = modelReady && embeddingService.isInitialized;

    // ---- Step B: candidate retrieval ----
    final Map<int, _CandidateScore> candidates = {};

    // B-1: semantic candidate
    double? userNorm;
    if (canSemantic && query.hasSemantic) {
      try {
        if (kDebugMode) {
          debugPrint(
            '[AISearch][T+${sw.elapsedMilliseconds}ms] before_encode_query',
          );
        }
        final queryEmbedding = await embeddingService.encodeQuery(
          query.semanticText,
        );
        userNorm = _vectorNorm(queryEmbedding);
        if (kDebugMode) {
          debugPrint(
            '[AISearch][T+${sw.elapsedMilliseconds}ms] after_encode_query',
          );
        }
        if (userNorm > 0) {
          final semanticRows = await searchNovelsByEmbedding(
            db: db,
            userEmbedding: queryEmbedding,
            limit: query.highPrecision
                ? FeelingScoreWeights.candidatePoolHighPrecision
                : FeelingScoreWeights.candidatePool,
            minSimilarity: 0.0, // 全候補を取得し、後でスコア化
          );
          for (final row in semanticRows) {
            final id = row['id'] as int? ?? row['work_id'] as int?;
            if (id == null) continue;
            if (!_passHardFilterLocal(row, query)) continue;
            final sim = (row['similarity'] as num?)?.toDouble() ?? 0.0;
            candidates[id] = _CandidateScore(
              workId: id,
              row: row,
              semantic: sim,
            );
          }
        }
      } catch (e) {
        debugPrint('[HybridSearch] semantic 検索失敗（lexical のみ継続）: $e');
      }
    }

    // B-2: lexical candidate
    if (query.hasHardFilter || query.hasSemantic) {
      if (kDebugMode) {
        debugPrint('[AISearch][T+${sw.elapsedMilliseconds}ms] before_lexical');
      }
      final lexicalRows = await searchNovelsLexical(db: db, query: query);
      if (kDebugMode) {
        debugPrint('[AISearch][T+${sw.elapsedMilliseconds}ms] after_lexical');
      }
      for (final row in lexicalRows) {
        final id = row['id'] as int?;
        if (id == null) continue;
        if (!_passHardFilterLocal(row, query)) continue;
        final existing = candidates[id];
        if (existing == null) {
          candidates[id] = _CandidateScore(workId: id, row: row, semantic: 0.0);
        } else {
          existing.lexicalHit = true;
        }
      }
    }

    if (candidates.isEmpty) return [];

    // ---- Step C: merge & Step D: score ----
    if (kDebugMode) {
      debugPrint(
        '[AISearch][T+${sw.elapsedMilliseconds}ms] before_merge_score',
      );
    }
    final results = <Map<String, dynamic>>[];
    for (final c in candidates.values) {
      final row = c.row;
      final tags = _parseTags(row['tags_json']);

      // keyword score: must/should/exclude の判定
      final title = (row['title'] as String? ?? '');
      final desc = (row['description'] as String? ?? '');
      final tagText = tags.join(' ');
      final haystack = '$title $desc $tagText'.toLowerCase();

      int mustHit = 0;
      for (final k in query.mustKeywords) {
        if (k.trim().isNotEmpty && haystack.contains(k.trim().toLowerCase())) {
          mustHit++;
        }
      }
      int shouldHit = 0;
      for (final k in query.shouldKeywords) {
        if (k.trim().isNotEmpty && haystack.contains(k.trim().toLowerCase())) {
          shouldHit++;
        }
      }
      int excludeHit = 0;
      for (final k in query.excludeKeywords) {
        if (k.trim().isNotEmpty && haystack.contains(k.trim().toLowerCase())) {
          excludeHit++;
        }
      }

      // tag match score
      int exactHit = 0;
      for (final t in query.exactTags) {
        if (t.trim().isNotEmpty && tags.contains(t.trim())) exactHit++;
      }
      int partialHit = 0;
      for (final t in query.partialTags) {
        if (t.trim().isNotEmpty &&
            tags.any(
              (tag) => tag.toLowerCase().contains(t.trim().toLowerCase()),
            )) {
          partialHit++;
        }
      }

      // must が全部揃わない、または exclude に触れたら除外（hard drop）
      final mustOk =
          query.mustKeywords.isEmpty || mustHit == query.mustKeywords.length;
      final excludeOk =
          excludeHit == 0 &&
          !tags.any(
            (tag) => query.excludeKeywords.any(
              (k) =>
                  k.trim().isNotEmpty &&
                  tag.toLowerCase() == k.trim().toLowerCase(),
            ),
          );
      if (!mustOk || !excludeOk) continue;

      // スコア正規化
      final semanticScore = c.semantic.clamp(0.0, 1.0);
      final keywordScore =
          query.mustKeywords.isEmpty && query.shouldKeywords.isEmpty
          ? (c.lexicalHit ? 1.0 : 0.0)
          : (mustHit + shouldHit) /
                (query.mustKeywords.length + query.shouldKeywords.length).clamp(
                  1,
                  9999,
                );
      final tagScoreRaw =
          (exactHit + partialHit * 0.5) /
          (query.exactTags.length + query.partialTags.length).clamp(1, 9999);
      final tagMatchScore = tagScoreRaw.clamp(0.0, 1.0);

      // metadata score: 数値条件クリアの度合い（0.0〜1.0）
      double metadataScore = 0.0;
      int metaCount = 0;
      int metaOk = 0;
      if (query.minBookmarks != null) {
        metaCount++;
        if ((row['total_bookmarks'] as int? ?? 0) >= query.minBookmarks!) {
          metaOk++;
        }
      }
      if (query.minTextLength != null) {
        metaCount++;
        if ((row['text_length'] as int? ?? 0) >= query.minTextLength!) metaOk++;
      }
      if (query.maxTextLength != null) {
        metaCount++;
        if ((row['text_length'] as int? ?? 0) <= query.maxTextLength!) metaOk++;
      }
      if (metaCount > 0) metadataScore = metaOk / metaCount;

      // 表示スコアは embedding の生 semanticScore をそのまま使う（合成廃止）。
      // keyword/tag/metadata は explanation 用に計算のみ行い、finalScore には寄与しない。
      double finalScore = semanticScore.clamp(0.0, 1.0);
      // excludeHit はドロップ済み（上の mustOk/excludeOk 判定で continue 済み）のため
      // ここでのペナルティ適用は不要。互換のため定数のみ参照。
      assert(FeelingScoreWeights.excludePenalty == 0.0);

      // explanation
      final explanations = <String>[];
      if (c.semantic > 0.05) {
        explanations.add('意味近め (${(c.semantic * 100).round()}%)');
      }
      if (exactHit > 0) {
        explanations.add('タグ一致: ${query.exactTags.take(exactHit).join(', ')}');
      } else if (partialHit > 0) {
        explanations.add(
          'タグ部分一致: ${query.partialTags.take(partialHit).join(', ')}',
        );
      }
      if (mustHit > 0) {
        explanations.add(
          '必須キーワード一致: ${query.mustKeywords.take(mustHit).join(', ')}',
        );
      }
      if (metaOk == metaCount && metaCount > 0) {
        explanations.add('ブクマ/文字数条件クリア');
      }
      if (excludeHit == 0 && query.excludeKeywords.isNotEmpty) {
        explanations.add('除外条件なし');
      }
      if (explanations.isEmpty) explanations.add('キーワード/タグ緩やか一致');

      final merged = <String, dynamic>{
        ...row,
        'finalScore': finalScore,
        'rerankApplied': false,
        'rerankScore': null,
        'semanticScore': semanticScore,
        'keywordScore': keywordScore,
        'tagMatchScore': tagMatchScore,
        'metadataScore': metadataScore,
        'explanation': explanations.join(' ・ '),
        'is_keyword_match': c.lexicalHit ? 1 : 0,
      };
      results.add(merged);
    }

    // ---- rerank (high precision) ----
    // reranker 未導入 / 失敗時は例外を握りつぶし、元のスコアでフォールバック。
    if (kDebugMode) {
      debugPrint('[AISearch][T+${sw.elapsedMilliseconds}ms] after_merge_score');
    }
    if (query.highPrecision) {
      try {
        if (kDebugMode) {
          debugPrint('[AISearch][T+${sw.elapsedMilliseconds}ms] before_rerank');
        }
        final available = await RerankService().isAvailable;
        if (available) {
          // 順位改善のため上位 N 件のみ rerank を適用（コスト抑制）。
          final rerankTargets = List<Map<String, dynamic>>.from(results)
            ..sort(
              (a, b) => (b['finalScore'] as double? ?? 0.0).compareTo(
                a['finalScore'] as double? ?? 0.0,
              ),
            );
          final top = rerankTargets
              .take(FeelingScoreWeights.rerankCandidateLimit)
              .toList();
          final candidates = top.map((r) {
            final id = r['id'] as int? ?? 0;
            final docText = _buildRerankDocument(r);
            return RerankCandidate(
              workId: id,
              documentText: docText,
              baseScore: (r['finalScore'] as double?) ?? 0.0,
            );
          }).toList();
          final reranked = await RerankService().rerank(
            query: query.semanticText,
            candidates: candidates,
          );
          // rerankScore は順位付け（ソート）用。
          // 表示スコア(finalScore)は上書きせず、ラベルは semantic から出す。
          for (final c in reranked) {
            if (c.rerankApplied && c.rerankScore != null) {
              final idx = results.indexWhere(
                (r) => (r['id'] as int? ?? 0) == c.workId,
              );
              if (idx >= 0) {
                results[idx]['rerankScore'] = c.rerankScore!;
                results[idx]['rerankApplied'] = true;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[HybridSearch] rerank 失敗（元スコアで継続）: $e');
      }
    }
    if (kDebugMode) {
      debugPrint('[AISearch][T+${sw.elapsedMilliseconds}ms] after_rerank');
    }

    // ---- sort ----
    // rerank 適用時は rerankScore を、それ以外は finalScore をソートキーにする。
    // 表示用ラベル(semantic/lexical)とは独立して順位付けを行う。
    // ソートキー: rerank ON なら rerankScore、それ以外は生 semanticScore。
    double sortKey(Map<String, dynamic> r) {
      final rerankApplied = (r['rerankApplied'] as bool? ?? false);
      if (rerankApplied && r['rerankScore'] != null) {
        return r['rerankScore'] as double;
      }
      return (r['semanticScore'] as double? ?? 0.0);
    }

    switch (query.sortMode) {
      case SortMode.relevance:
        results.sort((a, b) => sortKey(b).compareTo(sortKey(a)));
        break;
      case SortMode.newest:
        results.sort(
          (a, b) => (b['create_date'] as String? ?? '').compareTo(
            a['create_date'] as String? ?? '',
          ),
        );
        break;
      case SortMode.bookmarks:
        results.sort(
          (a, b) => (b['total_bookmarks'] as int? ?? 0).compareTo(
            a['total_bookmarks'] as int? ?? 0,
          ),
        );
        break;
    }

    final topK = query.topK.clamp(1, 1000);
    if (kDebugMode) {
      debugPrint(
        '[AISearch][T+${sw.elapsedMilliseconds}ms] search_return_to_ui '
        'count=${results.take(topK).length}',
      );
    }
    return List<Map<String, dynamic>>.from(results.take(topK));
  }

  /// イラスト意味検索（illust モード）。
  ///
  /// novel モードと同一のパイプライン（Step A/B/C/D + rerank + sort）を
  /// illusts / illust_embeddings テーブルに対して適用する。
  /// novel 側のスコア計算・挙動は一切変更しない。
  Future<List<Map<String, dynamic>>> _searchIllust(
    FeelingSearchQuery query, {
    required bool modelReady,
  }) async {
    if (query.isEmpty) return [];

    final db = await DatabaseService().database;

    // ---- Step A: hard filter（SQL 絞り込みは local 判定へ移譲）----
    final where = <String>[];
    final whereArgs = <Object>[];

    switch (query.r18Mode) {
      case R18Mode.all:
      case R18Mode.includeR18:
        break;
      case R18Mode.safeOnly:
        where.add('(x_restrict IS NULL OR x_restrict = 0)');
        break;
      case R18Mode.r18Only:
        where.add('x_restrict = 1');
        break;
    }
    switch (query.aiMode) {
      case AiMode.all:
        break;
      case AiMode.excludeAi:
        where.add('(novel_ai_type IS NULL OR novel_ai_type = 0)');
        break;
      case AiMode.aiOnly:
        where.add('novel_ai_type != 0');
        break;
    }
    if (query.minBookmarks != null) {
      where.add('total_bookmarks >= ?');
      whereArgs.add(query.minBookmarks!);
    }

    final embeddingService = EmbeddingService();
    final bool canSemantic = modelReady && embeddingService.isInitialized;

    // ---- Step B: candidate retrieval ----
    final Map<int, _CandidateScore> candidates = {};

    double? userNorm;
    if (canSemantic && query.hasSemantic) {
      try {
        final queryEmbedding = await embeddingService.encodeQuery(
          query.semanticText,
        );
        userNorm = _vectorNorm(queryEmbedding);
        if (userNorm > 0) {
          final semanticRows = await searchIllustsByEmbedding(
            db: db,
            userEmbedding: queryEmbedding,
            limit: query.highPrecision
                ? FeelingScoreWeights.candidatePoolHighPrecision
                : FeelingScoreWeights.candidatePool,
            minSimilarity: 0.0,
          );
          for (final row in semanticRows) {
            final id = row['id'] as int?;
            if (id == null) continue;
            if (!_passHardFilterLocal(row, query)) continue;
            final sim = (row['similarity'] as num?)?.toDouble() ?? 0.0;
            candidates[id] = _CandidateScore(
              workId: id,
              row: row,
              semantic: sim,
            );
          }
        }
      } catch (e) {
        debugPrint('[HybridSearch][illust] semantic 検索失敗（lexical のみ継続）: $e');
      }
    }

    // B-2: lexical candidate
    if (query.hasHardFilter || query.hasSemantic) {
      final lexicalRows = await searchIllustsLexical(db: db, query: query);
      for (final row in lexicalRows) {
        final id = row['id'] as int?;
        if (id == null) continue;
        if (!_passHardFilterLocal(row, query)) continue;
        final existing = candidates[id];
        if (existing == null) {
          candidates[id] = _CandidateScore(workId: id, row: row, semantic: 0.0);
        } else {
          existing.lexicalHit = true;
        }
      }
    }

    if (candidates.isEmpty) return [];

    // ---- Step C / D: merge & score ----
    final results = <Map<String, dynamic>>[];
    for (final c in candidates.values) {
      final row = c.row;
      final tags = _parseTags(row['tags_json']);
      final title = (row['title'] as String? ?? '');
      final desc = (row['description'] as String? ?? '');
      final tagText = tags.join(' ');
      final haystack = '$title $desc $tagText'.toLowerCase();

      int mustHit = 0;
      for (final k in query.mustKeywords) {
        if (k.trim().isNotEmpty && haystack.contains(k.trim().toLowerCase())) {
          mustHit++;
        }
      }
      int shouldHit = 0;
      for (final k in query.shouldKeywords) {
        if (k.trim().isNotEmpty && haystack.contains(k.trim().toLowerCase())) {
          shouldHit++;
        }
      }
      int excludeHit = 0;
      for (final k in query.excludeKeywords) {
        if (k.trim().isNotEmpty && haystack.contains(k.trim().toLowerCase())) {
          excludeHit++;
        }
      }

      int exactHit = 0;
      for (final t in query.exactTags) {
        if (t.trim().isNotEmpty && tags.contains(t.trim())) exactHit++;
      }
      int partialHit = 0;
      for (final t in query.partialTags) {
        if (t.trim().isNotEmpty &&
            tags.any(
              (tag) => tag.toLowerCase().contains(t.trim().toLowerCase()),
            )) {
          partialHit++;
        }
      }

      final mustOk =
          query.mustKeywords.isEmpty || mustHit == query.mustKeywords.length;
      final excludeOk =
          excludeHit == 0 &&
          !tags.any(
            (tag) => query.excludeKeywords.any(
              (k) =>
                  k.trim().isNotEmpty &&
                  tag.toLowerCase() == k.trim().toLowerCase(),
            ),
          );
      if (!mustOk || !excludeOk) continue;

      final semanticScore = c.semantic.clamp(0.0, 1.0);
      final keywordScore =
          query.mustKeywords.isEmpty && query.shouldKeywords.isEmpty
          ? (c.lexicalHit ? 1.0 : 0.0)
          : (mustHit + shouldHit) /
                (query.mustKeywords.length + query.shouldKeywords.length).clamp(
                  1,
                  9999,
                );
      final tagScoreRaw =
          (exactHit + partialHit * 0.5) /
          (query.exactTags.length + query.partialTags.length).clamp(1, 9999);
      final tagMatchScore = tagScoreRaw.clamp(0.0, 1.0);

      double metadataScore = 0.0;
      int metaCount = 0;
      int metaOk = 0;
      if (query.minBookmarks != null) {
        metaCount++;
        if ((row['total_bookmarks'] as int? ?? 0) >= query.minBookmarks!) {
          metaOk++;
        }
      }
      if (metaCount > 0) metadataScore = metaOk / metaCount;

      double finalScore = semanticScore.clamp(0.0, 1.0);
      assert(FeelingScoreWeights.excludePenalty == 0.0);

      final explanations = <String>[];
      if (c.semantic > 0.05) {
        explanations.add('意味近め (${(c.semantic * 100).round()}%)');
      }
      if (exactHit > 0) {
        explanations.add('タグ一致: ${query.exactTags.take(exactHit).join(', ')}');
      } else if (partialHit > 0) {
        explanations.add(
          'タグ部分一致: ${query.partialTags.take(partialHit).join(', ')}',
        );
      }
      if (mustHit > 0) {
        explanations.add(
          '必須キーワード一致: ${query.mustKeywords.take(mustHit).join(', ')}',
        );
      }
      if (metaOk == metaCount && metaCount > 0) {
        explanations.add('ブクマ条件クリア');
      }
      if (excludeHit == 0 && query.excludeKeywords.isNotEmpty) {
        explanations.add('除外条件なし');
      }
      if (explanations.isEmpty) explanations.add('キーワード/タグ緩やか一致');

      final merged = <String, dynamic>{
        ...row,
        'finalScore': finalScore,
        'rerankApplied': false,
        'rerankScore': null,
        'semanticScore': semanticScore,
        'keywordScore': keywordScore,
        'tagMatchScore': tagMatchScore,
        'metadataScore': metadataScore,
        'explanation': explanations.join(' ・ '),
        'is_keyword_match': c.lexicalHit ? 1 : 0,
      };
      results.add(merged);
    }

    // ---- rerank (high precision) ----
    if (query.highPrecision) {
      try {
        final available = await RerankService().isAvailable;
        if (available) {
          final rerankTargets = List<Map<String, dynamic>>.from(results)
            ..sort(
              (a, b) => (b['finalScore'] as double? ?? 0.0).compareTo(
                a['finalScore'] as double? ?? 0.0,
              ),
            );
          final top = rerankTargets
              .take(FeelingScoreWeights.rerankCandidateLimit)
              .toList();
          final rerankCandidates = top.map((r) {
            final id = r['id'] as int? ?? 0;
            final docText = _buildIllustRerankDocument(r);
            return RerankCandidate(
              workId: id,
              documentText: docText,
              baseScore: (r['finalScore'] as double?) ?? 0.0,
            );
          }).toList();
          final reranked = await RerankService().rerank(
            query: query.semanticText,
            candidates: rerankCandidates,
          );
          for (final c in reranked) {
            if (c.rerankApplied && c.rerankScore != null) {
              final idx = results.indexWhere(
                (r) => (r['id'] as int? ?? 0) == c.workId,
              );
              if (idx >= 0) {
                results[idx]['rerankScore'] = c.rerankScore!;
                results[idx]['rerankApplied'] = true;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[HybridSearch][illust] rerank 失敗（元スコアで継続）: $e');
      }
    }

    // ---- sort ----
    double sortKey(Map<String, dynamic> r) {
      final rerankApplied = (r['rerankApplied'] as bool? ?? false);
      if (rerankApplied && r['rerankScore'] != null) {
        return r['rerankScore'] as double;
      }
      return (r['semanticScore'] as double? ?? 0.0);
    }

    switch (query.sortMode) {
      case SortMode.relevance:
        results.sort((a, b) => sortKey(b).compareTo(sortKey(a)));
        break;
      case SortMode.newest:
        results.sort(
          (a, b) => (b['create_date'] as String? ?? '').compareTo(
            a['create_date'] as String? ?? '',
          ),
        );
        break;
      case SortMode.bookmarks:
        results.sort(
          (a, b) => (b['total_bookmarks'] as int? ?? 0).compareTo(
            a['total_bookmarks'] as int? ?? 0,
          ),
        );
        break;
    }

    final topK = query.topK.clamp(1, 1000);
    return List<Map<String, dynamic>>.from(results.take(topK));
  }

  /// novels 行が hard filter の数値/フラグ条件を満たすか（SQL 補完として local 判定）。
  bool _passHardFilterLocal(
    Map<String, dynamic> row,
    FeelingSearchQuery query,
  ) {
    switch (query.r18Mode) {
      case R18Mode.safeOnly:
        if ((row['x_restrict'] as int? ?? 0) != 0) return false;
        break;
      case R18Mode.r18Only:
        if ((row['x_restrict'] as int? ?? 0) != 1) return false;
        break;
      case R18Mode.all:
      case R18Mode.includeR18:
        break;
    }
    switch (query.aiMode) {
      case AiMode.excludeAi:
        if ((row['novel_ai_type'] as int? ?? 0) != 0) return false;
        break;
      case AiMode.aiOnly:
        if ((row['novel_ai_type'] as int? ?? 0) == 0) return false;
        break;
      case AiMode.all:
        break;
    }
    if (query.minBookmarks != null &&
        (row['total_bookmarks'] as int? ?? 0) < query.minBookmarks!) {
      return false;
    }
    final len = row['text_length'] as int? ?? 0;
    if (query.minTextLength != null && len < query.minTextLength!) return false;
    if (query.maxTextLength != null && len > query.maxTextLength!) return false;
    return true;
  }

  List<String> _parseTags(dynamic tagsJson) {
    if (tagsJson == null) return const [];
    try {
      final decoded = jsonDecode(tagsJson as String) as List<dynamic>;
      return decoded.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  double _vectorNorm(List<double> vec) {
    double sum = 0;
    for (final v in vec) {
      sum += v * v;
    }
    return math.sqrt(sum);
  }

  /// rerank 用の文書テキストを組み立てる（embedding 用文書と同じ形式）。
  String _buildRerankDocument(Map<String, dynamic> row) {
    final title = (row['title'] as String? ?? '');
    final tags = _parseTags(row['tags_json']);
    final caption = (row['description'] as String? ?? '');
    return buildNovelDocumentTextRaw(
      title: title,
      tags: tags,
      caption: caption,
    );
  }

  /// イラスト用 rerank 文書テキスト（illust モード）。
  String _buildIllustRerankDocument(Map<String, dynamic> row) {
    final title = (row['title'] as String? ?? '');
    final tags = _parseTags(row['tags_json']);
    final caption = (row['description'] as String? ?? '');
    return buildIllustDocumentTextRaw(
      title: title,
      tags: tags,
      caption: caption,
    );
  }
}

class _CandidateScore {
  _CandidateScore({
    required this.workId,
    required this.row,
    required this.semantic,
  });

  final int workId;
  final Map<String, dynamic> row;
  final double semantic;
  bool lexicalHit = false;
}
