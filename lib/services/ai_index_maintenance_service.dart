import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'database_service.dart';
import 'embedding_service.dart';
import 'illust_document_text.dart';
import 'novel_document_text.dart';
import 'pixiv_api_service.dart';
import 'ruri_model_manager.dart';

/// Google Drive 復元後等に、AI 検索（フィーリング発掘）に使えるデータの状態を
/// 診断し、ローカルデータ・API から修復するサービス。
///
/// データを3種類に分けて扱う（タスク要件）:
/// - A. 小説メタデータ: novels
/// - B. 小説本文: novel_text / novels.text
/// - C. AIインデックス: novel_embeddings
class AiIndexMaintenanceService {
  static final AiIndexMaintenanceService _instance =
      AiIndexMaintenanceService._internal();
  factory AiIndexMaintenanceService() => _instance;
  AiIndexMaintenanceService._internal();

  /// 診断結果を保持する不変データクラス。
  AiIndexDiagnosisResult diagnose() => _lastDiagnosis;
  AiIndexDiagnosisResult _lastDiagnosis = const AiIndexDiagnosisResult.empty();

  /// 全作品を診断する（read-only 集計）。
  ///
  /// embedding 次元は JSON decode して確認するが、壊れた1件で全体を落とさない。
  Future<AiIndexDiagnosisResult> diagnoseAll() async {
    final db = await DatabaseService().database;

    final novelsRows = await db.query('novels');
    final textRows = await db.query('novel_text', columns: ['work_id']);
    final embRows = await db.query('novel_embeddings');

    final illustRows = await db.query('illusts');
    final illustEmbRows = await db.query('illust_embeddings');

    final totalNovels = novelsRows.length;
    final textAvailable = textRows.length;

    // アクティブモデルの仕様で互換判定（モデル切り替え時に次元が変わるため）。
    final spec = await RuriModelManager().getActiveSpec();
    final int embedDim = spec.dimension;
    final String modelId = spec.id;
    final int modelVersion = RuriModelSpec.modelVersion;
    final int prefixVersion = RuriModelSpec.prefixSchemeVersion;

    int embedAvailable = 0;
    int embedCompatible = 0;
    int embedMissing = 0; // novel_embeddings に行が無い（novels に対して）
    int embedBroken = 0; // JSON decode 不可
    int embedDimMismatch = 0;
    int modelIdMismatch = 0;
    int modelVersionMismatch = 0;
    int prefixMismatch = 0;

    // novel_embeddings 行を work_id に紐づける
    final embByWorkId = <int, Map<String, dynamic>>{};
    for (final r in embRows) {
      final id = r['work_id'] as int?;
      if (id != null) embByWorkId[id] = r;
    }

    for (final novel in novelsRows) {
      final id = novel['id'] as int? ?? 0;
      final emb = embByWorkId[id];
      if (emb == null) {
        embedMissing++;
        continue;
      }
      embedAvailable++;
      final rawId = emb['model_id'] as String? ?? '';
      final rawVer = emb['model_version'] as int? ?? 0;
      final rawPrefix = emb['prefix_scheme_version'] as int? ?? 0;
      final rawEmb = emb['embedding'];
      if (rawId != modelId) modelIdMismatch++;
      if (rawVer != modelVersion) modelVersionMismatch++;
      if (rawPrefix != prefixVersion) prefixMismatch++;
      // 互換 = model_id/version/prefix 全一致
      final bool compatible =
          rawId == modelId &&
          rawVer == modelVersion &&
          rawPrefix == prefixVersion;
      if (!compatible) continue;
      // embedding JSON の正当性を確認
      if (rawEmb is! String || rawEmb.isEmpty) {
        embedBroken++;
        continue;
      }
      try {
        final decoded = jsonDecode(rawEmb) as List<dynamic>;
        if (decoded.length != embedDim) {
          embedDimMismatch++;
          continue;
        }
      } catch (_) {
        embedBroken++;
        continue;
      }
      embedCompatible++;
    }

    int textLengthZero = 0;
    int pageCountZero = 0;
    int metaMissing = 0; // author_name / cover_url が空
    for (final novel in novelsRows) {
      final tl = novel['text_length'] as int? ?? 0;
      final pc = novel['page_count'] as int? ?? 0;
      final an = (novel['author_name'] as String? ?? '').toString();
      final cu = (novel['cover_url'] as String? ?? '').toString();
      if (tl <= 0) textLengthZero++;
      if (pc <= 0) pageCountZero++;
      if (an.isEmpty || cu.isEmpty) metaMissing++;
    }

    // ---- イラスト側の集計（novel と同一アルゴリズム） ----
    final int totalIllusts = illustRows.length;
    int illustEmbedAvailable = 0;
    int illustEmbedCompatible = 0;
    int illustEmbedMissing = 0;
    int illustEmbedBroken = 0;
    int illustEmbedDimMismatch = 0;
    int illustModelIdMismatch = 0;
    int illustModelVersionMismatch = 0;
    int illustPrefixMismatch = 0;

    final illustEmbByWorkId = <int, Map<String, dynamic>>{};
    for (final r in illustEmbRows) {
      final id = r['work_id'] as int?;
      if (id != null) illustEmbByWorkId[id] = r;
    }

    for (final illust in illustRows) {
      final id = illust['id'] as int? ?? 0;
      final emb = illustEmbByWorkId[id];
      if (emb == null) {
        illustEmbedMissing++;
        continue;
      }
      illustEmbedAvailable++;
      final rawId = emb['model_id'] as String? ?? '';
      final rawVer = emb['model_version'] as int? ?? 0;
      final rawPrefix = emb['prefix_scheme_version'] as int? ?? 0;
      final rawEmb = emb['embedding'];
      if (rawId != modelId) illustModelIdMismatch++;
      if (rawVer != modelVersion) illustModelVersionMismatch++;
      if (rawPrefix != prefixVersion) illustPrefixMismatch++;
      final bool compatible =
          rawId == modelId &&
          rawVer == modelVersion &&
          rawPrefix == prefixVersion;
      if (!compatible) continue;
      if (rawEmb is! String || rawEmb.isEmpty) {
        illustEmbedBroken++;
        continue;
      }
      try {
        final decoded = jsonDecode(rawEmb) as List<dynamic>;
        if (decoded.length != embedDim) {
          illustEmbedDimMismatch++;
          continue;
        }
      } catch (_) {
        illustEmbedBroken++;
        continue;
      }
      illustEmbedCompatible++;
    }

    final result = AiIndexDiagnosisResult(
      totalNovels: totalNovels,
      textAvailable: textAvailable,
      embeddingAvailable: embedAvailable,
      embeddingCompatible: embedCompatible,
      embeddingMissing: embedMissing,
      embeddingBroken: embedBroken,
      embeddingDimMismatch: embedDimMismatch,
      modelIdMismatch: modelIdMismatch,
      modelVersionMismatch: modelVersionMismatch,
      prefixMismatch: prefixMismatch,
      textLengthZero: textLengthZero,
      pageCountZero: pageCountZero,
      metaMissing: metaMissing,
      totalIllusts: totalIllusts,
      illustEmbedAvailable: illustEmbedAvailable,
      illustEmbedCompatible: illustEmbedCompatible,
      illustEmbedMissing: illustEmbedMissing,
      illustEmbedBroken: illustEmbedBroken,
      illustEmbedDimMismatch: illustEmbedDimMismatch,
      illustModelIdMismatch: illustModelIdMismatch,
      illustModelVersionMismatch: illustModelVersionMismatch,
      illustPrefixMismatch: illustPrefixMismatch,
    );
    _lastDiagnosis = result;
    return result;
  }

