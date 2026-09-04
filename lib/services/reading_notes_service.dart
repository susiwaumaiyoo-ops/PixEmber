// 読書メモ・引用メモサービス（非AI機能パック Phase N6）。
//
// DB 側の CRUD は DatabaseService（reading_notes / v24）に集約し、
// このファイルは UI 非依存の純粋ヘルパーを置く。

/// 指定ページの本文から引用アンカーを抽出する。
///
/// 先頭から最初の非空行（前後空白除去済み）を取り、[maxLength] 超なら
/// 切り詰め末尾に「…」を付与する。テキストが無い場合は null。
String? extractAnchorText(String? pageText, {int maxLength = 60}) {
  if (pageText == null) return null;
  final lines = pageText
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return null;
  final first = lines.first;
  if (first.length <= maxLength) return first;
  return '${first.substring(0, maxLength)}…';
}
