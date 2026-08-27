/// フィーリング発掘（AI 意味検索）v2 の構造化クエリモデル。
///
/// 「意味で探したいもの（semanticText）」と
/// 「絶対条件 / 除外条件 / 数値条件（hard filter）」を分離する。
/// semanticText が空でも must/should/exclude だけで検索できる。
enum R18Mode { all, includeR18, safeOnly, r18Only }

enum AiMode { all, excludeAi, aiOnly }

enum SortMode { relevance, newest, bookmarks }

/// 検索対象の作品種別。
/// デフォルトは novel（既存の意味検索挙動を維持）。
enum WorkType { novel, illust }

/// 複数条件検索の入力モデル。
class FeelingSearchQuery {
  const FeelingSearchQuery({
    this.semanticText = '',
    this.mustKeywords = const [],
    this.shouldKeywords = const [],
    this.excludeKeywords = const [],
    this.exactTags = const [],
    this.partialTags = const [],
    this.minBookmarks,
    this.minTextLength,
    this.maxTextLength,
    this.r18Mode = R18Mode.all,
    this.aiMode = AiMode.all,
    this.sortMode = SortMode.relevance,
    this.workType = WorkType.novel,
    this.topK = 30,
    this.highPrecision = false,
  });

  final String semanticText;
  final List<String> mustKeywords;
  final List<String> shouldKeywords;
  final List<String> excludeKeywords;
  final List<String> exactTags;
  final List<String> partialTags;
  final int? minBookmarks;
  final int? minTextLength;
  final int? maxTextLength;
  final R18Mode r18Mode;
  final AiMode aiMode;
  final SortMode sortMode;
  final WorkType workType;
  final int topK;

  /// 高精度モード（embedding + rerank）。
  /// reranker 未導入時は無視され従来スコアで返る。
  final bool highPrecision;

  FeelingSearchQuery copyWith({
    String? semanticText,
    List<String>? mustKeywords,
    List<String>? shouldKeywords,
    List<String>? excludeKeywords,
    List<String>? exactTags,
    List<String>? partialTags,
    int? minBookmarks,
    int? minTextLength,
    int? maxTextLength,
    R18Mode? r18Mode,
    AiMode? aiMode,
    SortMode? sortMode,
    WorkType? workType,
    int? topK,
    bool? highPrecision,
  }) {
    return FeelingSearchQuery(
      semanticText: semanticText ?? this.semanticText,
      mustKeywords: mustKeywords ?? this.mustKeywords,
      shouldKeywords: shouldKeywords ?? this.shouldKeywords,
      excludeKeywords: excludeKeywords ?? this.excludeKeywords,
      exactTags: exactTags ?? this.exactTags,
      partialTags: partialTags ?? this.partialTags,
      minBookmarks: minBookmarks ?? this.minBookmarks,
      minTextLength: minTextLength ?? this.minTextLength,
      maxTextLength: maxTextLength ?? this.maxTextLength,
      r18Mode: r18Mode ?? this.r18Mode,
      aiMode: aiMode ?? this.aiMode,
      sortMode: sortMode ?? this.sortMode,
      workType: workType ?? this.workType,
      topK: topK ?? this.topK,
      highPrecision: highPrecision ?? this.highPrecision,
    );
  }

  bool get hasSemantic => semanticText.trim().isNotEmpty;

  bool get hasHardFilter =>
      mustKeywords.isNotEmpty ||
      shouldKeywords.isNotEmpty ||
      excludeKeywords.isNotEmpty ||
      exactTags.isNotEmpty ||
      partialTags.isNotEmpty ||
      minBookmarks != null ||
      minTextLength != null ||
      maxTextLength != null ||
      r18Mode != R18Mode.all ||
      aiMode != AiMode.all;

  bool get isEmpty => !hasSemantic && !hasHardFilter;

  /// 意味検索の意図がある（semanticText が非空）。
  bool get hasSemanticIntent => semanticText.trim().isNotEmpty;

  /// 強い絞り込み意図がある（exact/must/partial タグ・キーワードのいずれか）。
  bool get hasStrongFilterIntent =>
      exactTags.isNotEmpty || mustKeywords.isNotEmpty || partialTags.isNotEmpty;

  /// 意味検索なしの純キーワード/タグ検索。
  bool get isLexicalOnly => !hasSemanticIntent;
}

/// ハイブリッド検索の複合スコア重み（定数化で調整容易）。
/// ハイブリッド検索の複合スコア重み（クエリタイプで動的切替）。
class HybridWeights {
  const HybridWeights({
    required this.semantic,
    required this.keyword,
    required this.tagMatch,
    required this.metadata,
  });

  final double semantic;
  final double keyword;
  final double tagMatch;
  final double metadata;
}

class FeelingScoreWeights {
  const FeelingScoreWeights._();

  /// should キーワード1件ヒットごとの加点（0.0〜）
  static const double shouldKeywordBonus = 0.03;

  /// 除外キーワード/除外タグに触れた場合の大幅減点（最終スコア倍率）
  static const double excludePenalty = 0.0;

  /// first-stage で出す候補数（通常検索）。
  static const int candidatePool = 50;

  /// 高精度モード時の候補数（rerank の恩恵を受ける枠を拡大）。
  static const int candidatePoolHighPrecision = 120;

  /// 高精度モードで rerank を適用する上位件数（コスト抑制）。
  static const int rerankCandidateLimit = 40;

  /// 重み判定は廃止。表示スコアは embedding の生 semanticScore をそのまま使う。
  /// 互換のため残しているが、実質 semantic=1.0 / 他=0.0 固定。
  static HybridWeights forQuery(FeelingSearchQuery q) {
    return const HybridWeights(
      semantic: 1.0,
      keyword: 0.0,
      tagMatch: 0.0,
      metadata: 0.0,
    );
  }
}
