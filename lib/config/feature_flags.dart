/// 段階リリース用の feature flag 定義。
///
/// 各フラグは `--dart-define=FLAG_NAME=true` で実行時に有効化できる。
/// 既定値は false（既存挙動を維持）とし、flag off 時は DB マイグレーションのみ
/// 適用して動作への副作用を発生させない。
class FeatureFlags {
  /// イラストの意味検索（illust_embeddings の生成・検索モード追加）。
  static const bool illustSemanticSearch = bool.fromEnvironment(
    'ILLUST_SEMANTIC_SEARCH',
    defaultValue: false,
  );

  /// 関連イラスト（/v2/illust/related）の RerankService による再ランク。
  static const bool illustRelatedRerank = bool.fromEnvironment(
    'ILLUST_RELATED_RERANK',
    defaultValue: false,
  );
}
