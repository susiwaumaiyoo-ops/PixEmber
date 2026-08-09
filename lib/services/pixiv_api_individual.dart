// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'database_service.dart';
import '../illust_model.dart';
import '../novel_model.dart';
import 'pixiv_api_http.dart';

/// 429 Rate Limit エラー用のカスタム例外クラス
class RateLimitException implements Exception {
  final String message;
  final int statusCode;

  RateLimitException(this.message, {this.statusCode = 429});

  @override
  String toString() => 'RateLimitException: $message (Status: $statusCode)';
}

/// ミュート設定用のデータクラス
class _MuteFilter {
  final List<String> mutedTags;
  final List<int> mutedUserIds;
  final String? aiMuteValue;

  _MuteFilter({
    required this.mutedTags,
    required this.mutedUserIds,
    this.aiMuteValue,
  });
}

class PixivApiService {
  static final PixivApiService _instance = PixivApiService._internal();
  factory PixivApiService() => _instance;
  PixivApiService._internal();

  final String _baseUrl = 'https://app-api.pixiv.net';

  // Pixiv App-APIクライアント用の定数ヘッダー（公式アプリの擬態）
  final Map<String, String> _clientHeaders = {
    'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
    'App-OS': 'android',
    'App-OS-Version': '11',
    'App-Version': '6.71.1',
    'Accept-Language': 'ja-JP',
  };

  final DatabaseService _dbService = DatabaseService();

  /// 認証アクセストークンの取得（必要に応じて自動リフレッシュ）
  Future<String> getAccessToken(String refreshToken) async {
    try {
      // 1. ミリ秒を完全に排除した ISO 8601 UTC 時刻を自律生成
      final now = DateTime.now().toUtc();
      final clientTime =
          "${now.year.toString().padLeft(4, '0')}-"
          "${now.month.toString().padLeft(2, '0')}-"
          "${now.day.toString().padLeft(2, '0')}T"
          "${now.hour.toString().padLeft(2, '0')}:"
          "${now.minute.toString().padLeft(2, '0')}:"
          "${now.second.toString().padLeft(2, '0')}+00:00";

      // 2. 署名の計算
      final salt = "2821213q311543184o13o121o131o1o3";
      final input = clientTime + salt;
      final clientHash = md5.convert(utf8.encode(input)).toString();

      print("[DEBUG API SERVICE] Client Time: $clientTime");
      print("[DEBUG API SERVICE] Client Hash: $clientHash");

      final url = Uri.parse("https://oauth.secure.pixiv.net/auth/token");
      final headers = {
        "User-Agent": "PixivAndroidApp/5.0.234 (Android 11.0; Pixel 5)",
        "App-OS": "android",
        "App-OS-Version": "11.0",
        "App-Version": "5.0.234",
        "X-Client-Time": clientTime,
        "X-Client-Hash": clientHash,
        "Accept-Language": "ja-JP",
        "Content-Type": "application/x-www-form-urlencoded",
      };

      final data = {
        "client_id": "MOBrBDS8blbauoSck0ZfDbtuzpyT",
        "client_secret": "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj",
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
      };

      final response = await http.post(url, headers: headers, body: data);

      if (response.statusCode == 200) {
        final resData = jsonDecode(response.body);
        final responsePayload = resData['response'];
        if (responsePayload != null) {
          final accessToken = responsePayload['access_token'];
          if (accessToken != null) {
            return accessToken;
          }
        }
        throw Exception("レスポンス内に access_token が見つかりませんでした。");
      } else {
        print("❌❌❌ [OAuth Refresh ERROR] Pixivトークンリフレッシュに失敗しました ❌❌❌");
        print("ステータスコード: ${response.statusCode}");
        print("レスポンス内容: ${response.body}");
        throw Exception(
          "トークンのリフレッシュに失敗しました: ${response.statusCode}\n${response.body}",
        );
      }
    } catch (e, stack) {
      print("❌ [OAuth Refresh CRITICAL] 例外が発生しました: $e");
      print(stack);
      rethrow;
    }
  }