  /// ローカルデータだけで修復可能な作品を修復する（API を呼ばない）。
  ///
  /// 優先順位:
  /// 1. novel_text 本文から text_length を再計算し、本文があれば embedding を再生成
  /// 2. novels の description/tags から embedding 文書を構築して再生成
  /// 3. 有効な embedding は再生成せず保持
  ///
  /// モデル未導入時は embedding 再生成をスキップし、[requireModel] に true を返す。
  /// [onProgress] で進捗を通知（UI を固めない）。[cancel] で中断可能。
  Future<AiIndexRepairResult> repairLocal({
    required Future<void> Function(int current, int total) onProgress,
    bool Function()? cancel,
  }) async {
    final db = await DatabaseService().database;
    final result = AiIndexRepairResult();

    final novelsRows = List<Map<String, dynamic>>.from(
      await db.query('novels'),
    );
    final total = novelsRows.length;
    result.totalTargets = total;
    debugPrint('[AiIndexRepair] repairLocal: totalTargets=$total');

    final bool modelReady = await RuriModelManager().isModelReady();
    final embeddingService = EmbeddingService();
    if (modelReady) {
      try {
        await embeddingService.initialize();
      } catch (e) {
        debugPrint('[AiIndexRepair] モデル初期化失敗: $e');
      }
    }
    final canEmbed = modelReady && embeddingService.isInitialized;

    final textMap = <int, String>{};
    final textRows = await db.query('novel_text', columns: ['work_id', 'text']);
    for (final r in textRows) {
      final id = r['work_id'] as int?;
      final t = r['text'] as String?;
      if (id != null && t != null) textMap[id] = t;
    }

    for (int i = 0; i < novelsRows.length; i++) {
      if (cancel != null && cancel()) break;
      final novel = novelsRows[i];
      final rawId = novel['id'];
      final int id = rawId is int
          ? rawId
          : (rawId is String ? int.tryParse(rawId) ?? 0 : 0);
      if (id <= 0) {
        result.skipped++;
        continue;
      }
      try {
        await _repairOneNovel(
          db: db,
          id: id,
          novelRow: novel,
          bodyText: textMap[id],
          canEmbed: canEmbed,
          embeddingService: embeddingService,
          result: result,
        );
      } catch (e) {
        debugPrint('[AiIndexRepair] workId=$id 失敗: $e');
        result.failed++;
      }
      await onProgress(i + 1, total);
    }

    if (!canEmbed && result.embeddingsRegenerated == 0) {
      result.requireModel = novelsRows.isNotEmpty;
    }
    // ---- イラスト側も同様に修復（進捗に計上） ----
    await _repairLocalIllust(
      db: db,
      canEmbed: canEmbed,
      embeddingService: embeddingService,
      result: result,
      onProgress: onProgress,
      cancel: cancel,
      baseProgress: total,
    );
    return result;
  }

