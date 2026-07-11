import 'illust_model.dart' show Author, cleanCaption;

class NovelSeriesInfo {
  final int id;
  final String title;

  NovelSeriesInfo({required this.id, required this.title});

  factory NovelSeriesInfo.fromJson(Map<String, dynamic> json) {
    return NovelSeriesInfo(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'title': title};
}

class Novel {
  final int id;
  final String title;
  final String caption;
  final Author author;
  final List<String> tags;
  final String coverUrl;
  final String? rawCoverUrl;
  final int textCount;
  final int wordCount;
  final int textLength;
  final int pageCount;
  final String createDate;
  final int totalView;
  final int totalBookmarks;
  bool isBookmarked; // リアルタイムお気に入り切り替えのため非final
  final NovelSeriesInfo? series; // シリーズ情報

  Novel({
    required this.id,
    required this.title,
    required this.caption,
    required this.author,
    required this.tags,
    required this.coverUrl,
    this.rawCoverUrl,
    required this.textCount,
    required this.wordCount,
    required this.textLength,
    required this.pageCount,
    required this.createDate,
    required this.totalView,
    required this.totalBookmarks,
    required this.isBookmarked,
    this.series,
  });

  factory Novel.fromJson(Map<String, dynamic> json) {
    final tagsList = json['tags'] as List<dynamic>?;
    final List<String> parsedTags = tagsList != null
        ? tagsList
              .map((e) {
                if (e is Map<String, dynamic>) {
                  return e['name'] as String? ?? '';
                }
                return e.toString();
              })
              .where((t) => t.isNotEmpty)
              .toList()
        : <String>[];

    final user = json['user'] as Map<String, dynamic>?;
    final Author author = user != null
        ? Author.fromJson(user)
        : Author(id: 0, name: '名無しユーザー', account: '');

    final imageUrls = json['image_urls'] as Map<String, dynamic>?;
    final String coverUrl =
        imageUrls?['large'] as String? ??
        imageUrls?['medium'] as String? ??
        imageUrls?['square_medium'] as String? ??
        '';

    NovelSeriesInfo? parsedSeries;
    final seriesRaw = json['series'];
    if (seriesRaw != null) {
      try {
        final s = seriesRaw as Map<String, dynamic>;
        final seriesId = s['id'] as int? ?? 0;
        // 無効なID(0)の場合はダミー系列を作らず null のままにする（API 400エラー防止）
        if (seriesId != 0) {
          parsedSeries = NovelSeriesInfo(
            id: seriesId,
            title: s['title'] as String? ?? 'Unknown Series',
          );
        }
      } catch (_) {
        // パースエラー時はスルー
      }
    }

    int textLength = 0;
    for (final key in const ['text_length', 'text_count', 'word_count']) {
      final v = json[key];
      if (v != null) {
        final parsed = int.tryParse(v.toString());
        if (parsed != null) {
          textLength = parsed;
          break;
        }
      }
    }

    return Novel(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? '無題',
      caption: cleanCaption(json['caption'] as String? ?? ''),
      author: author,
      tags: parsedTags,
      coverUrl: coverUrl,
      rawCoverUrl: coverUrl.isNotEmpty ? coverUrl : null,
      textCount: textLength,
      wordCount: textLength,
      textLength: textLength,
      pageCount: json['page_count'] as int? ?? 1,
      createDate: json['create_date'] as String? ?? '',
      totalView: json['total_view'] as int? ?? 0,
      totalBookmarks: json['total_bookmarks'] as int? ?? 0,
      isBookmarked: json['is_bookmarked'] as bool? ?? false,
      series: parsedSeries,
    );
  }

  /// Isolate 間通信（compute）のためのシリアライズ用。
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'caption': caption,
    'user': author.toJson(),
    'tags': tags.map((t) => {'name': t}).toList(),
    'image_urls': rawCoverUrl != null ? {'large': rawCoverUrl} : {'large': ''},
    'text_length': textLength,
    'text_count': textCount,
    'word_count': wordCount,
    'page_count': pageCount,
    'create_date': createDate,
    'total_view': totalView,
    'total_bookmarks': totalBookmarks,
    'is_bookmarked': isBookmarked,
    if (series != null) 'series': series!.toJson(),
  };
}

class NovelTextData {
  final int id;
  final String novelText;
  final List<String> novelPages;

  NovelTextData({
    required this.id,
    required this.novelText,
    required this.novelPages,
  });

  factory NovelTextData.fromJson(Map<String, dynamic> json) {
    var pagesList = json['novel_pages'] as List<dynamic>?;
    List<String> parsedPages = pagesList != null
        ? pagesList.map((e) => e.toString()).toList()
        : [];

    return NovelTextData(
      id: json['id'] as int,
      novelText: json['novel_text'] as String? ?? '',
      novelPages: parsedPages,
    );
  }
}
