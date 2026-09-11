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

  /// プロンプト版（思考分離プロンプトを含む現行版）。
  /// v4: 出力書式プロンプトから英語・括弧形注記を削除(問題A)。
  /// v5: 長文対応（n_ctx 8192 + 全文/チャンク分割 map-reduce）。旧キャッシュを無効化。
  /// v6: プロンプト修正（件数/説明文を見出しから分離、メタテキスト混入対策）。旧キャッシュ無効化。
  static const int promptVersion = 6;

  /// キャッシュを照会する。ヒット時は [LlmSummaryResult] を返す。
  /// ヒットしない・読込失敗時は null（生成を継続）。
  ///
  /// F2（キャッシュキー整合性）: [modelFileHash] を渡すと照会条件に加え、
  /// 保存時（[save]）と同一のモデルファイル・フィンガープリントを持つ行のみ
  /// ヒットさせる。手動・自動で同じ有効性判定を使うため、呼び出し側は
  /// 必ず [computeModelFileHash] の結果を渡すこと。
  /// 後方互換（テスト等）のため未指定時は従来どおり hash 条件なしで照会する。
  Future<LlmSummaryResult?> get({
    required int workId,
    required String modelId,
    required String sourceFingerprint,
    String? modelFileHash,
  }) async {
    try {
      final db = await _db.database;
      final where = [
        'work_id = ?',
        'model_id = ?',
        'prompt_version = ?',
        'source_fingerprint = ?',
      ];
      final args = <Object?>[workId, modelId, promptVersion, sourceFingerprint];
      // 同一モデルファイル（内容指纹）でないと誤ヒットするため hash を条件化。
      // model_file_hash は v25 導入時から NOT NULL で全行算出済みだが、
      // 旧行を壊さないため「指定時のみ」絞る（NULL 行は存在せず再計算不要）。
      if (modelFileHash != null) {
        where.add('model_file_hash = ?');
        args.add(modelFileHash);
      }
      final rows = await db.query(
        'llm_summaries',
        where: where.join(' AND '),
        whereArgs: args,
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
  ///
  /// 注: 本来は「DL/インポート時の内容 SHA-256」が最も厳密だが、それは
  /// 導入経路（download/import）と arbiter のモデル所有者へ保存を要する
  /// 広範な変更になるため本バッチでは見送り（未実施）。現行の
  /// basename:size:mtime は「取得不能時のフォールバック」として十分機能し、
  /// 取り直し時は mtime が変わるため実用上の誤ヒットは起きにくい。
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
