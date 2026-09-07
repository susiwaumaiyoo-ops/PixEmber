// LLM モデルカタログエントリ（M2）。
//
// 厳選ローカル LLM モデル（GGUF）の「不変」メタデータ:
// HuggingFace リポジトリの pin revision + 正確なファイルサイズ + SHA-256。
// 3 点すべてが pin されているエントリ (isVerified) のみ、
// アプリ内自動ダウンロードの対象とできる（仕様: 未検証モデルは禁止）。

class LlmModelCatalogEntry {
  const LlmModelCatalogEntry({
    required this.id,
    required this.displayName,
    required this.family,
    required this.parameterCount,
    required this.quantization,
    required this.repositoryId,
    required this.revision,
    required this.fileName,
    required this.expectedSizeBytes,
    required this.sha256,
    required this.licenseId,
    required this.attribution,
    required this.description,
    required this.recommendedContext,
    required this.maxOutputTokens,
    required this.estimatedRamBytes,
    required this.preferredBackend,
    required this.preferredGpuLayers,
    required this.capabilities,
    required this.reducedSafetyAlignment,
    required this.platforms,
    required this.isExperimental,
    this.isRecommended = false,
    this.highRamWarning = false,
  });

  /// 安定 ID（要約キャッシュ・好みのキーに使用）。
  final String id;

  final String displayName;
  final String family;
  final String parameterCount;
  final String quantization;

  /// HuggingFace リポジトリ（owner/name）。
  final String repositoryId;

  /// pin された revision commit（40桁16進）。
  final String revision;

  /// リポジトリ内の GGUF ファイル名。
  final String fileName;

  /// 正確なダウンロードサイズ（バイト）。
  final int expectedSizeBytes;

  /// ファイルの SHA-256（64桁16進、LFS oid）。
  final String sha256;

  final String licenseId;
  final String attribution;
  final String description;

  /// 推論プリセット: 推奨コンテキストサイズ。
  final int recommendedContext;

  /// 推論プリセット: 最大出力トークン。
  final int maxOutputTokens;

  /// 概算 RAM 要件（モデル + KVキャッシュ込みの目安）。
  final int estimatedRamBytes;

  /// 優先バックエンド（llama_cpp）。
  final String preferredBackend;

  /// 優先 GPU レイヤ（0=CPU, -1=自動）。
  final int preferredGpuLayers;

  /// 機能（'text_generation' など。mmproj なし = 'multimodal' を含まない）。
  final List<String> capabilities;

  /// abliterated（安全アライメント軽減）モデルか。
  final bool reducedSafetyAlignment;

  /// 対応プラットフォーム（'android' など）。
  final List<String> platforms;

  final bool isExperimental;

  /// 推奨モデルか（2B が true）。
  final bool isRecommended;

  /// 高 RAM 警告か（4B が true）。
  final bool highRamWarning;

  factory LlmModelCatalogEntry.fromJson(Map<String, dynamic> json) {
    return LlmModelCatalogEntry(
      id: (json['id'] as String?) ?? '',
      displayName: (json['displayName'] as String?) ?? '',
      family: (json['family'] as String?) ?? '',
      parameterCount: (json['parameterCount'] as String?) ?? '',
      quantization: (json['quantization'] as String?) ?? '',
      repositoryId: (json['repositoryId'] as String?) ?? '',
      revision: (json['revision'] as String?) ?? '',
      fileName: (json['fileName'] as String?) ?? '',
      expectedSizeBytes: (json['expectedSizeBytes'] as num?)?.toInt() ?? 0,
      sha256: (json['sha256'] as String?) ?? '',
      licenseId: (json['licenseId'] as String?) ?? '',
      attribution: (json['attribution'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      recommendedContext: (json['recommendedContext'] as num?)?.toInt() ?? 4096,
      maxOutputTokens: (json['maxOutputTokens'] as num?)?.toInt() ?? 512,
      estimatedRamBytes: (json['estimatedRamBytes'] as num?)?.toInt() ?? 0,
      preferredBackend: (json['preferredBackend'] as String?) ?? 'llama_cpp',
      preferredGpuLayers: (json['preferredGpuLayers'] as num?)?.toInt() ?? 0,
      capabilities: (json['capabilities'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      reducedSafetyAlignment:
          (json['reducedSafetyAlignment'] as bool?) ?? false,
      platforms: (json['platforms'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      isExperimental: (json['isExperimental'] as bool?) ?? true,
      isRecommended: (json['isRecommended'] as bool?) ?? false,
      highRamWarning: (json['highRamWarning'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'family': family,
    'parameterCount': parameterCount,
    'quantization': quantization,
    'repositoryId': repositoryId,
    'revision': revision,
    'fileName': fileName,
    'expectedSizeBytes': expectedSizeBytes,
    'sha256': sha256,
    'licenseId': licenseId,
    'attribution': attribution,
    'description': description,
    'recommendedContext': recommendedContext,
    'maxOutputTokens': maxOutputTokens,
    'estimatedRamBytes': estimatedRamBytes,
    'preferredBackend': preferredBackend,
    'preferredGpuLayers': preferredGpuLayers,
    'capabilities': capabilities,
    'reducedSafetyAlignment': reducedSafetyAlignment,
    'platforms': platforms,
    'isExperimental': isExperimental,
    'isRecommended': isRecommended,
    'highRamWarning': highRamWarning,
  };

  /// revision(40桁16進) + SHA-256(64桁16進) + サイズ + GGUF ファイル名が
  /// すべて検証可能か。true のみ自動ダウンロード対象。
  bool get isVerified =>
      RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(revision) &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256) &&
      expectedSizeBytes > 0 &&
      fileName.endsWith('.gguf') &&
      repositoryId.contains('/');

  /// HuggingFace 不変ダウンロード URL（revision で pin）。
  String get downloadUrl =>
      'https://huggingface.co/$repositoryId/resolve/$revision/$fileName';

  bool get supportsMultimodal => capabilities.contains('multimodal');

  bool supportsPlatform(String platform) => platforms.contains(platform);
}