  /// SharedPreferences からリフレッシュトークンを取得（未設定なら例外）
  Future<String> getRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('PIXIV_REFRESH_TOKEN');
    if (token == null || token.isEmpty) {
      throw Exception('Pixivリフレッシュトークンが設定されていません。再ログインが必要です。');
    }
    return token;
  }

  /// 共通のGETリクエストメソッド
  Future<String> _get(String endpoint, {Map<String, String>? params}) async {
    final token = await getAccessToken(await getRefreshToken());
    final headers = {'Authorization': 'Bearer $token', ..._clientHeaders};

    final queryParams = <String, String>{};
    if (params != null) {
      queryParams.addAll(params);
    }

    final uri = Uri.parse(
      _baseUrl + endpoint,
    ).replace(queryParameters: queryParams);
    final response = await http.get(uri, headers: headers);

    if (response.statusCode == 429) {
      throw RateLimitException('Rate limit exceeded', statusCode: 429);
    }

    if (response.statusCode != 200) {
      throw Exception('API request failed: ${response.statusCode}');
    }

    return response.body;
  }

  /// 共通のPOSTリクエストメソッド（PixivHttpClient に委譲）
  Future<Map<String, dynamic>> _post(
    String endpoint, {
    Map<String, String>? body,
  }) => PixivHttpClient().post(endpoint, body: body);

  /// ミュート設定をロード
  Future<_MuteFilter> _loadMuteFilter() async {
    final mutes = await _dbService.getMutesList();

    // タグミュート設定
    final mutedTags = mutes
        .where((m) => m['mute_type'] == 'tag')
        .map((m) => m['value'].toString().toLowerCase())
        .toSet();

    // ユーザーミュート設定
    final mutedUserIds = mutes
        .where((m) => m['mute_type'] == 'user')
        .map((m) => int.tryParse(m['value'].toString()))
        .whereType<int>()
        .toSet();

    // AI作品ミュート設定
    final aiMuteRecord = mutes.firstWhere(
      (m) => m['mute_type'] == 'ai',
      orElse: () => {},
    );
    final aiMuteValue = aiMuteRecord.isNotEmpty
        ? aiMuteRecord['value'].toString()
        : null;

    return _MuteFilter(
      mutedTags: mutedTags.toList(),
      mutedUserIds: mutedUserIds.toList(),
      aiMuteValue: aiMuteValue,
    );
  }

  /// イラストのミュート適用
  Future<List<Illust>> filterIllusts(
    String rawBody, {
    String? xRestrict,
  }) async {
    final mute = await _loadMuteFilter();
    return filterIllustsIsolated(
      rawBody,
      mutedTags: mute.mutedTags,
      mutedUserIds: mute.mutedUserIds,
      xRestrict: xRestrict,
      aiMuteValue: mute.aiMuteValue,
    );
  }

  /// イラストのミュート適用（Isolateで実行）
  Future<List<Illust>> filterIllustsIsolated(
    String rawBody, {
    List<String> mutedTags = const [],
    List<int> mutedUserIds = const [],
    String? xRestrict,
    String? aiMuteValue,
  }) async {
    final results = await Isolate.run(
      () => _filterIllustsInIsolate(
        rawBody,
        mutedTags,
        mutedUserIds,
        xRestrict,
        aiMuteValue,
      ),
    );
    return results;
  }

  List<Illust> _filterIllustsInIsolate(
    String rawBody,
    List<String> mutedTags,
    List<int> mutedUserIds,
    String? xRestrict,
    String? aiMuteValue,
  ) {
    final List<Illust> filtered = [];
    final List<dynamic> illustsJson = jsonDecode(rawBody) as List<dynamic>;

    for (final item in illustsJson) {
      if (item is! Map<String, dynamic>) continue;

      final itemMap = item;
      final userId = itemMap['user']?['id'] as int?;

      // ユーザーミュートチェック
      if (mutedUserIds.isNotEmpty && userId != null) {
        if (mutedUserIds.contains(userId)) continue;
      }

      // AI作品ミュートチェック
      final aiType = itemMap['type'] as String?;
      if (aiMuteValue != null && aiMuteValue == '1' && aiType == 'ai') {
        continue;
      }

      // タグミュートチェック
      bool hasMutedTag = false;
      if (itemMap['tags'] != null) {
        final tags = itemMap['tags'] as List<dynamic>;
        for (final t in tags) {
          if (t is! Map<String, dynamic>) continue;
          final tName = (t['name'] as String? ?? '').toLowerCase();
          if (mutedTags.any((mTag) => tName.contains(mTag))) {
            hasMutedTag = true;
            break;
          }
        }
      }
      if (hasMutedTag) continue;

      filtered.add(Illust.fromJson(itemMap));
    }

    return filtered;
  }

  /// 小説のミュート適用
  Future<List<Novel>> filterNovels(String rawBody, {String? xRestrict}) async {
    final mute = await _loadMuteFilter();
    return filterNovelsIsolated(
      rawBody,
      mutedTags: mute.mutedTags,
      mutedUserIds: mute.mutedUserIds,
      xRestrict: xRestrict,
      aiMuteValue: mute.aiMuteValue,
    );
  }

  /// 小説のミュート適用（Isolateで実行）
  Future<List<Novel>> filterNovelsIsolated(
    String rawBody, {
    List<String> mutedTags = const [],
    List<int> mutedUserIds = const [],
    String? xRestrict,
    String? aiMuteValue,
  }) async {
    final results = await Isolate.run(
      () => _filterNovelsInIsolate(
        rawBody,
        mutedTags,
        mutedUserIds,
        xRestrict,
        aiMuteValue,
      ),
    );
    return results;
  }

  List<Novel> _filterNovelsInIsolate(
    String rawBody,
    List<String> mutedTags,
    List<int> mutedUserIds,
    String? xRestrict,
    String? aiMuteValue,
  ) {
    final List<Novel> filtered = [];
    final List<dynamic> novelsJsonList = jsonDecode(rawBody) as List<dynamic>;

    for (final item in novelsJsonList) {
      if (item is! Map<String, dynamic>) continue;

      final itemMap = item;
      final userId = itemMap['user']?['id'] as int?;

      // ユーザーミュートチェック
      if (mutedUserIds.isNotEmpty && userId != null) {
        if (mutedUserIds.contains(userId)) continue;
      }

      // タグミュートチェック
      bool hasMutedTag = false;
      if (itemMap['tags'] != null) {
        final tags = itemMap['tags'] as List<dynamic>;
        for (final t in tags) {
          if (t is! Map<String, dynamic>) continue;
          final tName = (t['name'] as String? ?? '').toLowerCase();
          final tTranslated = (t['translated_name'] as String? ?? '')
              .toLowerCase();

          if (mutedTags.any(
            (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
          )) {
            hasMutedTag = true;
            break;
          }
        }
      }
      if (hasMutedTag) continue;

      // AI作品ミュート
      final int aiType = itemMap['novel_ai_type'] as int? ?? 0;
      final bool isAiWork = aiType == 2;
      if (aiMuteValue != null) {
        if (aiMuteValue == '1' && isAiWork) {
          continue;
        } else if (aiMuteValue == '0' && !isAiWork) {
          continue;
        } else if (aiMuteValue == '2') {
          continue;
        }
      }

      final novel = Novel.fromJson(itemMap);
      filtered.add(novel);
    }

    return filtered;
  }

  // ==========================================
  // 各エンドポイントに対応するDartメソッド
  // ==========================================

  /// 取得結果ラッパー（一覧 + ページングURL + 百科事典カード）
  /// [rawBody] から next_url を抽出する（メインスレッドで軽量にデコード）。
  FetchResult<T> _wrap<T>({
    required List<T> items,
    required String rawBody,
    SearchItem? searchItem,
  }) {
    String? nextUrl;
    try {
      final Map<String, dynamic> data =
          jsonDecode(rawBody) as Map<String, dynamic>;
      nextUrl = data['next_url'] as String?;
    } catch (_) {
      nextUrl = null;
    }
    if (nextUrl != null && nextUrl.isEmpty) nextUrl = null;
    return FetchResult(items: items, nextUrl: nextUrl, searchItem: searchItem);
  }

  /// おすすめ取得
  Future<FetchResult<Illust>> getRecommend({int offset = 0}) async {
    final body = await _get(
      '/v1/illust/recommend',
      params: {'offset': offset.toString()},
    );
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final illustsJson = bodyData['illusts'] as List<dynamic>;
    final items = illustsJson
        .map((e) => Illust.fromJson(e as Map<String, dynamic>))
        .toList();
    return _wrap(items: items, rawBody: body);
  }

  /// イラスト検索
  Future<FetchResult<Illust>> searchIllust(
    String searchTarget,
    String word, {
    int offset = 0,
    int filter = 0,
  }) async {
    final params = {
      'search_target': searchTarget,
      'word': word,
      'filter': filter.toString(),
      'offset': offset.toString(),
    };
    final body = await _get('/v1/search/illust', params: params);
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final illustsJson = bodyData['illusts'] as List<dynamic>;
    final items = illustsJson
        .map((e) => Illust.fromJson(e as Map<String, dynamic>))
        .toList();
    return _wrap(items: items, rawBody: body);
  }

  /// 関連イラスト取得
  Future<List<Illust>> getIllustRelated(int illustId) async {
    final body = await _get(
      '/v2/illust/related',
      params: {'illust_id': illustId.toString()},
    );
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final illustsJson = bodyData['illusts'] as List<dynamic>;
    return illustsJson
        .map((e) => Illust.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// ランキング取得
  Future<FetchResult<Illust>> getRanking(String mode, {int offset = 0}) async {
    final params = {'mode': mode, 'offset': offset.toString()};
    final body = await _get('/v1/illust/ranking', params: params);
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final illustsJson = bodyData['illusts'] as List<dynamic>;
    final items = illustsJson
        .map((e) => Illust.fromJson(e as Map<String, dynamic>))
        .toList();
    return _wrap(items: items, rawBody: body);
  }

  /// 小説ランキング取得
  Future<FetchResult<Novel>> getNovelRanking(
    String mode, {
    int offset = 0,
  }) async {
    final params = {'mode': mode, 'offset': offset.toString()};
    final body = await _get('/v1/novel/ranking', params: params);
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final novelsJson = bodyData['novels'] as List<dynamic>;
    final items = novelsJson
        .map((e) => Novel.fromJson(e as Map<String, dynamic>))
        .toList();
    return _wrap(items: items, rawBody: body);
  }

  /// 小説おすすめ取得
  Future<FetchResult<Novel>> getNovelRecommend({int offset = 0}) async {
    final body = await _get(
      '/v1/novel/recommended',
      params: {'offset': offset.toString()},
    );
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final novelsJson = bodyData['novels'] as List<dynamic>;
    final items = novelsJson
        .map((e) => Novel.fromJson(e as Map<String, dynamic>))
        .toList();
    return _wrap(items: items, rawBody: body);
  }

  /// 小説検索
  Future<FetchResult<Novel>> searchNovel(
    String searchTarget,
    String word, {
    int offset = 0,
    int filter = 0,
  }) async {
    final params = {
      'search_target': searchTarget,
      'word': word,
      'filter': filter.toString(),
      'offset': offset.toString(),
    };
    final body = await _get('/v1/search/novel', params: params);
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final novelsJson = bodyData['novels'] as List<dynamic>;
    final items = novelsJson
        .map((e) => Novel.fromJson(e as Map<String, dynamic>))
        .toList();
    return _wrap(items: items, rawBody: body);
  }

  /// Pixiv の search_target は単一指定のため、「タグの部分一致」と「本文(text)」
  /// を同時に検索するためのラッパーメソッド
  Future<AllTextSearchResult<Novel>> searchNovelAllText(
    String word, {
    int offset = 0,
    int filter = 0,
  }) async {
    // タグ検索
    final tagResult = await searchNovel(
      'partial_match_for_tags',
      word,
      offset: offset,
      filter: filter,
    );
    final tagItems = tagResult.items;
    final tagNextOffset = tagResult.nextOffset ?? 0;

    // 本文検索
    final textResult = await searchNovel(
      'text',
      word,
      offset: offset,
      filter: filter,
    );
    final textItems = textResult.items;
    final textNextOffset = textResult.nextOffset ?? 0;

    return AllTextSearchResult<Novel>(
      tagItems: tagItems,
      textItems: textItems,
      tagNextOffset: tagNextOffset,
      textNextOffset: textNextOffset,
    );
  }

  /// 小説本文取得
  Future<NovelTextData> getNovelText(int novelId) async {
    final token = await getAccessToken(await getRefreshToken());
    final headers = {'Authorization': 'Bearer $token', ..._clientHeaders};

    final response = await http.get(
      Uri.parse('https://app-api.pixiv.net/v1/novel/pages?novel_id=$novelId'),
      headers: headers,
    );

    if (response.statusCode == 200) {
      final body = response.body;
      final regex = RegExp(
        r'<script id="data" type="application/json">(.*?)</script>',
      );
      final match = regex.firstMatch(body);

      if (match != null) {
        final jsonString = match.group(1);
        if (jsonString != null) {
          final json = jsonDecode(jsonString) as Map<String, dynamic>;
          final novelData = json['novel'] as Map<String, dynamic>;

          // novel_text が null の場合は空文字列で初期化
          final text = novelData['novel_text'] as String? ?? '';

          print(
            '📍 [DEBUG API] getNovelText 本文長: text.length = ${text.length}',
          );

          return NovelTextData(
            id: novelId,
            novelText: text,
            novelPages: [text],
          );
        }
      }
    } else {
      print('📍 [DEBUG API] getNovelText HTTPエラー: ${response.statusCode}');
    }

    throw Exception('小説本文の取得に失敗しました');
  }

  /// 小説シリーズ取得
  Future<List<Novel>> getNovelSeries(int seriesId, {int? lastOrder}) async {
    final params = <String, String>{
      'series_id': seriesId.toString(),
      'include_total_publication': 'true',
    };
    if (lastOrder != null) {
      params['last_order'] = lastOrder.toString();
    }
    final body = await _get('/v1/novel/series', params: params);
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final novelsJson = bodyData['novels'] as List<dynamic>;
    return novelsJson
        .map((e) => Novel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 小説シリーズ全巻取得
  Future<List<Novel>> getNovelSeriesAll(int seriesId) async {
    final novels = <Novel>[];
    int? lastOrder;

    while (true) {
      final batch = await getNovelSeries(seriesId, lastOrder: lastOrder);
      if (batch.isEmpty) break;
      novels.addAll(batch);
      lastOrder = batch.last.seriesOrder;
    }

    print(
      '📍 [DEBUG API] getNovelSeriesAll 完了: seriesId=$seriesId, count=${novels.length}',
    );
    return novels;
  }

  /// イラスト/マンガ/うごイラ単体取得（ディープリンク用）
  Future<Illust> getIllustById(int id) async {
    final body = await _get(
      '/v1/illust/detail',
      params: {'illust_id': id.toString()},
    );
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final illust = bodyData['illust'] as Map<String, dynamic>;

    return Illust.fromJson(illust);
  }

  /// 小説単体取得（ディープリンク用）
  Future<Novel> getNovelById(int id) async {
    final body = await _get(
      '/v1/novel/detail',
      params: {'novel_id': id.toString()},
    );
    final resData = jsonDecode(body) as Map<String, dynamic>;
    final bodyData = resData['body'] as Map<String, dynamic>;
    final novel = bodyData['novel'] as Map<String, dynamic>;

    return Novel.fromJson(novel);
  }

  /// ユーザー詳細取得
  Future<Map<String, dynamic>> getUserDetail(int userId) async {
    final data = await _get(
      '/v1/user/detail',
      params: {'user_id': userId.toString()},
    );
    return jsonDecode(data) as Map<String, dynamic>;
  }

  /// 特定ユーザーのイラスト作品取得
  Future<List<Illust>> getUserIllusts(int userId, {int offset = 0}) async {
    final body = await _get(
      '/v1/user/illusts',
      params: {'user_id': userId.toString(), 'offset': offset.toString()},
    );
    return filterIllustsIsolated(body, xRestrict: null);
  }

  /// 特定ユーザーの小説作品取得
  Future<List<Novel>> getUserNovels(int userId, {int offset = 0}) async {
    final body = await _get(
      '/v1/user/novels',
      params: {'user_id': userId.toString(), 'offset': offset.toString()},
    );
    return filterNovelsIsolated(body, xRestrict: null);
  }

  /// うごイラメタデータ取得
  Future<Map<String, dynamic>> getUgoiraMetadata(int illustId) async {
    final data = await _get(
      '/v1/ugoira/metadata',
      params: {'illust_id': illustId.toString()},
    );
    return jsonDecode(data) as Map<String, dynamic>;
  }

  // ==========================================
  // ブックマーク・ログイン管理
  // ==========================================

  /// ブックマーク追加/削除
  Future<bool> toggleBookmark(int id, bool isNovel, bool isAdd) async {
    try {
      if (isNovel) {
        if (isAdd) {
          await _post(
            '/v2/novel/bookmark/add',
            body: {'novel_id': id.toString(), 'restrict': 'public'},
          );
        } else {
          await _post(
            '/v2/novel/bookmark/delete',
            body: {'novel_id': id.toString()},
          );
        }
      } else {
        if (isAdd) {
          await _post(
            '/v1/bookmark/add',
            body: {
              'illust_id': id.toString(),
              'restrict': 'public',
              'tags[]': '',
            },
          );
        } else {
          await _post(
            '/v1/bookmark/delete',
            body: {'illust_id': id.toString()},
          );
        }
      }
      return true;
    } catch (e) {
      print('ブックマーク操作エラー: $e');
      return false;
    }
  }

  /// SharedPreferences にリフレッシュトークンを保存
  void setRefreshToken(String refreshToken) {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('PIXIV_REFRESH_TOKEN', refreshToken);
    });
  }

  /// リフレッシュトークンからアクセストークンを取得してログイン状態を確立
  Future<void> login() async {
    await getAccessToken(await getRefreshToken());
  }

  // ==========================================
  // 検索状態管理プロパティ
  // ==========================================

  /// 次ページの offset を [nextUrl] から安全に抽出する。
  /// next_url が存在しない場合は null を返し、呼び出し側でページングを終了させる。
  int? get nextOffset {
    // これは AllTextSearchResult の nextOffset プロパティから取得
    // 実際の実装は AllTextSearchResult クラス内で行う
    return null;
  }

  /// いずれかの検索に次ページがあるか
  bool get hasNext => nextOffset != null;
}

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

/// 全文検索の結果を保持するクラス
class AllTextSearchResult<T> {
  final List<T> tagItems;
  final List<T> textItems;
  final int tagNextOffset;
  final int textNextOffset;

  const AllTextSearchResult({
    required this.tagItems,
    required this.textItems,
    required this.tagNextOffset,
    required this.textNextOffset,
  });

  int? get nextOffset => tagNextOffset != 0
      ? tagNextOffset
      : (textNextOffset != 0 ? textNextOffset : null);
  bool get hasNext => nextOffset != null;
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
}
