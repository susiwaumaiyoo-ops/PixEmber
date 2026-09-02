/// 小説本文のリッチレンダリング用パーサー（Phase 1 本体実装）。
///
/// UI に依存しない純粋 Dart モジュール（単体テスト対象）。
/// 設計: docs/plans/09-novel-rich-rendering.md §4（パーサー設計）、
/// §6.1（案B'' 行送り拡張 RichText）、§11.3（page 越過フォールバック）。
library;

/// ルビの表示モード（設計書 §6.2）。
enum RubyDisplayMode {
  /// ルビを親文字の上に小さく表示（本設計の標準描画）。
  show,

  /// 親文字の後ろに括弧でルビをインライン表示（例: 颯（はやて））。
  brackets,

  /// ルビを畳み、親文字のみ表示（TTS の readRuby=false と見た目が一致）。
  hide,
}

/// ページ本文を解析した結果の構造単位（sealed）。
sealed class NovelBlock {
  const NovelBlock();
}

/// 通常段落。rubyToken 化された [InlineRun] 列を持つ。
class ParagraphBlock extends NovelBlock {
  final List<InlineRun> runs;

  const ParagraphBlock(this.runs);

  /// ルビを 1 つでも含む段落（= ルビ段落）か（§6.1 案B'' の段落分類）。
  bool get hasRuby => runs.any((r) => r is RubyInline);

  /// 段落の表示用プレーンテキスト（検索 / TTS 整合テスト用）。
  String get plainText => runs
      .map(
        (r) => switch (r) {
          PlainText(:final text) => text,
          RubyInline(:final base) => base,
        },
      )
      .join();
}

/// `[uploadedimage:ID]`。
class UploadedImageBlock extends NovelBlock {
  /// タグ中の ID（textEmbeddedImages マップのキーと完全一致照合）。
  final String localId;

  /// 同一ページ内の出現順（複数挿絵対応・Widget key 用）。
  final int pageIndexInPage;

  const UploadedImageBlock({
    required this.localId,
    required this.pageIndexInPage,
  });
}

/// `[pixivimage:ID]` / `[pixivimage:ID-page]`。
class PixivImageBlock extends NovelBlock {
  final int illustId;

  /// 0 始まり。省略時は null（= 表紙扱い）。
  final int? page;

  const PixivImageBlock({required this.illustId, this.page});
}

/// `[newpage]`（ページ分割は getNovelText 済みだが、仕様上 parse 経路でも許容）。
class PageBreakBlock extends NovelBlock {
  const PageBreakBlock();
}

/// 段落内の 1 要素（sealed）。
sealed class InlineRun {
  const InlineRun();
}

/// 装飾の無い通常テキスト。
class PlainText extends InlineRun {
  final String text;

  const PlainText(this.text);
}

/// `[[rb:親文字 > ルビ]]`。
class RubyInline extends InlineRun {
  /// 親文字（表示はこちら）。
  final String base;

  /// ルビ（上に小さく表示 / TTS は readRuby で選択）。
  final String ruby;

  const RubyInline({required this.base, required this.ruby});
}

/// 小説本文の解析ユーティリティ（純粋関数のみ）。
abstract final class NovelParser {
  /// `[[rb:親文字 > ルビ]]` 形式のルビタグ。TTS 側の _rubyPattern と同一書式。
  static final RegExp _rubyTagRegExp = RegExp(r'\[\[rb:(.+?)\s*>\s*(.+?)\]\]');

  /// 行頭〜行末が完全一致する `[uploadedimage:ID]` のみ独立ブロック化する。
  /// 負数・非数値はマッチしないため PlainText として温存される。
  static final RegExp _uploadedTagRegExp = RegExp(r'^\[uploadedimage:(\d+)\]$');

  /// 行頭〜行末が完全一致する `[pixivimage:ID]` / `[pixivimage:ID-page]` のみ
  /// 独立ブロック化する。page は 0 始まり。`[pixivimage:1]abc` のような変形は
  /// 誤爆しない（完全一致制約。設計書 §4 規則 2・5）。
  static final RegExp _pixivTagRegExp = RegExp(
    r'^\[pixivimage:(\d+)(?:-(\d+))?\]$',
  );

  static final RegExp _newpageTagRegExp = RegExp(r'^\[newpage\]$');

  /// [collectPixivImages] 用の走査（行頭行末制約なし・事前解決用の広め抽出）。
  static final RegExp _collectPixivRegExp = RegExp(
    r'\[pixivimage:(\d+)(?:-(\d+))?\]',
  );

