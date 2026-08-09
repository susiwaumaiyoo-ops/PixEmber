// ignore_for_file: avoid_print
import 'dart:convert';
import '../illust_model.dart';
import '../novel_model.dart';
import 'pixiv_api_http.dart';

/// API 取得結果のラッパー。
/// 一覧 [items] に加え、次ページ取得用の [nextUrl]（Pixiv が返す next_url そのもの）
/// と検索時の百科事典カード [searchItem] を保持する。
class FetchResult<T> {
  final List<T> items;
  final String? nextUrl;
  final SearchItem? searchItem;

  const FetchResult({required this.items, this.nextUrl, this.searchItem});

  /// 次ページの offset を [nextUrl] から安全に抽出する。
  /// next_url が存在しない場合は null を返し、呼び出し側でページングを終了させる。
  int? get nextOffset {
    if (nextUrl == null || nextUrl!.isEmpty) return null;
    try {
      final uri = Uri.parse(nextUrl!);
      final offsetStr = uri.queryParameters['offset'];
      if (offsetStr == null) return null;
      return int.tryParse(offsetStr);
    } catch (_) {
      return null;
    }
  }

  bool get hasNext => nextOffset != null;
}

/// 全文検索（all_text）の結果と更新された検索状態を保持するラッパー。
class AllTextSearchResult<T> {
  final FetchResult<T> result;
  final AllTextSearchState state;

  const AllTextSearchResult({required this.result, required this.state});
}

/// 全文検索の状態を保持するクラス
class AllTextSearchState<T> {
  final int tagNextOffset;
  final int textNextOffset;
  final int tagPageCount;
  final int textPageCount;
  final List<T> tagItems;
  final List<T> textItems;

  const AllTextSearchState({
    this.tagNextOffset = 0,
    this.textNextOffset = 0,
    this.tagPageCount = 0,
    this.textPageCount = 0,
    this.tagItems = const [],
    this.textItems = const [],
  });

  bool get hasNext => tagNextOffset != 0 || textNextOffset != 0;

  AllTextSearchState<T> copyWith({
    int? tagNextOffset,
    int? textNextOffset,
    int? tagPageCount,
    int? textPageCount,
    List<T>? tagItems,
    List<T>? textItems,
  }) {
    return AllTextSearchState<T>(
      tagNextOffset: tagNextOffset ?? this.tagNextOffset,
      textNextOffset: textNextOffset ?? this.textNextOffset,
      tagPageCount: tagPageCount ?? this.tagPageCount,
      textPageCount: textPageCount ?? this.textPageCount,
      tagItems: tagItems ?? this.tagItems,
      textItems: textItems ?? this.textItems,
    );
  }

  static const AllTextSearchState empty = AllTextSearchState();
}

class PixivApiService {
  final PixivHttpClient _http = PixivHttpClient();

  /// 共通のGETリクエストメソッド（PixivHttpClient に委譲）
  Future<String> _get(String endpoint, {Map<String, String>? params}) =>
      _http.get(endpoint, params: params);

  /// 取得結果ラッパー（一覧 + ページングURL + 百科事典カード）
  /// [rawBody] から next_url を抽出する（メインスレッドで軽量にデコード）。
  FetchResult<T> _wrap<T>({
    required String rawBody,
    required T Function(Map<String, dynamic>) fromJson,
  }) {
    final resData = jsonDecode(rawBody) as Map<String, dynamic>;
    final body = resData['body'] as Map<String, dynamic>;
    final works = body['works'] as List<dynamic>? ?? [];
    final nextUrl = body['next_url'] as String?;

    final items = works
        .map((w) => fromJson(w as Map<String, dynamic>))
        .toList();
    final searchItem = body['search_item'] != null
        ? SearchItem.fromJson(body['search_item'] as Map<String, dynamic>)
        : null;

    return FetchResult<T>(
      items: items,
      nextUrl: nextUrl,
      searchItem: searchItem,
    );
  }

  // ==========================================
  // おすすめ・検索・ランキング・シリーズ
  // ==========================================

  /// イラストおすすめ取得
  Future<FetchResult<Illust>> getRecommend({int offset = 0}) async {
    final body = await _get(
      '/v1/illust/recommended',
      params: {'offset': offset.toString()},
    );
    return _wrap<Illust>(
      rawBody: body,
      fromJson: (json) => Illust.fromJson(json),
    );
  }

  /// イラスト検索
  Future<FetchResult<Illust>> searchIllust(
    String query, {
    int offset = 0,
    String searchTarget = 'partial_match_for_tags',
    int sort = 0,
    bool mergeResults = true,
  }) async {
    final body = await _get(
      '/v1/search/illust',
      params: {
        'word': query,
        'search_target': searchTarget,
        'sort': sort.toString(),
        'merge_results': mergeResults.toString(),
        'offset': offset.toString(),
      },
    );
    return _wrap<Illust>(
      rawBody: body,
      fromJson: (json) => Illust.fromJson(json),
    );
  }

