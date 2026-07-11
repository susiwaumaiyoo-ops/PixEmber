/// main.py の clean_caption と同等の処理（HTMLタグ除去・改行正規化）。
String cleanCaption(String caption) {
  if (caption.isEmpty) return "";
  var s = caption.replaceAllMapped(
    RegExp(r'<br\s*/?>', caseSensitive: false),
    (_) => '\n',
  );
  s = s.replaceAll(RegExp(r'<[^>]*>'), '');
  s = s.replaceAllMapped(RegExp(r'\n{3,}'), (_) => '\n\n');
  return s.trim();
}

class Illust {
  final int id;
  final String title;
  final String caption;
  final Author author;
  final List<String> tags;
  final IllustUrls urls;
  final int pageCount;
  final List<PageImage> metaPages;
  final int width;
  final int height;
  final int totalView;
  final int totalBookmarks;
  final String createDate;
  final String type;
  bool isBookmarked; // リアルタイム切り替えのため非final

  Illust({
    required this.id,
    required this.title,
    required this.caption,
    required this.author,
    required this.tags,
    required this.urls,
    required this.pageCount,
    required this.metaPages,
    required this.width,
    required this.height,
    required this.totalView,
    required this.totalBookmarks,
    required this.createDate,
    required this.type,
    required this.isBookmarked,
  });

  factory Illust.fromJson(Map<String, dynamic> json) {
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
    final metaSingle = json['meta_single_page'] as Map<String, dynamic>?;
    final IllustUrls urls = IllustUrls.fromJson(
      imageUrls,
      metaSinglePage: metaSingle,
    );

    final pagesList = json['meta_pages'] as List<dynamic>?;
    final List<PageImage> parsedPages = pagesList != null
        ? pagesList.map((e) {
            final p = e as Map<String, dynamic>;
            final pu = p['image_urls'] as Map<String, dynamic>?;
            final medium = pu?['medium'] as String?;
            final large = pu?['large'] as String?;
            final original = pu?['original'] as String?;
            return PageImage(
              page: (p['page'] as int? ?? 0) + 1,
              preview: medium ?? large,
              original: original ?? large ?? medium,
              rawPreview: medium ?? large,
              rawOriginal: original ?? large ?? medium,
            );
          }).toList()
        : <PageImage>[];

    return Illust(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? '無題',
      caption: cleanCaption(json['caption'] as String? ?? ''),
      author: author,
      tags: parsedTags,
      urls: urls,
      pageCount:
          json['page_count'] as int? ??
          (parsedPages.isNotEmpty ? parsedPages.length : 1),
      metaPages: parsedPages,
      width: json['width'] as int? ?? 0,
      height: json['height'] as int? ?? 0,
      totalView: json['total_view'] as int? ?? 0,
      totalBookmarks: json['total_bookmarks'] as int? ?? 0,
      createDate: json['create_date'] as String? ?? '',
      type: json['type'] as String? ?? 'illust',
      isBookmarked: json['is_bookmarked'] as bool? ?? false,
    );
  }

  /// Isolate 間通信（compute）のためのシリアライズ用。
  /// StandardMessageCodec はカスタムクラスを送れないため、生 Map に戻す。
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'caption': caption,
    'user': author.toJson(),
    'tags': tags.map((t) => {'name': t}).toList(),
    'image_urls': urls.toJson(),
    'page_count': pageCount,
    'meta_pages': metaPages.map((p) => p.toJson()).toList(),
    'meta_single_page':
        urls.original != null ? {'original_image_url': urls.original} : {},
    'width': width,
    'height': height,
    'total_view': totalView,
    'total_bookmarks': totalBookmarks,
    'create_date': createDate,
    'type': type,
    'is_bookmarked': isBookmarked,
  };
}

class Author {
  final int id;
  final String name;
  final String account;
  final String? avatar;

  Author({
    required this.id,
    required this.name,
    required this.account,
    this.avatar,
  });

  factory Author.fromJson(Map<String, dynamic> json) {
    final profile = json['profile_image_urls'] as Map<String, dynamic>?;
    return Author(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '名無しユーザー',
      account: json['account'] as String? ?? '',
      avatar: profile?['medium'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'account': account,
    if (avatar != null) 'profile_image_urls': {'medium': avatar},
  };
}

class IllustUrls {
  final String? preview;
  final String? original;
  final String? rawPreview;
  final String? rawOriginal;

  IllustUrls({this.preview, this.original, this.rawPreview, this.rawOriginal});

  /// 生の Pixiv API JSON (image_urls / meta_single_page) から構築する。
  factory IllustUrls.fromJson(
    Map<String, dynamic>? imageUrls, {
    Map<String, dynamic>? metaSinglePage,
  }) {
    final medium = imageUrls?['medium'] as String?;
    final large = imageUrls?['large'] as String?;
    final square = imageUrls?['square_medium'] as String?;
    String? original = metaSinglePage?['original_image_url'] as String?;
    original ??= large ?? medium ?? square;
    final preview = medium ?? large ?? square;
    return IllustUrls(
      preview: preview,
      original: original,
      rawPreview: preview,
      rawOriginal: original,
    );
  }

  Map<String, dynamic> toJson() => {
    'medium': preview,
    if (original != null) 'large': original,
  };
}

class PageImage {
  final int page;
  final String? preview;
  final String? original;
  final String? rawPreview;
  final String? rawOriginal;

  PageImage({
    required this.page,
    this.preview,
    this.original,
    this.rawPreview,
    this.rawOriginal,
  });

  factory PageImage.fromJson(Map<String, dynamic> json) {
    return PageImage(
      page: json['page'] as int? ?? 1,
      preview: json['preview'] as String?,
      original: json['original'] as String?,
      rawPreview: json['raw_preview'] as String?,
      rawOriginal: json['raw_original'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'page': page,
    'image_urls': {
      'medium': preview,
      'large': original,
      'original': rawOriginal,
    },
  };
}

class SearchItem {
  final String name;
  final String dicUrl;
  final String summary;
  final String? iconUrl;
  final int wordCount;

  SearchItem({
    required this.name,
    required this.dicUrl,
    required this.summary,
    this.iconUrl,
    required this.wordCount,
  });

  factory SearchItem.fromJson(Map<String, dynamic> json) {
    return SearchItem(
      name: json['name'] as String? ?? '',
      dicUrl: json['dic_url'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      iconUrl: json['icon_url'] as String?,
      wordCount: json['word_count'] as int? ?? 0,
    );
  }
}