  /// 1 ページ分の本文をブロック列へ変換する（純粋関数）。
  ///
  /// 解析規則（設計書 §4）:
  /// 1. 段落分割は `\n` 区切り。連続空行は 1 つの空段落に圧縮する
  ///    （既存 `_formatParagraphs` の意図を継承）
  /// 2. 行頭〜行末が完全一致で挿絵タグ 1 個のみの場合に独立ブロック化する。
  ///    行中混在や変形のタグは PlainText として温存される
  /// 3. `[[rb:...]]` は行内どこでも可。ネスト括弧・複数出現に対応
  /// 4. 不明タグ（`[jump:N]` 等）は PlainText として温存する
  static List<NovelBlock> parsePage(String pageText) {
    final blocks = <NovelBlock>[];
    var lastWasBlank = false;
    var uploadedIndexInPage = 0;
    for (final rawLine in pageText.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        // 連続空行は 1 つの空段落に圧縮
        if (lastWasBlank) continue;
        lastWasBlank = true;
        blocks.add(const ParagraphBlock([]));
        continue;
      }
      lastWasBlank = false;

      final uploaded = _uploadedTagRegExp.firstMatch(line);
      if (uploaded != null) {
        blocks.add(
          UploadedImageBlock(
            localId: uploaded.group(1)!,
            pageIndexInPage: uploadedIndexInPage++,
          ),
        );
        continue;
      }

      final pixiv = _pixivTagRegExp.firstMatch(line);
      if (pixiv != null) {
        final id = int.tryParse(pixiv.group(1)!);
        final pageStr = pixiv.group(2);
        final page = pageStr != null ? int.tryParse(pageStr) : null;
        if (id != null && (pageStr == null || page != null)) {
          blocks.add(PixivImageBlock(illustId: id, page: page));
          continue;
        }
      }

      if (_newpageTagRegExp.hasMatch(line)) {
        blocks.add(const PageBreakBlock());
        continue;
      }

      blocks.add(ParagraphBlock(parseInline(line)));
    }
    return blocks;
  }

  /// 段落を [InlineRun] 列へ変換する（純粋関数）。
  ///
  /// `[[rb:...]]` は行内どこでも可。非貪欲マッチの逐次適用により
  /// 複数出現・入れ子括弧に対応する。空ルビは親文字のみへ畳む。
  static List<InlineRun> parseInline(String paragraphText) {
    final runs = <InlineRun>[];
    var cursor = 0;
    for (final match in _rubyTagRegExp.allMatches(paragraphText)) {
      if (match.start > cursor) {
        runs.add(PlainText(paragraphText.substring(cursor, match.start)));
      }
      final base = (match.group(1) ?? '').trim();
      final ruby = (match.group(2) ?? '').trim();
      if (ruby.isEmpty) {
        runs.add(PlainText(base));
      } else {
        runs.add(RubyInline(base: base, ruby: ruby));
      }
      cursor = match.end;
    }
    if (cursor < paragraphText.length) {
      runs.add(PlainText(paragraphText.substring(cursor)));
    }
    return runs;
  }

  /// 本文全体から挿絵参照を抽出する（オフライン事前解決用）。
  ///
  /// 同一 illustId+page の重複は除去する。page 差分は別要素として保持する。
  static List<PixivImageBlock> collectPixivImages(String fullText) {
    final blocks = <PixivImageBlock>[];
    final seen = <String>{};
    for (final match in _collectPixivRegExp.allMatches(fullText)) {
      final id = int.tryParse(match.group(1) ?? '');
      if (id == null) continue;
      final pageStr = match.group(2);
      final page = pageStr != null ? int.tryParse(pageStr) : null;
      final key = '$id:${page ?? ''}';
      if (!seen.add(key)) continue;
      blocks.add(PixivImageBlock(illustId: id, page: page));
    }
    return blocks;
  }

  /// 表示モードに応じて [InlineRun] 列を畳む（設計書 §6.2）。
  ///
  /// - show: そのまま返す
  /// - brackets: RubyInline → `親文字（ルビ）` の PlainText
  /// - hide: RubyInline → 親文字のみの PlainText
  static List<InlineRun> collapseRunsForDisplay(
    List<InlineRun> runs,
    RubyDisplayMode mode,
  ) {
    if (mode == RubyDisplayMode.show) return runs;
    return runs.map((r) {
      if (r is! RubyInline) return r;
      return switch (mode) {
        RubyDisplayMode.brackets => PlainText('${r.base}（${r.ruby}）'),
        RubyDisplayMode.hide => PlainText(r.base),
        RubyDisplayMode.show => r,
      };
    }).toList();
  }

  /// ルビ段落の行送り倍率（設計書 §6.1 案B''）。
  ///
  /// 式: `lineHeight + rubyFontSize / fontSize + 呼吸分 0.05`。
  /// rubyFontSize = fontSize × 0.5 のため標準設定（fontSize=18 / lineHeight=1.8）
  /// では 2.35 になる。ルビを含まない段落は従来どおり height: lineHeight を使う。
  static double rubyLineHeightRatio(double fontSize, double lineHeight) {
    if (fontSize <= 0) return lineHeight + 0.55;
    return lineHeight + (fontSize * 0.5) / fontSize + 0.05;
  }

  /// `[pixivimage]` タグの page（0 始まり、null=表紙）から original URL を解決する
  /// 純粋関数（設計書 §2.2 / §5.3 / §11.3）。
  ///
  /// - [coverOriginal]: `Illust.urls.original`（表紙・1 ページ作品）
  /// - [metaPageOriginals]: `metaPages[i].original` の列。index 0 = 1 ページ目
  /// - [requestedPage]: タグの 0 始まり page（null = 表紙）
  ///
  /// page 越過時のみ、タグが 1 始まりで書かれた可能性を考慮した
  /// 1 始まり再解釈フォールバックを 1 回試行する。
  static String? resolvePixivImageUrl({
    required String? coverOriginal,
    required List<String?> metaPageOriginals,
    int? requestedPage,
  }) {
    if (requestedPage == null) {
      return coverOriginal ??
          (metaPageOriginals.isNotEmpty ? metaPageOriginals.first : null);
    }
    final oneBased = requestedPage + 1;
    if (oneBased >= 1 && oneBased <= metaPageOriginals.length) {
      return metaPageOriginals[requestedPage];
    }
    // page 越過: 1 始まりで書かれたタグの可能性 → 1 回のみ再解釈
    if (requestedPage >= 1 && requestedPage <= metaPageOriginals.length) {
      return metaPageOriginals[requestedPage - 1];
    }
    return coverOriginal ??
        (metaPageOriginals.isNotEmpty ? metaPageOriginals.first : null);
  }
}
