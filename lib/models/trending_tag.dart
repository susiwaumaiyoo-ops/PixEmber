/// Pixiv トレンドタグ最小モデル。
///
/// /v1/trending-tags/illust / /v1/trending-tags/novel で
/// 返却されるタグ名をそのまま保持する。
class TrendingTag {
  final String tag;
  final bool? isTranslated;

  const TrendingTag({required this.tag, this.isTranslated});

  factory TrendingTag.fromJson(Map<String, dynamic> json) {
    return TrendingTag(
      tag: (json['tag'] ?? json['name'] ?? '').toString(),
      isTranslated: json['is_translated'] as bool?,
    );
  }

  Map<String, dynamic> toJson() => {
    'tag': tag,
    if (isTranslated != null) 'is_translated': isTranslated,
  };
}
