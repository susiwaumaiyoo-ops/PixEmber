// M5: モデル別推論プリセット + モデル切替用の選択肢モデル。
//
// カタログ（assets/llm_models.json）の fileName 一致で
// context / maxOutputTokens / GPU layers を解決する。
// 未一致モデル（カスタム GGUF など）は安全側の既定値を使う。

import 'package:path/path.dart' as p;

import '../models/llm_model_catalog_entry.dart';

/// モデル別の推論パラメータ（M5）。
///
/// カタログの recommendedContext / maxOutputTokens / preferredGpuLayers を
/// そのまま推論に反映するための値集合。
class LlmInferencePreset {
  const LlmInferencePreset({
    this.contextSize = 4096,
    this.maxOutputTokens = 512,
    this.gpuLayers = 0,
  });

  /// 既定プリセット（カタログ不一致・カスタムモデル用の安全値）。
  ///
  /// - contextSize: 4096（本文2000字 + プロンプト + 出力に十分）
  /// - maxOutputTokens: 512（3セクション出力に十分）
  /// - gpuLayers: 0（CPU のみ = 最も互換性が高い）
  static const LlmInferencePreset defaults = LlmInferencePreset();

  /// コンテキストサイズ。
  final int contextSize;

  /// 最大出力トークン。
  final int maxOutputTokens;

  /// GPU オフロード層数（0=CPU のみ、-1=自動）。
  final int gpuLayers;

  /// カタログエントリからプリセットを作る。
  factory LlmInferencePreset.fromEntry(LlmModelCatalogEntry entry) {
    return LlmInferencePreset(
      contextSize: entry.recommendedContext,
      maxOutputTokens: entry.maxOutputTokens,
      gpuLayers: entry.preferredGpuLayers,
    );
  }

  /// [fileNameOrPath]（絶対パス可）のファイル名でカタログを引き、
  /// 一致するプリセットを返す。見つからなければ [defaults]。
  ///
  /// ファイル名比較は大文字小文字を無視する。
  static LlmInferencePreset resolveForFileName(
    String fileNameOrPath,
    List<LlmModelCatalogEntry> entries,
  ) {
    final name = p.basename(fileNameOrPath.trim()).toLowerCase();
    if (name.isEmpty) return defaults;
    for (final e in entries) {
      if (e.fileName.toLowerCase() == name) {
        return LlmInferencePreset.fromEntry(e);
      }
    }
    return defaults;
  }
}

/// モデル切替 UI 用の選択肢（M5）。
class LlmModelChoice {
  const LlmModelChoice({
    required this.path,
    required this.label,
    this.preset = LlmInferencePreset.defaults,
  });

  /// GGUF の絶対パス。
  final String path;

  /// 表示ラベル（カタログ displayName、無ければファイル名）。
  final String label;

  /// このモデルの推論プリセット（カタログ解決済み・未一致は既定値）。
  final LlmInferencePreset preset;
}
