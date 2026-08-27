import '../illust_model.dart'; // Illust 型 + cleanCaption（illust_model で定義済み）

/// Embedding 用のイラスト文書テキストを組み立てる共通関数。
///
/// [novel_document_text.buildNovelDocumentText] と同一フォーマット
/// （タイトル / タグ / 説明）とし、重要情報を前方に置く方針を踏襲する。
/// イラストは「本文」を持たないため body 相当は省略する。
///
/// 形式:
/// ```
/// タイトル: {title}
/// タグ: {tags}
/// 説明: {caption}
/// ```
String buildIllustDocumentText(Illust illust) {
  return buildIllustDocumentTextRaw(
    title: illust.title,
    tags: illust.tags,
    caption: illust.caption,
  );
}

/// Illust インスタンスを持たない場所（DB の行など）から組み立てる版。
String buildIllustDocumentTextRaw({
  required String title,
  List<String> tags = const [],
  String caption = '',
}) {
  final buffer = StringBuffer();
  buffer.write('タイトル: ${_normalize(title)}');

  final tagText = tags.map(_normalize).where((t) => t.isNotEmpty).join(' ');
  buffer.write('\nタグ: $tagText');

  // caption は Illust.fromJson 側で cleanCaption 済だが、生値が来た場合も
  // 安全のため再適用する（novel 側と同じ cleanCaption を再利用）。
  final captionText = _normalize(cleanCaption(caption));
  buffer.write('\n説明: $captionText');

  return buffer.toString();
}

String _normalize(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
