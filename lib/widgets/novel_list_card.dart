import 'package:flutter/material.dart';
import '../novel_model.dart';
import 'pixiv_image.dart';

/// ホーム／フィーリング発掘で共通利用する小説カード。
///
/// 設計方針（シンプル・正しい設計）:
/// - API / DB アクセスを一切行わない（同期描画のみ）。
/// - 類似度は [similarity] が null でない場合のみバッジ表示する。
/// - 「意味近め%」表記は出さない（数値%のみ）。
///
/// ANR 防止規約（絶対）:
/// - Column の children に Spacer / Expanded / Flexible を入れない。
///   （無限レイアウト → ANR を防ぐため）
/// - 高さ判定は LayoutBuilder の constraints.maxHeight.isFinite で行う。
/// - 常に mainAxisSize: min（コンテンツ自然高）。ストレッチ/デッドスペース防止。
class NovelListCard extends StatelessWidget {
  final Novel novel;
  final VoidCallback? onTap;

  /// フィーリング発掘の一致度ラベル（例: かなり近い / 近い / キーワード一致）。
  /// null の場合はラベル非表示。
  final String? matchLabel;

  /// キーワード一致バッジを表示するか（フィーリング発掘）。
  final bool isKeywordMatch;

  /// AI未解析バッジを表示するか（フィーリング発掘）。
  final bool isAiUnanalyzed;

  /// 呼び出し側が任意で追加するバッジ群（「参考なし」等）。
  final List<Widget> extraBadges;

  const NovelListCard({
    super.key,
    required this.novel,
    this.matchLabel,
    this.isKeywordMatch = false,
    this.isAiUnanalyzed = false,
    this.extraBadges = const <Widget>[],
    this.onTap,
  });

  /// カバー画像のアスペクト比（縦 : 横 = 1.4 : 1）。
  /// カード高さから横幅を自動計算し、cover でトリミングしつつ大きく表示。
  static const double _coverAspect = 1.4;

  /// 高さ無制限（SliverList 等）で構築される場合の固定カバー高。
  /// unbounded な maxHeight をそのまま使うと SizedBox(∞) が生成され
  /// 「BoxConstraints forces an infinite height」でクラッシュするため。
  static const double _listCoverHeight = 101.0;

