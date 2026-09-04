// B1: 検索結果から開いたイラスト詳細で画像ロードが途中で止まる問題。
// /v1/search/illust のレスポンスアイテムは image_urls/meta_single_page/
// meta_pages を持わずトップレベル url（master1200）のみであるため、
// (1) Illust.fromJson が url で補完すること（詳細に画像URLが渡る）
// (2) 再取得トリガ判定 hasIncompleteImageMeta の正しさ
// (3) IllustDetailState.applyFullMeta が illust/handler を差し替えること
// を検証する。

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/screens/illust_detail_state.dart';

/// 検索API（/v1/search/illust）形状: image_urls/meta_pages がない。
Map<String, dynamic> _searchItemJson({int pageCount = 1}) => {
  'id': 105553323,
  'title': '検索作品',
  'type': 'illust',
  'page_count': pageCount,
  'caption': 'caption',
  'width': 1200,
  'height': 1600,
  'total_view': 100,
  'total_bookmarks': 200,
  'create_date': '2026-08-01T12:00:00+09:00',
  'x_restrict': 0,
  'illust_ai_type': 0,
  'tags': [
    {'name': '猫'},
  ],
  'user': {
    'id': 42,
    'name': '作者',
    'account': 'account',
    'profile_image_urls': {
      'medium': 'https://t.pixiv.net/img/profile_images/42.jpg',
    },
  },
  'url': 'https://i.pximg.net/img-master/xxx/105553323_p0_master1200.jpg',
};

/// 詳細API（/v1/illust/detail）形状: image_urls + meta_single_page を持つ。
Map<String, dynamic> _detailItemJson() => {
  'id': 105553323,
  'title': '詳細作品',
  'type': 'illust',
  'page_count': 1,
  'caption': 'caption',
  'width': 1920,
  'height': 2560,
  'total_view': 100,
  'total_bookmarks': 200,
  'create_date': '2026-08-01T12:00:00+09:00',
  'x_restrict': 0,
  'illust_ai_type': 0,
  'tags': [
    {'name': '猫'},
  ],
  'user': {
    'id': 42,
    'name': '作者',
    'account': 'account',
    'profile_image_urls': {
      'medium': 'https://t.pixiv.net/img/profile_images/42.jpg',
    },
  },
  'image_urls': {
    'medium': 'https://i.pximg.net/c/1200x1200/img-master/xxx/_medium.jpg',
    'large': 'https://i.pximg.net/img-master/xxx/_large.jpg',
  },
  'meta_single_page': {
    'original_image_url': 'https://i.pximg.net/img-original/xxx/original.jpg',
  },
};

void main() {
  group('B1: 検索結果→詳細で画像URLが渡る（再現）', () {
    test('検索API形状: トップレベル url が preview/original に補完される', () {
      final searchUrl = _searchItemJson()['url'] as String;
      final i = Illust.fromJson(_searchItemJson());
      expect(i.urls.preview, searchUrl);
      expect(i.urls.original, searchUrl);
      expect(i.urls.preview, isNotEmpty);
      expect(i.urls.original, isNotEmpty);
    });

    test('詳細API形状: meta_single_page のオリジナルURLがそのまま original', () {
      final i = Illust.fromJson(_detailItemJson());
      expect(
        i.urls.original,
        'https://i.pximg.net/img-original/xxx/original.jpg',
      );
      expect(
        i.urls.preview,
        'https://i.pximg.net/c/1200x1200/img-master/xxx/_medium.jpg',
      );
    });
  });

  group('B1: 再取得トリガ hasIncompleteImageMeta', () {
    test('1ページ・検索形状（url補完済み）: 再取得不要', () {
      final i = Illust.fromJson(_searchItemJson(pageCount: 1));
      expect(i.hasIncompleteImageMeta, isFalse);
    });

    test('複数ページ・検索形状（meta_pages 欠落）: 再取得必要', () {
      final i = Illust.fromJson(_searchItemJson(pageCount: 3));
      expect(i.hasIncompleteImageMeta, isTrue);
    });

    test('詳細API形状: 再取得不要', () {
      final i = Illust.fromJson(_detailItemJson());
      expect(i.hasIncompleteImageMeta, isFalse);
    });
  });

  group('B1: IllustDetailState.applyFullMeta', () {
    test('illust と handler.illust が完全メタに差し替わりブックマーク状態保持', () {
      final search = Illust.fromJson(_searchItemJson(pageCount: 2));
      search.isBookmarked = true;
      final state = IllustDetailState(illust: search);

      final full = Illust.fromJson(_detailItemJson());
      state.applyFullMeta(full);

      expect(identical(state.illust, full), isTrue);
      expect(identical(state.handler.illust, full), isTrue);
      expect(state.isBookmarked, isTrue);
      expect(
        state.illust.urls.original,
        'https://i.pximg.net/img-original/xxx/original.jpg',
      );
    });
  });
}