  /// イラスト側のローカル修復（novel の repairLocal と同一アルゴリズム）。
  /// [baseProgress] は novel 側で既に処理した件数（進捗の連続性維持のため）。
  Future<void> _repairLocalIllust({
    required Database db,
    required bool canEmbed,
    required EmbeddingService embeddingService,
    required AiIndexRepairResult result,
    required Future<void> Function(int current, int total) onProgress,
    bool Function()? cancel,
    int baseProgress = 0,
  }) async {
    final illustRows = List<Map<String, dynamic>>.from(
      await db.query('illusts'),
    );
    final int illustTotal = illustRows.length;
    final int total = baseProgress + illustTotal;
    debugPrint('[AiIndexRepair] _repairLocalIllust: illustTotal=$illustTotal');

    for (int i = 0; i < illustRows.length; i++) {
      if (cancel != null && cancel()) break;
      final row = illustRows[i];
      final rawId = row['id'];
      final int id = rawId is int
          ? rawId
          : (rawId is String ? int.tryParse(rawId) ?? 0 : 0);
      if (id <= 0) {
        result.illustSkipped++;
        continue;
      }
      try {
        await _repairOneIllust(
          db: db,
          id: id,
          illustRow: row,
          canEmbed: canEmbed,
          embeddingService: embeddingService,
          result: result,
        );
      } catch (e) {
        debugPrint('[AiIndexRepair] illust workId=$id 失敗: $e');
        result.illustFailed++;
      }
      await onProgress(baseProgress + i + 1, total);
    }

    if (!canEmbed &&
        result.illustEmbeddingsRegenerated == 0 &&
        illustTotal > 0) {
      result.requireModel = true;
    }
  }