  static const EdgeInsets _cardPadding = EdgeInsets.all(8.0);
  static const double _hGap = 8.0;
  static const double _vGap = 6.0;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: _cardPadding,
          // LayoutBuilder で「親が有限高さか」を判定（Grid=true / List=false）。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final bool hasBounded = constraints.maxHeight.isFinite;
              // カバー高さ:
              // - bounded（Grid 等）: カード高さいっぱいに表示。
              // - unbounded（SliverList 等）: 固定高。maxHeight（=∞）をそのまま
              //   使うと SizedBox(∞) が生成されレイアウトでクラッシュする
              //   （スマホの1列表示でのみ発生する端末依存クラッシュの根因）。
              final double coverH = hasBounded
                  ? constraints.maxHeight
                  : _listCoverHeight;
              final double coverW = coverH / _coverAspect; // 縦:横 = 1.4:1
              return Row(
                // unbounded のとき stretch は子に tight(∞) を渡してクラッシュ
                // するため、固定高で上寄せする start に切り替える。
                crossAxisAlignment: hasBounded
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.start,
                children: [
                  _buildCover(coverW: coverW, coverH: coverH),
                  const SizedBox(width: _hGap),
                  // Row の幅は有限なので Expanded は安全。
                  Expanded(
                    child: _buildTextColumn(context, hasBounded: hasBounded),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// カバー画像。カード高さいっぱい（縦:横 = 1.4:1）に表示。
  /// cover でトリミングしつつ、表示領域を大きく確保する。
  Widget _buildCover({required double coverW, required double coverH}) {
    final String coverUrl = novel.coverUrl.isNotEmpty
        ? novel.coverUrl
        : (novel.rawCoverUrl ?? '');

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: coverW,
        height: coverH,
        child: coverUrl.isNotEmpty
            ? PixivImage(
                url: coverUrl,
                fit: BoxFit.cover,
                isThumbnail: true,
                errorWidget: const _CoverPlaceholder(),
                placeholder: const _CoverPlaceholder(),
              )
            : const _CoverPlaceholder(),
      ),
    );
  }

  /// テキスト部カラム。
  /// - 常に mainAxisSize: min（コンテンツ自然高、ストレッチなし）。
  /// - bounded: caption / series は表示しない（省スペース、188pxに収める）。
  /// - unbounded: caption / series を1行ずつ追加。
  Widget _buildTextColumn(BuildContext context, {required bool hasBounded}) {
    final colorScheme = Theme.of(context).colorScheme;
    final bool showCaption = !hasBounded && novel.caption.trim().isNotEmpty;
    final bool showSeries = !hasBounded && novel.series != null;
    final bool hasTags = novel.tags.isNotEmpty;

    final children = <Widget>[];

    // バッジ行（空なら Widget ごと生成しない）
    final badges = _buildBadges(context);
    if (badges.isNotEmpty) {
      children.add(Wrap(spacing: 4, runSpacing: 2, children: badges));
      children.add(const SizedBox(height: _vGap));
    }

    // 1. タイトル（一致度ラベルを先頭にインライン表示し、別行バッジを省いて縦幅を節約）
    final bool hasLabel = matchLabel != null && matchLabel!.isNotEmpty;
    children.add(
      RichText(
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: DefaultTextStyle.of(
            context,
          ).style.copyWith(fontWeight: FontWeight.bold, fontSize: 14),
          children: [
            if (hasLabel)
              TextSpan(
                text: '$matchLabel ',
                style: TextStyle(color: colorScheme.tertiary, fontSize: 13),
              ),
            TextSpan(text: novel.title),
          ],
        ),
      ),
    );

    // 2. 間隔
    children.add(const SizedBox(height: _vGap));

    // 3. 作者行
    children.add(_buildAuthorRow(context));

    // 4. 間隔
    children.add(const SizedBox(height: _vGap));

    // 5. タグ（最大3、Wrap で折り返し→横オーバーフローなし）
    if (hasTags) {
      children.add(_buildTags(context));
    }

    // unbounded のときのみ caption / series を追加（bounded は非表示）
    if (showCaption) {
      children.add(const SizedBox(height: _vGap));
      children.add(
        Text(
          novel.caption.trim(),
          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    if (showSeries) {
      children.add(const SizedBox(height: _vGap));
      children.add(
        Row(
          children: [
            const Icon(
              Icons.collections_bookmark,
              size: 13,
              color: Colors.blueAccent,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                novel.series!.title,
                style: TextStyle(fontSize: 12, color: colorScheme.secondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    // 6. メタ行
    children.add(_buildMetaRow(context));

    return Column(
      // stretch: 全子（バッジ/タイトル/タグWrap/メタ）をテキストエリア幅いっぱいに広げ、
      // タグがカード右端で折り返し、はみ出しを防止。右端がカード端に揃う。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      // 画像は固定サイズ(72×101)で Spacer なし。min で自然高に収める。
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 作者行（アイコンは常に丸型 / PixivImage で Referer 付き取得）。
  Widget _buildAuthorRow(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final String? avatar = novel.author.avatar;
    final bool hasAvatar = avatar != null && avatar.isNotEmpty;

    return Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: ClipOval(
            child: hasAvatar
                ? PixivImage(
                    url: avatar,
                    fit: BoxFit.cover,
                    isThumbnail: true,
                    errorWidget: const _AvatarPlaceholder(),
                    placeholder: const _AvatarPlaceholder(),
                  )
                : const _AvatarPlaceholder(),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            novel.author.name,
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// タグ（最大3個）。Wrap で折り返し、右端での切れ/オーバーフローを防止。
  Widget _buildTags(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tags = novel.tags.take(4).toList();
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: [
        for (final t in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '#$t',
              style: TextStyle(fontSize: 10, color: colorScheme.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  /// メタ行（文字数 / ページ数 / ブクマ）。薄めの色。
  /// Row の幅は有限なので Expanded + ellipsis は安全。
  Widget _buildMetaRow(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(Icons.notes, size: 12, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(
            novel.textLength > 0 ? _formatNumber(novel.textLength) : '不明',
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
            maxLines: 1,
          ),
          const SizedBox(width: 10),
          Icon(Icons.menu_book, size: 12, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(
            novel.pageCount > 0 ? '${novel.pageCount}P' : '不明',
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
            maxLines: 1,
          ),
          const SizedBox(width: 10),
          Icon(Icons.bookmark, size: 12, color: colorScheme.primary),
          const SizedBox(width: 3),
          Expanded(
            child: Text(
              _formatNumber(novel.totalBookmarks),
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// バッジ群を組み立てる（空リストなら呼び出し側で非表示にする）。
  /// - matchLabel: タイトル先頭にインライン表示されるためここでは生成しない
  /// - isKeywordMatch: キーワード一致
  /// - isAiUnanalyzed: AI未解析
  /// - extraBadges: 呼び出し側任意（「参考なし」等）
  List<Widget> _buildBadges(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 類似度%はタイトル先頭にインライン表示するためここでは生成しない。
    final list = <Widget>[];
    if (isKeywordMatch) {
      list.add(_badge(Icons.label, 'キーワード一致', colorScheme.tertiary));
    }
    if (isAiUnanalyzed) {
      list.add(
        _badge(Icons.auto_awesome, 'AI未解析', colorScheme.onSurfaceVariant),
      );
    }
    list.addAll(extraBadges);
    return list;
  }

  Widget _badge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 10, color: color)),
        ],
      ),
    );
  }

  /// 呼び出し側が [extraBadges] に渡すバッジを生成するファクトリ。
  static Widget buildExtraBadge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 10, color: color)),
        ],
      ),
    );
  }

  static String _formatNumber(int number) {
    if (number >= 10000) {
      return '${(number / 10000).toStringAsFixed(1)}万';
    }
    return number.toString();
  }
}

/// 作者アイコンの円形プレースホルダ（未設定・読み込み失敗時）。
class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.surfaceContainerHigh,
      ),
      child: Center(
        child: Icon(
          Icons.person,
          size: 12,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// カバー画像のプレースホルダ（const で再利用）。
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      color: colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.menu_book,
        color: colorScheme.onSurfaceVariant,
        size: 32,
      ),
    );
  }
}