  /// 関連イラスト取得
  Future<List<Illust>> getIllustRelated(int illustId) async {
    final body = await _get(
      '/v2/illust/related',
      params: {'illust_id': illustId.toString()},
    );
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final works = (resData['body']?['works'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    return works.map((w) => Illust.fromJson(w)).toList();
  }

  /// イラストランキング取得
  Future<FetchResult<Illust>> getRanking(String mode, {int offset = 0}) async {
    final body = await _get(
      '/v1/illust/ranking',
      params: {'mode': mode, 'offset': offset.toString()},
    );
    return _wrap<Illust>(
      rawBody: body,
      fromJson: (json) => Illust.fromJson(json),
    );
  }

  /// 小説ランキング取得
  Future<FetchResult<Novel>> getNovelRanking(
    String mode, {
    int offset = 0,
    bool includeR18 = false,
  }) async {
    final params = <String, String>{'mode': mode, 'offset': offset.toString()};
    if (includeR18) {
      params['filter'] = 'all';
    }

    final body = await _get('/v1/novel/ranking', params: params);
    return _wrap<Novel>(
      rawBody: body,
      fromJson: (json) => Novel.fromJson(json),
    );
  }

  /// 小説おすすめ取得
  Future<FetchResult<Novel>> getNovelRecommend({
    int offset = 0,
    bool includeR18 = false,
  }) async {
    final params = <String, String>{'offset': offset.toString()};
    if (includeR18) {
      params['filter'] = 'all';
    }

    final body = await _get('/v1/novel/recommended', params: params);
    return _wrap<Novel>(
      rawBody: body,
      fromJson: (json) => Novel.fromJson(json),
    );
  }

  /// 小説検索
  Future<FetchResult<Novel>> searchNovel(
    String query, {
    int offset = 0,
    String searchTarget = 'partial_match_for_tags',
    int sort = 0,
    bool mergeResults = true,
  }) async {
    final body = await _get(
      '/v1/search/novel',
      params: {
        'word': query,
        'search_target': searchTarget,
        'sort': sort.toString(),
        'merge_results': mergeResults.toString(),
        'offset': offset.toString(),
      },
    );
    return _wrap<Novel>(
      rawBody: body,
      fromJson: (json) => Novel.fromJson(json),
    );
  }

  /// 小説全文検索（自由な文字検索）。
  ///
  /// Pixiv の search_target は単一指定のため、「タグの部分一致」と「本文(text)」
  /// を並行で検索し、結果をIDで統合して返す。これによりタイトル・タグ・本文の
  /// いずれかに検索語を含む小説を漏れなく取得できる。
  ///
  /// ページングは [AllTextSearchState] で管理する。タグ検索と本文検索は独立した
  /// ページング状態を持つため、それぞれの nextUrl/offset を別々に追跡する。
  /// 重複除去は API 側で ID ベースで実施する。
  /// 戻り値は [AllTextSearchResult] で、更新された検索状態も含む。
  Future<AllTextSearchResult<Novel>> searchNovelAllText(
    String query, {
    AllTextSearchState? state,
  }) async {
    state ??= AllTextSearchState.empty;

    // タグ検索
    final tagResult = await searchNovel(
      query,
      offset: state.tagNextOffset,
      searchTarget: 'partial_match_for_tags',
      sort: 0,
      mergeResults: true,
    );

    // 本文検索
    final textResult = await searchNovel(
      query,
      offset: state.textNextOffset,
      searchTarget: 'text',
      sort: 0,
      mergeResults: true,
    );

    // 重複除去（IDで統合）
    final allIds = <int>{};
    final tagItems = <Novel>[];
    final textItems = <Novel>[];

    for (var item in tagResult.items) {
      if (!allIds.contains(item.id)) {
        allIds.add(item.id);
        tagItems.add(item);
      }
    }

    for (var item in textResult.items) {
      if (!allIds.contains(item.id)) {
        allIds.add(item.id);
        textItems.add(item);
      }
    }

    // 統合結果の作成
    final newState = AllTextSearchState(
      tagNextOffset: tagResult.nextOffset ?? 0,
      textNextOffset: textResult.nextOffset ?? 0,
      tagPageCount: tagResult.items.length,
      textPageCount: textResult.items.length,
      tagItems: tagItems,
      textItems: textItems,
    );

    return AllTextSearchResult<Novel>(
      result: FetchResult<Novel>(
        items: [...tagItems, ...textItems],
        nextUrl: tagResult.nextUrl,
        searchItem: tagResult.searchItem,
      ),
      state: newState,
    );
  }

  /// 小説シリーズのエピソード一覧取得
  Future<List<Novel>> getNovelSeries(int seriesId, {int? lastOrder}) async {
    print('📍 [DEBUG API] getNovelSeries リクエスト直前: seriesId = $seriesId');
    final params = <String, String>{'series_id': seriesId.toString()};
    if (lastOrder != null) {
      params['last_order'] = lastOrder.toString();
    }

    final body = await _get('/v1/novel/series', params: params);
    print('📍 [DEBUG API] getNovelSeries デコード直前');

    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final episodes = bodyData['episodes'] as List<dynamic>? ?? [];

    return episodes
        .map((e) => Novel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 小説シリーズのエピソード一覧を全ページ取得する（ページネーション対応）。
  /// /v1/novel/series は last_order によるページングを返すため、next_url が
  /// なくなるまで繰り返し取得し、全エピソードを結合して返す。
  /// シリーズ統計文字数検索で全話の文字数を合算するために使用する。
  Future<List<Novel>> getNovelSeriesAll(int seriesId) async {
    print('📍 [DEBUG API] getNovelSeriesAll 開始: seriesId = $seriesId');
    final all = <Novel>[];

    int? lastOrder;

    while (true) {
      final episodes = await getNovelSeries(seriesId, lastOrder: lastOrder);

      if (episodes.isEmpty) {
        break;
      }

      all.addAll(episodes);

      // 最後のエピソードの last_order を取得
      final lastEpisode = episodes.last;
      lastOrder = lastEpisode.seriesOrder;

      print(
        '📍 [DEBUG API] getNovelSeriesAll 完了: seriesId=$seriesId, count=${all.length}',
      );
    }

    return all;
  }
}
