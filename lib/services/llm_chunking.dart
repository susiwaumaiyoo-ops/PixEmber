// B: 長編本文のチャンク分割(map-reduce)用の純粋ロジック。
//
// トークン数は「おおよそ 1.4 字/トークン」で文字数へ換算する
// (llama.cpp トークナイザが使える場合は呼び出し側が実測して補正する)。
// 分割は段落境界(空行・改行)を優先し、文の途中では切らない。

typedef IntUnaryOp = int Function(int value);

/// 分割後の 1 チャンク。
class LlmTextChunk {
  const LlmTextChunk({
    required this.index,
    required this.text,
    required this.startChar,
    required this.endChar,
  });

  /// 0 始まりの連番。
  final int index;

  /// チャンク本文(前チャンクからの overlap を含む)。
  final String text;

  /// 元テキスト内の開始位置。
  final int startChar;

  /// 元テキスト内の終了位置。
  final int endChar;

  int get length => text.length;
}

/// 段落境界を優先したチャンク分割(B-2)。
class LlmChunker {
  LlmChunker._();

  /// 日本語の目安: 1 トークン ≈ 1.4 文字。
  static const double charsPerToken = 1.4;

  /// [maxChars] を超えないよう段落単位で分割し、前チャンク末尾を
  /// [overlapChars] 文字ぶん次チャンク先頭へ重複させる。
  static List<LlmTextChunk> split(
    String text, {
    required int maxChars,
    required int overlapChars,
  }) {
    final normalized = text.trim();
    if (normalized.isEmpty) return const <LlmTextChunk>[];
    final limit = maxChars < 200 ? 200 : maxChars;
    final overlap = overlapChars < 0
        ? 0
        : (overlapChars >= limit ~/ 2 ? limit ~/ 2 : overlapChars);

    final units = _units(normalized, limit);
    final chunks = <LlmTextChunk>[];
    final buffer = StringBuffer();
    var bufferStart = 0;
    var cursor = 0;
    var lastEnd = 0;

    void flush() {
      final chunkText = buffer.toString().trim();
      if (chunkText.isEmpty) {
        buffer.clear();
        return;
      }
      chunks.add(
        LlmTextChunk(
          index: chunks.length,
          text: chunkText,
          startChar: bufferStart,
          endChar: lastEnd,
        ),
      );
      buffer.clear();
    }

    for (final unit in units) {
      final unitStart = cursor;
      cursor += unit.length;
      if (buffer.isNotEmpty && buffer.length + unit.length > limit) {
        lastEnd = unitStart;
        flush();
        if (overlap > 0 && chunks.isNotEmpty) {
          final prev = chunks.last.text;
          final tail = prev.substring(
            prev.length > overlap ? prev.length - overlap : 0,
          );
          buffer.write(tail);
          bufferStart = unitStart - tail.length;
        } else {
          bufferStart = unitStart;
        }
      }
      buffer.write(unit);
      lastEnd = cursor;
    }
    flush();
    return List<LlmTextChunk>.unmodifiable(chunks);
  }

  /// 段落(空行/改行)優先で意味単位に分解する。1 行が [limit] を超える
  /// 場合は文末(。！？!?)でさらに分割し、それでも超える場合は
  /// [limit] 文字で機械的に分割する(最終手段)。
  static List<String> _units(String text, int limit) {
    final out = <String>[];
    for (final para in text.split(RegExp(r'\n'))) {
      if (para.isEmpty) {
        out.add('\n');
        continue;
      }
      if (para.length <= limit) {
        out.add(para);
        out.add('\n');
        continue;
      }
      out.addAll(_splitSentences(para, limit));
      out.add('\n');
    }
    return out;
  }

  static List<String> _splitSentences(String para, int limit) {
    final out = <String>[];
    final buffer = StringBuffer();
    for (final rune in para.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(ch);
      final isEnd =
          ch == '。' || ch == '！' || ch == '？' || ch == '!' || ch == '?';
      if (isEnd && buffer.length >= limit ~/ 2) {
        out.add(buffer.toString());
        buffer.clear();
      } else if (buffer.length >= limit) {
        out.add(buffer.toString());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) out.add(buffer.toString());
    return out;
  }

  /// 文字数からトークン数の目安を返す(トークナイザ実測不可時の概算)。
  static int approxTokens(int chars) => (chars / charsPerToken).ceil();

  /// トークン数から文字数の目安を返す。
  static int approxChars(int tokens) => (tokens * charsPerToken).floor();
}
