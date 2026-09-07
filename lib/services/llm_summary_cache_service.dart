// LLM要約キャッシュサービス（M6）。
//
// 設計:
// - 生成済みの要約を llm_summaries テーブル（DB v25）にキャッシュする。
//   同一作品 × 同一モデル × 同一プロンプト版 × 同一入力フィンガープリント
//   で1行（UNIQUE制約、INSERT OR REPLACE で上書き）。
// - source_fingerprint: プロンプト入力（正規化本文の均衡抜粋 + タイトル + タグ）
//   の SHA-256。本文が変われば自動的にキャッシュミスになる。
// - model_file_hash: モデル GGUF の高速フィンガープリント（ファイル名 + サイズ
//   + 更新日時の SHA-256）。数GBのモデル全体をハッシュしない（実用性優先）。
// - キャッシュは本文・モデルから再生成可能なため Google Drive バックアップ
//   対象外（exportAllData に含めない）。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'database_service.dart';
import 'llm_summary_service.dart';

/// LLM要約キャッシュサービス。
class LlmSummaryCacheService {
  LlmSummaryCacheService({DatabaseService? dbService})
    : _db = dbService ?? DatabaseService();

  final DatabaseService _db;

  /// プロンプト版（M1の言い換え強化プロンプトを含む現行版）。
  static const int promptVersion = 2;

  /// キャッシュを照会する。ヒット時は [LlmSummaryResult] を返す。
  /// ヒットしない・読込失敗時は null（生成を継続）。
  Future<LlmSummaryResult?> get({
    required int workId,
    required String modelId,
    required String sourceFingerprint,
  }) async {
    try {
      final db = await _db.database;
      final rows = await db.query(
        'llm_summaries',
        where:
            'work_id = ? AND model_id = ? AND prompt_version = ? '
            'AND source_fingerprint = ?',
        whereArgs: [workId, modelId, promptVersion, sourceFingerprint],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final tagsJson = row['suggested_tags_json'] as String? ?? '[]';
      final tags = (jsonDecode(tagsJson) as List<dynamic>)
          .map((e) => e.toString())
          .toList();
      return LlmSummaryResult(
        synopsis: row['synopsis'] as String? ?? '',
        intro: row['spoiler_free_intro'] as String? ?? '',
        tagSuggestions: tags,
        copyWarning: (row['copy_warning'] as int? ?? 0) != 0,
        bodySourceNote: null,
        modelLabel: modelId,
        generationMs: row['generation_ms'] as int?,
        tokensPerSecond: null,
        generatedAt: DateTime.tryParse(row['generated_at'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }

  /// 生成結果をキャッシュに保存する。失敗しても呼び出し側を妨げない。
  Future<void> save({
    required int workId,
    required String modelId,
    required String modelFileHash,
    required String sourceFingerprint,
    required LlmSummaryResult result,
  }) async {
    try {
      final db = await _db.database;
      await db.insert('llm_summaries', {
        'work_id': workId,
        'model_id': modelId,
        'model_file_hash': modelFileHash,
        'prompt_version': promptVersion,
        'source_fingerprint': sourceFingerprint,
        'synopsis': result.synopsis,
        'spoiler_free_intro': result.intro,
        'suggested_tags_json': jsonEncode(result.tagSuggestions),
        'copy_warning': result.copyWarning ? 1 : 0,
        'generation_ms': result.generationMs,
        'generated_at': (result.generatedAt ?? DateTime.now())
            .toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {
      // キャッシュ保存失敗は要約表示を妨げない。
    }
  }

  /// モデルファイルの高速フィンガープリント。
  ///
  /// ファイル名 + サイズ + 更新日時ミリ秒の SHA-256。
  /// 数GBの GGUF 全体を読まずに実質的な同一性を判定する。
  /// ファイルが存在しない・読み取れない場合はパス自体の SHA-256 を返す。
  static Future<String> computeModelFileHash(String path) async {
    try {
      final f = File(path);
      final stat = await f.stat();
      final basis =
          '${p.basename(path)}:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      return sha256.convert(utf8.encode(basis)).toString();
    } catch (_) {
      return sha256.convert(utf8.encode(path)).toString();
    }
  }
}
