import '../novel_model.dart';
import '../illust_model.dart' show cleanCaption;

/// Embedding 用の小説文書テキストを組み立てる共通関数。
///
/// 呼び出し側ごとに整形をばらつかせないため、必ずこの関数を使うこと。
/// Ruri は 128 トークンで truncate される前提のため、重要情報を前方に置く。
///
/// 形式:
/// ```
/// タイトル: {title}
/// タグ: {tags}
/// 説明: {caption}
/// 本文: {bodyText 冒頭}
/// ```
String buildNovelDocumentText(Novel novel, {String? bodyText}) {
  return buildNovelDocumentTextRaw(
    title: novel.title,
    tags: novel.tags,
    caption: novel.caption,
    bodyText: bodyText,
  );
}

/// Novel インスタンスを持たない場所（DB の行など）から組み立てる版。
String buildNovelDocumentTextRaw({
  required String title,
  List<String> tags = const [],
  String caption = '',
  String? bodyText,
}) {
  const int maxBodyChars = 400;

  final buffer = StringBuffer();
  buffer.write('タイトル: ${_normalize(title)}');

  final tagText = tags.map(_normalize).where((t) => t.isNotEmpty).join(' ');
  buffer.write('\nタグ: $tagText');

  final captionText = _normalize(cleanCaption(caption));
  buffer.write('\n説明: $captionText');

  final body = bodyText == null ? '' : _normalize(bodyText);
  if (body.isNotEmpty) {
    final head = body.length > maxBodyChars
        ? body.substring(0, maxBodyChars)
        : body;
    buffer.write('\n本文: $head');
  }

  return buffer.toString();
}

String _normalize(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