  Future<void> _repairOneIllust({
    required Database db,
    required int id,
    required Map<String, dynamic> illustRow,
    required bool canEmbed,
    required EmbeddingService embeddingService,
    required AiIndexRepairResult result,
  }) async {
    bool changed = false;

    // ---- 埋め込み: 有効なら保持、欠落/破損/不一致なら再生成 ----
    final embRow = await db.query(
      'illust_embeddings',
      where: 'work_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    bool needEmbed = false;
    if (embRow.isEmpty) {
      needEmbed = true;
    } else {
      final e = embRow.first;
      final rawId = e['model_id'] as String? ?? '';
      final rawVer = e['model_version'] as int? ?? 0;
      final rawPrefix = e['prefix_scheme_version'] as int? ?? 0;
      final rawEmb = e['embedding'];
      if (rawId != RuriModelManager.embeddingModelId ||
          rawVer != RuriModelSpec.modelVersion ||
          rawPrefix != RuriModelSpec.prefixSchemeVersion) {
        needEmbed = true;
      } else if (rawEmb is! String || rawEmb.isEmpty) {
        needEmbed = true;
      } else {
        try {
          final decoded = jsonDecode(rawEmb) as List<dynamic>;
          if (decoded.length != RuriModelManager.embeddingDimension) {
            needEmbed = true;
          }
        } catch (_) {
          needEmbed = true;
        }
      }
    }

    if (needEmbed) {
      if (!canEmbed) {
        result.illustSkipped++;
        return;
      }
      // 文書構築: illusts 行から title/tags/caption を抽出
      final docText = _buildIllustDocumentTextFromRow(illustRow);
      if (docText.isEmpty) {
        result.illustSkipped++;
        return;
      }
      final vector = await embeddingService.encodeDocument(docText);
      await db.insert('illust_embeddings', {
        'work_id': id,
        'embedding': jsonEncode(vector.toList()),
        'model_id': RuriModelManager.embeddingModelId,
        'model_version': RuriModelManager.embeddingModelVersion,
        'prefix_scheme_version': RuriModelManager.prefixSchemeVersion,
        'embedding_dim': RuriModelManager.embeddingDimension,
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      result.illustEmbeddingsRegenerated++;
      changed = true;
    }

    if (changed) {
      result.illustMetaUpdated++;
    } else {
      result.illustSkipped++;
    }
  }

  /// illusts 行から埋め込み文書を構築する。
  String _buildIllustDocumentTextFromRow(Map<String, dynamic> illustRow) {
    final title = illustRow['title'] as String? ?? '';
    List<String> tags = const <String>[];
    final tagsJson = illustRow['tags_json'] as String?;
    if (tagsJson != null && tagsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(tagsJson) as List<dynamic>;
        tags = decoded
            .map(
              (e) => e is Map<String, dynamic>
                  ? (e['name'] as String? ?? '')
                  : e.toString(),
            )
            .where((t) => t.isNotEmpty)
            .toList();
      } catch (_) {
        // ignore
      }
    }
    final caption = illustRow['description'] as String? ?? '';
    return buildIllustDocumentTextRaw(
      title: title,
      tags: tags,
      caption: caption,
    );
  }

  Future<void> _repairOneNovel({
    required Database db,
    required int id,
    required Map<String, dynamic> novelRow,
    required String? bodyText,
    required bool canEmbed,
    required EmbeddingService embeddingService,
    required AiIndexRepairResult result,
  }) async {
    bool changed = false;

    // ---- メタデータ: text_length / page_count の再計算 ----
    final int currentTl = novelRow['text_length'] as int? ?? 0;
    int newTl = currentTl;
    if (currentTl <= 0 && bodyText != null && bodyText.isNotEmpty) {
      newTl = bodyText.length;
    }
    if (newTl != currentTl) {
      await db.update(
        'novels',
        {'text_length': newTl},
        where: 'id = ?',
        whereArgs: [id],
      );
      changed = true;
    }

    // ---- 埋め込み: 有効なら保持、欠落/破損/不一致なら再生成 ----
    final embRow = await db.query(
      'novel_embeddings',
      where: 'work_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    bool needEmbed = false;
    if (embRow.isEmpty) {
      needEmbed = true;
    } else {
      final e = embRow.first;
      final rawId = e['model_id'] as String? ?? '';
      final rawVer = e['model_version'] as int? ?? 0;
      final rawPrefix = e['prefix_scheme_version'] as int? ?? 0;
      final rawEmb = e['embedding'];
      if (rawId != RuriModelManager.embeddingModelId ||
          rawVer != RuriModelSpec.modelVersion ||
          rawPrefix != RuriModelSpec.prefixSchemeVersion) {
        needEmbed = true;
      } else if (rawEmb is! String || rawEmb.isEmpty) {
        needEmbed = true;
      } else {
        try {
          final decoded = jsonDecode(rawEmb) as List<dynamic>;
          if (decoded.length != RuriModelManager.embeddingDimension) {
            needEmbed = true;
          }
        } catch (_) {
          needEmbed = true;
        }
      }
    }

    if (needEmbed) {
      if (!canEmbed) {
        // モデル未導入: 再生成不可 → スキップ（API 補完フェーズでも不可）
        result.skipped++;
        if (changed) result.metaUpdated++;
        return;
      }
      // 文書構築: 本文優先、なければ description/tags から
      final docText = _buildDocumentTextFromRow(novelRow, bodyText);
      if (docText.isEmpty) {
        result.skipped++;
        if (changed) result.metaUpdated++;
        return;
      }
      final vector = await embeddingService.encodeDocument(docText);
      await db.insert('novel_embeddings', {
        'work_id': id,
        'embedding': jsonEncode(vector.toList()),
        'model_id': RuriModelManager.embeddingModelId,
        'model_version': RuriModelManager.embeddingModelVersion,
        'prefix_scheme_version': RuriModelManager.prefixSchemeVersion,
        'embedding_dim': RuriModelManager.embeddingDimension,
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      result.embeddingsRegenerated++;
      changed = true;
    }

    if (changed) {
      result.metaUpdated++;
    } else {
      result.skipped++;
    }
  }

  /// novels 行 + 本文から埋め込み文書を構築する（本文なしでも可）。
  String _buildDocumentTextFromRow(
    Map<String, dynamic> novelRow,
    String? bodyText,
  ) {
    final title = novelRow['title'] as String? ?? '';
    List<String> tags = const <String>[];
    final tagsJson = novelRow['tags_json'] as String?;
    if (tagsJson != null && tagsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(tagsJson) as List<dynamic>;
        tags = decoded
            .map(
              (e) => e is Map<String, dynamic>
                  ? (e['name'] as String? ?? '')
                  : e.toString(),
            )
            .where((t) => t.isNotEmpty)
            .toList();
      } catch (_) {
        // ignore
      }
    }
    final description = novelRow['description'] as String? ?? '';
    return buildNovelDocumentTextRaw(
      title: title,
      tags: tags,
      caption: description,
      bodyText: bodyText,
    );
  }

  /// 不足情報を Pixiv API から補完する（ユーザーが明示実行時にのみ呼ぶ）。
  ///
  /// - 対象は「ローカル修復だけでは補えない作品」を呼び出し側が選別して渡す。
  /// - 自動大量リクエスト禁止: 呼び出し側で件数確認ダイアログを出す前提。
  /// - 逐次処理 + 400~700ms delay、作品単位 try-catch、認証切れ/削除/非公開は安全にスキップ。
  Future<AiIndexRepairResult> repairViaApi({
    required List<int> workIds,
    required Future<void> Function(int current, int total) onProgress,
    bool Function()? cancel,
    int delayMs = 550,
  }) async {
    final api = PixivApiService();
    final db = await DatabaseService().database;
    final result = AiIndexRepairResult();

    final bool modelReady = await RuriModelManager().isModelReady();
    final embeddingService = EmbeddingService();
    if (modelReady) {
      try {
        await embeddingService.initialize();
      } catch (e) {
        debugPrint('[AiIndexRepair] API補完: モデル初期化失敗: $e');
      }
    }
    final canEmbed = modelReady && embeddingService.isInitialized;

    int current = 0;
    result.totalTargets = workIds.length;
    debugPrint('[AiIndexRepair] repairViaApi: totalTargets=${workIds.length}');
    for (final id in workIds) {
      if (cancel != null && cancel()) break;
      current++;
      try {
        final novel = await api.getNovelById(id);
        await db.insert('novels', {
          'id': novel.id,
          'title': novel.title,
          'description': novel.caption,
          'author_id': novel.author.id,
          'author_name': novel.author.name,
          'series_id': novel.series?.id ?? 0,
          'series_order': novel.seriesOrder ?? 0,
          'text_length': novel.textLength,
          'tags': novel.tags.join(','),
          'tags_json': jsonEncode(novel.tags),
          'x_restrict': novel.xRestrict,
          'novel_ai_type': novel.aiType,
          'cover_url': novel.coverUrl,
          'page_count': novel.pageCount,
          'total_bookmarks': novel.totalBookmarks,
          'total_view': novel.totalView,
          'create_date': novel.createDate,
          'meta_json': jsonEncode({
            ...novel.toJson(),
            if (novel.series != null) 'series_title': novel.series!.title,
          }),
          'updated_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        result.metaUpdated++;

        // 本文取得（可能なら）
        String? bodyText;
        try {
          final textData = await api.getNovelText(id);
          bodyText = textData.novelText;
          await db.insert('novel_text', {
            'work_id': id,
            'title': novel.title,
            'author_name': novel.author.name,
            'pages_json': jsonEncode(textData.novelPages),
            'text': textData.novelText,
            'updated_at': DateTime.now().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        } catch (e) {
          debugPrint('[AiIndexRepair] 本文取得スキップ workId=$id: $e');
        }

        // 埋め込み生成（モデル有効時のみ）
        if (canEmbed) {
          final docText = buildNovelDocumentText(novel, bodyText: bodyText);
          if (docText.isNotEmpty) {
            final vector = await embeddingService.encodeDocument(docText);
            await db.insert('novel_embeddings', {
              'work_id': id,
              'embedding': jsonEncode(vector.toList()),
              'model_id': RuriModelManager.embeddingModelId,
              'model_version': RuriModelManager.embeddingModelVersion,
              'prefix_scheme_version': RuriModelManager.prefixSchemeVersion,
              'embedding_dim': RuriModelManager.embeddingDimension,
              'updated_at': DateTime.now().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            result.embeddingsRegenerated++;
          }
        } else {
          result.requireModel = true;
        }
        result.success++;
      } on RateLimitException {
        // 429: レート制限。一定時間待機してリトライし、それでも失敗なら中断。
        debugPrint('[AiIndexRepair] レート制限 workId=$id、5秒待機してリトライ');
        result.rateLimited++;
        try {
          await Future.delayed(const Duration(seconds: 5));
          final novelRetry = await api.getNovelById(id);
          await db.insert('novels', {
            'id': novelRetry.id,
            'title': novelRetry.title,
            'description': novelRetry.caption,
            'author_id': novelRetry.author.id,
            'author_name': novelRetry.author.name,
            'series_id': novelRetry.series?.id ?? 0,
            'series_order': novelRetry.seriesOrder ?? 0,
            'text_length': novelRetry.textLength,
            'tags': novelRetry.tags.join(','),
            'tags_json': jsonEncode(novelRetry.tags),
            'x_restrict': novelRetry.xRestrict,
            'novel_ai_type': novelRetry.aiType,
            'cover_url': novelRetry.coverUrl,
            'page_count': novelRetry.pageCount,
            'total_bookmarks': novelRetry.totalBookmarks,
            'total_view': novelRetry.totalView,
            'create_date': novelRetry.createDate,
            'meta_json': jsonEncode({
              ...novelRetry.toJson(),
              if (novelRetry.series != null)
                'series_title': novelRetry.series!.title,
            }),
            'updated_at': DateTime.now().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          result.metaUpdated++;
          result.success++;
          debugPrint('[AiIndexRepair] リトライ成功 workId=$id');
          continue;
        } catch (e2) {
          debugPrint('[AiIndexRepair] リトライ失敗 workId=$id: $e2');
          // リトライ後も失敗 → 中断扱い（後続はユーザーが再度実行）
          result.rateLimited++;
          break;
        }
      } on AuthException {
        // 401: 認証エラー。トークンリフレッシュを試み、それでも駄目なら中断。
        debugPrint('[AiIndexRepair] 認証エラー workId=$id: 再ログインが必要');
        result.authErrors++;
        break;
      } on NovelNotFoundException {
        // 404/削除済み/非公開: 安全にスキップして継続
        debugPrint('[AiIndexRepair] 作品なし(404等) workId=$id: スキップ');
        result.notFound++;
        continue;
      } catch (e) {
        // その他ネットワークエラー等: スキップして継続、最後にまとめて報告
        debugPrint('[AiIndexRepair] 補完スキップ(その他) workId=$id: $e');
        result.failed++;
        continue;
      }
      await onProgress(current, workIds.length);
      if (current < workIds.length && delayMs > 0) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
    return result;
  }

  /// すべて再インデックス（ローカル修復 + 有効なものは保持）。
  Future<AiIndexRepairResult> reindexAll({
    required Future<void> Function(int current, int total) onProgress,
    bool Function()? cancel,
  }) => repairLocal(onProgress: onProgress, cancel: cancel);

  /// API 補完対象を選別する（ローカル修復だけでは補えない作品）。
  /// 対象: novel_text なし かつ description/tags もほぼ空、または
  /// text_length/page_count が 0 で埋め込み文書を構築不可なもの。
  Future<List<int>> selectApiTargets() async {
    final db = await DatabaseService().database;
    final novelsRows = await db.query('novels');
    final textRows = await db.query('novel_text', columns: ['work_id']);
    final textIds = textRows.map((r) => r['work_id'] as int? ?? -1).toSet();

    final targets = <int>[];
    for (final novel in novelsRows) {
      final id = novel['id'] as int? ?? 0;
      if (id <= 0) continue;
      final hasText = textIds.contains(id);
      final desc = (novel['description'] as String? ?? '').toString();
      final tags = (novel['tags'] as String? ?? '').toString();
      final tl = novel['text_length'] as int? ?? 0;
      final pc = novel['page_count'] as int? ?? 0;
      final noLocalInfo = !hasText && desc.isEmpty && tags.isEmpty;
      final needMeta = tl <= 0 || pc <= 0;
      if (noLocalInfo || needMeta) {
        // ただし description/tags があればローカル修復で埋め込み生成可能
        if (hasText || desc.isNotEmpty || tags.isNotEmpty) {
          // ローカル修復で対応可能 → API 不要
          continue;
        }
        targets.add(id);
      }
    }
    return targets;
  }
}

/// 診断結果。
class AiIndexDiagnosisResult {
  final int totalNovels;
  final int textAvailable;
  final int embeddingAvailable;
  final int embeddingCompatible;
  final int embeddingMissing;
  final int embeddingBroken;
  final int embeddingDimMismatch;
  final int modelIdMismatch;
  final int modelVersionMismatch;
  final int prefixMismatch;
  final int textLengthZero;
  final int pageCountZero;
  final int metaMissing;

  // ---- イラスト側（novel と同一構成） ----
  final int totalIllusts;
  final int illustEmbedAvailable;
  final int illustEmbedCompatible;
  final int illustEmbedMissing;
  final int illustEmbedBroken;
  final int illustEmbedDimMismatch;
  final int illustModelIdMismatch;
  final int illustModelVersionMismatch;
  final int illustPrefixMismatch;

  const AiIndexDiagnosisResult({
    this.totalNovels = 0,
    this.textAvailable = 0,
    this.embeddingAvailable = 0,
    this.embeddingCompatible = 0,
    this.embeddingMissing = 0,
    this.embeddingBroken = 0,
    this.embeddingDimMismatch = 0,
    this.modelIdMismatch = 0,
    this.modelVersionMismatch = 0,
    this.prefixMismatch = 0,
    this.textLengthZero = 0,
    this.pageCountZero = 0,
    this.metaMissing = 0,
    this.totalIllusts = 0,
    this.illustEmbedAvailable = 0,
    this.illustEmbedCompatible = 0,
    this.illustEmbedMissing = 0,
    this.illustEmbedBroken = 0,
    this.illustEmbedDimMismatch = 0,
    this.illustModelIdMismatch = 0,
    this.illustModelVersionMismatch = 0,
    this.illustPrefixMismatch = 0,
  });

  const AiIndexDiagnosisResult.empty() : this();

  /// AI検索にすぐ使える件数（互換embeddingがある）。
  int get aiSearchable => embeddingCompatible + illustEmbedCompatible;

  /// 埋め込みが不足・破損・不一致の件数。
  int get embeddingDeficient =>
      embeddingMissing +
      embeddingBroken +
      embeddingDimMismatch +
      modelIdMismatch +
      modelVersionMismatch +
      prefixMismatch +
      illustEmbedMissing +
      illustEmbedBroken +
      illustEmbedDimMismatch +
      illustModelIdMismatch +
      illustModelVersionMismatch +
      illustPrefixMismatch;

  /// イラスト側の埋め込み不足・破損・不一致の件数。
  int get illustEmbeddingDeficient =>
      illustEmbedMissing +
      illustEmbedBroken +
      illustEmbedDimMismatch +
      illustModelIdMismatch +
      illustModelVersionMismatch +
      illustPrefixMismatch;

  /// メタデータ不足（文字数/ページ/作者名/カバー）。
  int get metadataDeficient => metaMissing;

  /// 本文あり・ローカルで再生成可能（text_length等は別途再計算）。
  int get localRepairable => textLengthZero;

  /// API取得が必要な件数（ローカルでは補えない）。
  int get apiRequired => embeddingDeficient; // 詳細選別は selectApiTargets() で行う
}

/// 修復結果。
class AiIndexRepairResult {
  int totalTargets = 0; // 今回処理の対象になった件数
  int metaUpdated = 0;
  int embeddingsRegenerated = 0;
  int success = 0;
  int skipped = 0; // ローカルで補えない/文書構築不可等
  int notFound = 0; // 404/削除済み/非公開
  int authErrors = 0; // 401 認証エラー
  int rateLimited = 0; // 429 レート制限で中断
  int failed = 0; // その他予期せぬ失敗
  bool requireModel = false;

  // ---- イラスト側カウンタ（novel と同一構成） ----
  int illustMetaUpdated = 0;
  int illustEmbeddingsRegenerated = 0;
  int illustSkipped = 0;
  int illustFailed = 0;

  @override
  String toString() =>
      'AiIndexRepairResult(totalTargets:$totalTargets, success:$success, '
      'metaUpdated:$metaUpdated, embeddingsRegenerated:$embeddingsRegenerated, '
      'skipped:$skipped, notFound:$notFound, authErrors:$authErrors, '
      'rateLimited:$rateLimited, failed:$failed, requireModel:$requireModel, '
      'illustMetaUpdated:$illustMetaUpdated, '
      'illustEmbeddingsRegenerated:$illustEmbeddingsRegenerated, '
      'illustSkipped:$illustSkipped, illustFailed:$illustFailed)';
}
