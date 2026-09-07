// LLM モデルカタログサービス（M2）。
//
// assets/llm_models.json を読み込み、厳選モデル一覧を公開する。
// revision / 正確なサイズ / SHA-256 のいずれかが欠落したエントリは
// 自動ダウンロード対象 (downloadable) から除外される（仕様: 未検証
// モデルの自動 DL 禁止）。

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/llm_model_catalog_entry.dart';

/// 読み込んだカタログ。
class LlmModelCatalog {
  const LlmModelCatalog({required this.catalogVersion, required this.entries});

  final int catalogVersion;
  final List<LlmModelCatalogEntry> entries;

  /// 自動ダウンロード可能モデル（revision/サイズ/ハッシュ pin 済み）。
  List<LlmModelCatalogEntry> get downloadable =>
      entries.where((e) => e.isVerified).toList(growable: false);

  /// 推奨モデル（isRecommended && isVerified の最初）。
  LlmModelCatalogEntry? get recommended {
    for (final e in entries) {
      if (e.isRecommended && e.isVerified) return e;
    }
    return null;
  }
}

class LlmModelCatalogService {
  LlmModelCatalogService({Future<String> Function()? jsonReader})
    : _jsonReader = jsonReader ?? _readBundled;

  final Future<String> Function() _jsonReader;

  static const String kAssetPath = 'assets/llm_models.json';

  static Future<String> _readBundled() => rootBundle.loadString(kAssetPath);

  /// バンドルカタログ (assets/llm_models.json) を読み込む。
  Future<LlmModelCatalog> load() async {
    final raw = await _jsonReader();
    return parse(raw);
  }

  /// 純粋パーサー（テスト向け）。不正な JSON は FormatException。
  static LlmModelCatalog parse(String raw) {
    final top = jsonDecode(raw);
    if (top is! Map<String, dynamic>) {
      throw const FormatException(
        'llm_models.json: top-level must be an object',
      );
    }
    final models = top['models'];
    final list = models is List
        ? models
              .whereType<Map<String, dynamic>>()
              .map(LlmModelCatalogEntry.fromJson)
              .toList()
        : const <LlmModelCatalogEntry>[];
    return LlmModelCatalog(
      catalogVersion: (top['catalog_version'] as num?)?.toInt() ?? 1,
      entries: list,
    );
  }

  /// バイト数表示（1000 進 MB/GB。カタログ仕様の表記に合わせる）。
  static String formatBytes(int bytes) {
    const kb = 1000.0;
    const mb = kb * 1000;
    const gb = mb * 1000;
    if (bytes < 1000) return '$bytes B';
    if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / gb).toStringAsFixed(2)} GB';
  }
}
