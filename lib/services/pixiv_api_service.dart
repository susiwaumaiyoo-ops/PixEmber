import 'dart:convert';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'database_service.dart';
import '../illust_model.dart';
import '../novel_model.dart';

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
        "Accept-Language": "ja_JP",
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
  /// 注意: JSON デコードはメインスレッドで軽量に行い、重いリスト解析は
  /// 各メソッドが生 body 文字列を Isolate.run に渡して実行する。
  Future<String> _get(String endpoint, {Map<String, String>? params}) async {
    final token = await getAccessToken(await getRefreshToken());

    var uri = Uri.parse('$_baseUrl$endpoint');
    if (params != null) {
      uri = uri.replace(queryParameters: params);
    }

    print('[API] GET $uri');
    if (params != null && params.isNotEmpty) {
      print('[API] Params: $params');
    }

    final response = await http.get(
      uri,
      headers: {..._clientHeaders, 'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      print('[API] Status: 200, endpoint: $endpoint');
      return response.body;
    } else {
      print('[API] ERROR Status: ${response.statusCode}, endpoint: $endpoint');
      print('[API] ERROR Body: ${response.body}');
      throw Exception('Pixiv APIエラー: ${response.statusCode}\n${response.body}');
    }
  }

  // ==========================================
  // ミュート（ブラックリスト）動的フィルタリング
  // ==========================================

  /// ミュート設定をメインスレッド側（UI Isolate）で SQLite から取得し、
  /// Isolate に渡しやすい Set に正規化する。
  /// 注意: sqflite は別 Isolate から呼ぶと MethodChannel デッドロック（ANR）になるため、
  /// ここでの取得は必ずメインスレッド側で行う。
  Future<_MuteFilter> _loadMuteFilter() async {
    final mutes = await _dbService.getMutesList();

    final mutedTags = mutes
        .where((m) => m['mute_type'] == 'tag')
        .map((m) => m['value'].toString().toLowerCase())
        .toSet();
    final mutedUserIds = mutes
        .where((m) => m['mute_type'] == 'user')
        .map((m) => int.tryParse(m['value'].toString()))
        .whereType<int>()
        .toSet();

    // AI作品ミュート設定
    // '0': AI以外（AI作品をミュート）
    // '1': AI作品（AI以外をミュート）
    // '2': すべてをミュート
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

  /// イラストリストに対するミュートの動的適用（メインスレッド側・レガシー）
  Future<List<Illust>> filterIllusts(
    List<dynamic> illustsJsonList, {
    String? xRestrict,
    String? workType,
  }) async {
    final mutes = await _dbService.getMutesList();

    final mutedTags = mutes
        .where((m) => m['mute_type'] == 'tag')
        .map((m) => m['value'].toString().toLowerCase())
        .toSet();
    final mutedUserIds = mutes
        .where((m) => m['mute_type'] == 'user')
        .map((m) => int.tryParse(m['value'].toString()))
        .whereType<int>()
        .toSet();

    // AI作品ミュート設定
    // '0': AI以外（AI作品をミュート）
    // '1': AI作品（AI以外をミュート）
    // '2': すべてをミュート
    final aiMuteRecord = mutes.firstWhere(
      (m) => m['mute_type'] == 'ai',
      orElse: () => {},
    );
    final aiMuteValue = aiMuteRecord.isNotEmpty
        ? aiMuteRecord['value'].toString()
        : null;

    final List<Illust> filtered = [];

    for (var item in illustsJsonList) {
      try {
        final Map<String, dynamic> itemMap = item as Map<String, dynamic>;

        // 0. 年齢制限（x_restrict）フィルタリング
        final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
        if (xRestrict != null) {
          final String xLower = xRestrict.toLowerCase();
          if (xLower == 'safe' && xRestrictVal > 0) {
            continue; // safe（全年齢）が指定されている場合、R-18(1)/R-18G(2)を除外
          } else if (xLower == 'r18' && xRestrictVal == 0) {
            continue; // r18が指定されている場合、全年齢(0)を除外
          }
        }

        // 0.5 work_type（イラストの種類）フィルタ
        if (workType != null &&
            workType != 'all' &&
            workType != 'illust_manga_ugoira') {
          final String rawType = itemMap['type'] as String? ?? '';
          if (rawType != workType) {
            continue;
          }
        }

        // 1. ユーザーIDミュート
        final int userId = itemMap['user']?['id'] as int? ?? 0;
        if (mutedUserIds.contains(userId)) {
          continue;
        }

        // 2. タグミュート（部分一致・完全一致）
        final tagsObj = itemMap['tags'] as List<dynamic>? ?? [];
        bool hasMutedTag = false;
        for (var t in tagsObj) {
          final tMap = t as Map<String, dynamic>?;
          final tName = (tMap?['name'] as String? ?? '').toLowerCase();
          final tTranslated = (tMap?['translated_name'] as String? ?? '')
              .toLowerCase();

          if (mutedTags.any(
            (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
          )) {
            hasMutedTag = true;
            break;
          }
        }
        if (hasMutedTag) {
          continue;
        }

        // 3. AI作品ミュート
        // pixivのイラストデータ構造: item['illust_ai_type'] == 2 がAI作品
        final int aiType = itemMap['illust_ai_type'] as int? ?? 0;
        final bool isAiWork = aiType == 2;
        if (aiMuteValue != null) {
          if (aiMuteValue == '1' && isAiWork) {
            // AI作品をミュート
            continue;
          } else if (aiMuteValue == '0' && !isAiWork) {
            // AI以外をミュート
            continue;
          } else if (aiMuteValue == '2') {
            // すべてミュート
            continue;
          }
        }

        final illust = Illust.fromJson(itemMap);
        filtered.add(illust);
      } catch (e, stack) {
        // 個別パースエラーはスルー（デバッグログを出力）
        final idStr = (item is Map && item['id'] != null)
            ? item['id'].toString()
            : 'unknown';
        print('[API][PARSE ERROR] Illust id=$idStr, error=$e');
        print(stack);
      }
    }

    print(
      '[API] filterIllusts: input=${illustsJsonList.length}, output=${filtered.length}',
    );
    return filtered;
  }

  /// イラストのミュート適用＋モデル変換を Isolate で実行するためのエントリ。
  /// ミュート設定はメインスレッド側で事前取得（_loadMuteFilter）し、
  /// Isolate.run 内では DB アクセスを行わずメモリ上のフィルタのみ実行。
  /// Isolate.run は StandardMessageCodec を使うためカスタムクラスを
  /// 送受信できない（Isolate 内では Map のみ扱い、fromJson はメイン側で
  /// 1 回だけ行う）。これで fromJson→toJson→fromJson の重複シリアライズを排除。
  Future<List<Illust>> filterIllustsIsolated(
    String rawBody, {
    String? xRestrict,
    String? workType,
  }) async {
    final mute = await _loadMuteFilter();
    final List<Map<String, dynamic>> maps = await Isolate.run(
      () => _filterIllustsInIsolate(
        rawBody,
        mute.mutedTags,
        mute.mutedUserIds,
        mute.aiMuteValue,
        xRestrict,
        workType,
      ),
    );
    // --- メインスレッド側の fromJson を try-catch で保護 ---
    final List<Illust> result = [];
    for (final m in maps) {
      try {
        result.add(Illust.fromJson(m));
      } catch (e, stack) {
        final idStr = m['id']?.toString() ?? 'unknown';
        print('[API][PARSE ERROR] Illust.fromJson id=$idStr, error=$e');
        print(stack);
      }
    }
    return result;
  }

  /// 小説リストに対するミュートの動的適用
  Future<List<Novel>> filterNovels(
    List<dynamic> novelsJsonList, {
    String? xRestrict,
  }) async {
    final mutes = await _dbService.getMutesList();

    final mutedTags = mutes
        .where((m) => m['mute_type'] == 'tag')
        .map((m) => m['value'].toString().toLowerCase())
        .toSet();
    final mutedUserIds = mutes
        .where((m) => m['mute_type'] == 'user')
        .map((m) => int.tryParse(m['value'].toString()))
        .whereType<int>()
        .toSet();

    final aiMuteRecord = mutes.firstWhere(
      (m) => m['mute_type'] == 'ai',
      orElse: () => {},
    );
    final aiMuteValue = aiMuteRecord.isNotEmpty
        ? aiMuteRecord['value'].toString()
        : null;

    final List<Novel> filtered = [];

    for (var item in novelsJsonList) {
      try {
        final Map<String, dynamic> itemMap = item as Map<String, dynamic>;

        // 0. 年齢制限（x_restrict）フィルタリング
        final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
        if (xRestrict != null) {
          final String xLower = xRestrict.toLowerCase();
          if (xLower == 'safe' && xRestrictVal > 0) {
            continue; // safe（全年齢）が指定されている場合、R-18(1)/R-18G(2)を除外
          } else if (xLower == 'r18' && xRestrictVal == 0) {
            continue; // r18が指定されている場合、全年齢(0)を除外
          }
        }

        // 1. ユーザーIDミュート
        final int userId = itemMap['user']?['id'] as int? ?? 0;
        if (mutedUserIds.contains(userId)) {
          continue;
        }

        // 2. タグミュート
        final tagsObj = itemMap['tags'] as List<dynamic>? ?? [];
        bool hasMutedTag = false;
        for (var t in tagsObj) {
          final tMap = t as Map<String, dynamic>?;
          final tName = (tMap?['name'] as String? ?? '').toLowerCase();
          final tTranslated = (tMap?['translated_name'] as String? ?? '')
              .toLowerCase();

          if (mutedTags.any(
            (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
          )) {
            hasMutedTag = true;
            break;
          }
        }
        if (hasMutedTag) {
          continue;
        }

        // 3. AI作品ミュート
        // 小説の構造: novel_ai_type == 2 がAI作品
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
      } catch (e, stack) {
        // 個別パースエラーはスルー（デバッグログを出力）
        final idStr = (item is Map && item['id'] != null)
            ? item['id'].toString()
            : 'unknown';
        print('[API][PARSE ERROR] Novel id=$idStr, error=$e');
        print(stack);
      }
    }

    print(
      '[API] filterNovels: input=${novelsJsonList.length}, output=${filtered.length}',
    );
    return filtered;
  }

  /// 小説のミュート適用＋モデル変換を Isolate で実行するためのエントリ。
  /// ミュート設定はメインスレッド側で事前取得（_loadMuteFilter）し、
  /// Isolate.run 内では DB アクセスを行わずメモリ上のフィルタのみ実行。
  Future<List<Novel>> filterNovelsIsolated(
    String rawBody, {
    String? xRestrict,
  }) async {
    final mute = await _loadMuteFilter();
    final List<Map<String, dynamic>> maps = await Isolate.run(
      () => _filterNovelsInIsolate(
        rawBody,
        mute.mutedTags,
        mute.mutedUserIds,
        mute.aiMuteValue,
        xRestrict,
      ),
    );
    // --- メインスレッド側の fromJson を try-catch で保護 ---
    // 1件でもパース失敗すると全体がクラッシュするのを防ぎ、失敗1件をスキップ
    final List<Novel> result = [];
    for (final m in maps) {
      try {
        result.add(Novel.fromJson(m));
      } catch (e, stack) {
        final idStr = m['id']?.toString() ?? 'unknown';
        print('[API][PARSE ERROR] Novel.fromJson id=$idStr, error=$e');
        print(stack);
      }
    }
    return result;
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
    return FetchResult<T>(
      items: items,
      nextUrl: nextUrl,
      searchItem: searchItem,
    );
  }

  /// イラストおすすめ取得
  Future<FetchResult<Illust>> getRecommend({int offset = 0}) async {
    final body = await _get(
      '/v1/illust/recommended',
      params: {'content_type': 'illust', 'offset': offset.toString()},
    );
    final items = await filterIllustsIsolated(body);
    return _wrap(items: items, rawBody: body);
  }

  /// イラスト検索
  Future<FetchResult<Illust>> searchIllust(
    String word,
    String searchTarget,
    String sort,
    int offset,
    String xRestrict, {
    int bookmarkFilter = 0,
    String? workType,
  }) async {
    // main.py 互換: bookmark_filter / x_restrict の検索ワード書き換え
    var effectiveWord = word;
    if (bookmarkFilter > 0) {
      effectiveWord = '$effectiveWord ${bookmarkFilter}users入り';
    }
    if (xRestrict.toLowerCase() == 'r18') {
      effectiveWord = '$effectiveWord R-18';
    }
    print(
      '[API] searchIllust: word="$effectiveWord" (original: "$word"), '
      'xRestrict=$xRestrict, bookmarkFilter=$bookmarkFilter, workType=$workType',
    );

    final body = await _get(
      '/v1/search/illust',
      params: {
        'word': effectiveWord,
        'search_target':
            searchTarget, // 'partial_match_for_tags', 'exact_match_for_tags', 'title_and_caption'
        'sort': sort, // 'date_desc', 'date_asc', 'popular_desc'
        'offset': offset.toString(),
        'filter': 'for_android',
      },
    );
    final items = await filterIllustsIsolated(
      body,
      xRestrict: xRestrict,
      workType: workType,
    );
    final searchItem = _extractSearchItem(body);
    return _wrap(items: items, rawBody: body, searchItem: searchItem);
  }

  /// 関連イラスト取得
  Future<List<Illust>> getIllustRelated(int illustId) async {
    final body = await _get(
      '/v2/illust/related',
      params: {'illust_id': illustId.toString(), 'filter': 'for_android'},
    );
    return await filterIllustsIsolated(body);
  }

  /// イラストランキング取得
  Future<FetchResult<Illust>> getRanking(String mode, {int offset = 0}) async {
    // mode: 'day', 'week', 'month', 'day_male', 'day_female', 'week_original', 'week_rookie', 'day_manga'
    final body = await _get(
      '/v1/illust/ranking',
      params: {'mode': mode, 'offset': offset.toString()},
    );
    final items = await filterIllustsIsolated(body);
    return _wrap(items: items, rawBody: body);
  }

  /// 小説ランキング取得
  Future<FetchResult<Novel>> getNovelRanking(
    String mode, {
    int offset = 0,
  }) async {
    final body = await _get(
      '/v1/novel/ranking',
      params: {'mode': mode, 'offset': offset.toString()},
    );
    final items = await filterNovelsIsolated(body);
    return _wrap(items: items, rawBody: body);
  }

  /// 小説おすすめ取得
  Future<FetchResult<Novel>> getNovelRecommend({int offset = 0}) async {
    final body = await _get(
      '/v1/novel/recommended',
      params: {'offset': offset.toString()},
    );
    final items = await filterNovelsIsolated(body);
    return _wrap(items: items, rawBody: body);
  }

  /// 小説検索
  Future<FetchResult<Novel>> searchNovel(
    String word,
    String searchTarget,
    String sort,
    int offset,
    String xRestrict,
    int? minLength,
    int? maxLength, {
    int bookmarkFilter = 0,
  }) async {
    // main.py 互換: bookmark_filter / x_restrict の検索ワード書き換え
    var effectiveWord = word;
    if (bookmarkFilter > 0) {
      effectiveWord = '$effectiveWord ${bookmarkFilter}users入り';
    }
    if (xRestrict.toLowerCase() == 'r18') {
      effectiveWord = '$effectiveWord R-18';
    }
    print(
      '[API] searchNovel: word="$effectiveWord" (original: "$word"), '
      'xRestrict=$xRestrict, bookmarkFilter=$bookmarkFilter, '
      'minLength=$minLength, maxLength=$maxLength',
    );

    final params = {
      'word': effectiveWord,
      'search_target': searchTarget,
      'sort': sort,
      'offset': offset.toString(),
      'filter': 'for_android',
    };

    // 文字数制限
    if (minLength != null) params['start_text_length'] = minLength.toString();
    if (maxLength != null) params['end_text_length'] = maxLength.toString();

    final body = await _get('/v1/search/novel', params: params);
    final items = await filterNovelsIsolated(body, xRestrict: xRestrict);
    final searchItem = _extractSearchItem(body);
    return _wrap(items: items, rawBody: body, searchItem: searchItem);
  }

  /// 小説本文の取得（NovelTextDataモデルへの変換）
  ///
  /// Pixiv は /v1/novel/text を廃止したため、HTML を返す
  /// /webview/v2/novel を使用する。レスポンス本文から正規表現で
  /// 埋め込み JSON（novel オブジェクト）を抽出し、その中の 'text' キーから
  /// 本文を取得する。
  Future<NovelTextData> getNovelText(int novelId) async {
    print('📍 [DEBUG API] getNovelText リクエスト直前: novelId = $novelId');
    final token = await getAccessToken(await getRefreshToken());

    final uri = Uri.parse('$_baseUrl/webview/v2/novel').replace(
      queryParameters: {
        'id': novelId.toString(),
        'viewer_version': '20221031_ai',
      },
    );

    final response = await http.get(
      uri,
      headers: {..._clientHeaders, 'Authorization': 'Bearer $token'},
    );

    if (response.statusCode != 200) {
      print('📍 [DEBUG API] getNovelText HTTPエラー: ${response.statusCode}');
      throw Exception('Pixiv APIエラー: ${response.statusCode}');
    }

    final String body = response.body;
    print('📍 [DEBUG API] getNovelText 取得: body.length = ${body.length}');

    // 埋め込み JSON を抽出: window.preloadData = {...} 等の script 内から
    // `novel: {...}, isOwnWork` のパターンを探す。
    final regex = RegExp(
      r'novel:\s*(\{\{.*?\}|\{.*?\})\s*,\s*isOwnWork',
      dotAll: true,
    );
    final match = regex.firstMatch(body);
    if (match == null) {
      throw Exception('小説本文の解析に失敗しました（JSON抽出エラー）');
    }

    final String jsonStr = match.group(1)!;
    final Map<String, dynamic> novelJson =
        jsonDecode(jsonStr) as Map<String, dynamic>;

    final String text = novelJson['text'] as String? ?? '';
    print('📍 [DEBUG API] getNovelText 本文長: text.length = ${text.length}');

    // 改ページ [newpage] でページを分割
    final List<String> pages = text.split('[newpage]');
    final List<String> cleanedPages = pages.map((p) => p.trim()).toList();

    return NovelTextData(
      id: novelId,
      novelText: text,
      novelPages: cleanedPages,
    );
  }

  /// 小説シリーズのエピソード一覧取得
  Future<List<Novel>> getNovelSeries(int seriesId, {int? lastOrder}) async {
    print('📍 [DEBUG API] getNovelSeries リクエスト直前: seriesId = $seriesId');
    final params = {'series_id': seriesId.toString(), 'filter': 'for_android'};
    if (lastOrder != null) {
      params['last_order'] = lastOrder.toString();
    }

    final body = await _get('/v1/novel/series', params: params);
    print('📍 [DEBUG API] getNovelSeries デコード直前');
    return await filterNovelsIsolated(body);
  }

  /// ユーザー詳細取得
  Future<Map<String, dynamic>> getUserDetail(int userId) async {
    final data = await _get(
      '/v1/user/detail',
      params: {'user_id': userId.toString(), 'filter': 'for_android'},
    );
    final Map<String, dynamic> decoded =
        jsonDecode(data) as Map<String, dynamic>;
    // Pixiv の /v1/user/detail は { "user": {...}, "profile": {...} } 構造。
    // 画面側は name/avatar/comment/total_* をトップレベルから参照するため、
    // ここで user と profile をマージしたマップを返す。
    final user =
        (decoded['user'] as Map<String, dynamic>? ?? <String, dynamic>{})
            .cast<String, dynamic>();
    final profile =
        (decoded['profile'] as Map<String, dynamic>? ?? <String, dynamic>{})
            .cast<String, dynamic>();

    final Map<String, dynamic> merged = <String, dynamic>{};
    merged.addAll(user);
    merged.addAll(profile); // profile 側（total_* など）を優先

    // アバターURLは user.profile_image_urls.medium にあり、画面は 'avatar' キーで参照する
    final profileImageUrls =
        user['profile_image_urls'] as Map<String, dynamic>?;
    if (profileImageUrls != null) {
      merged['avatar'] =
          profileImageUrls['medium'] as String? ??
          profileImageUrls['large'] as String?;
    }
    return merged;
  }

  /// 特定ユーザーのイラスト作品取得
  Future<List<Illust>> getUserIllusts(
    int userId, {
    int offset = 0,
    String? workType,
  }) async {
    final body = await _get(
      '/v1/user/illusts',
      params: {
        'user_id': userId.toString(),
        'type': 'illust',
        'offset': offset.toString(),
      },
    );
    return await filterIllustsIsolated(body, workType: workType);
  }

  /// 特定ユーザーの小説作品取得
  Future<List<Novel>> getUserNovels(int userId, {int offset = 0}) async {
    final body = await _get(
      '/v1/user/novels',
      params: {'user_id': userId.toString(), 'offset': offset.toString()},
    );
    return await filterNovelsIsolated(body);
  }

  /// うごイラメタデータ取得
  Future<Map<String, dynamic>> getUgoiraMetadata(int illustId) async {
    final data = await _get(
      '/v1/ugoira/metadata',
      params: {'illust_id': illustId.toString()},
    );
    return jsonDecode(data) as Map<String, dynamic>;
  }

  /// 共通のPOSTリクエストメソッド
  Future<Map<String, dynamic>> _post(
    String endpoint, {
    Map<String, String>? body,
  }) async {
    final token = await getAccessToken(await getRefreshToken());

    final response = await http.post(
      Uri.parse('$_baseUrl$endpoint'),
      headers: {
        ..._clientHeaders,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body,
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('Pixiv APIエラー: ${response.statusCode}\n${response.body}');
    }
  }

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
            '/v1/novel/bookmark/delete',
            body: {'novel_id': id.toString()},
          );
        }
      } else {
        if (isAdd) {
          await _post(
            '/v2/illust/bookmark/add',
            body: {'illust_id': id.toString(), 'restrict': 'public'},
          );
        } else {
          await _post(
            '/v1/illust/bookmark/delete',
            body: {'illust_id': id.toString()},
          );
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// リフレッシュトークンを登録（永続化）
  void setRefreshToken(String refreshToken) {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('PIXIV_REFRESH_TOKEN', refreshToken);
    });
  }

  /// リフレッシュトークンからアクセストークンを取得してログイン状態を確立
  Future<void> login() async {
    await getAccessToken(await getRefreshToken());
  }
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

// ==========================================
// Isolate.run 用のトップレベル関数
// Isolate.run はカスタムクラス（Illust/Novel）を直接転送できるため、
// シリアライズ（toJson）は一切不要。Isolate 内では DB アクセスを行わず、
// メインスレッドから渡された _MuteFilter を使ってメモリ上のフィルタのみ実行する。
// ==========================================

/// ミュート設定の正規化済みリスト（メインスレッド側で構築し Isolate へ渡す）。
/// Isolate.run は StandardMessageCodec を使うため、カスタムクラスのインスタンスは
/// 送受信できない。そのためフィールドは List&lt;String&gt;/List&lt;int&gt;/String? など
/// シリアライズ可能なプリミティブのみに限定する。
class _MuteFilter {
  final List<String> mutedTags;
  final List<int> mutedUserIds;
  final String? aiMuteValue;

  _MuteFilter({
    required this.mutedTags,
    required this.mutedUserIds,
    required this.aiMuteValue,
  });
}

/// 生レスポンス body から search_item（百科事典カード）を抽出する。
SearchItem? _extractSearchItem(String rawBody) {
  try {
    final Map<String, dynamic> data =
        jsonDecode(rawBody) as Map<String, dynamic>;
    final item = data['search_item'];
    if (item != null) {
      return SearchItem.fromJson(item as Map<String, dynamic>);
    }
  } catch (_) {
    // 解析失敗は無視
  }
  return null;
}

/// Isolate 上でイラストの JSON デコード＋ミュート適用を行い、
/// シリアライズ可能な List<Map<String, dynamic>> を返す。
/// （Isolate を跨いでカスタムクラスは送受信できないため、fromJson は
///  メインスレッド側で 1 回だけ行う。toJson/fromJson の往復は一切なし。）
List<Map<String, dynamic>> _filterIllustsInIsolate(
  String rawBody,
  List<String> mutedTags,
  List<int> mutedUserIds,
  String? aiMuteValue,
  String? xRestrict,
  String? workType,
) {
  final Set<String> mutedTagSet = mutedTags.toSet();
  final Set<int> mutedUserIdSet = mutedUserIds.toSet();

  // --- Isolate 内での jsonDecode を try-catch で保護（ハングアップ対策） ---
  final List<dynamic> list;
  try {
    final Map<String, dynamic> decoded =
        jsonDecode(rawBody) as Map<String, dynamic>;
    list = decoded['illusts'] as List<dynamic>? ?? [];
  } catch (e, stack) {
    print('❌ [API][ISOLATE FATAL] _filterIllustsInIsolate: JSONデコード失敗: $e');
    print(stack);
    return <Map<String, dynamic>>[];
  }

  final List<Map<String, dynamic>> filtered = [];

  for (var item in list) {
    try {
      final Map<String, dynamic> itemMap = item as Map<String, dynamic>;

      final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
      if (xRestrict != null) {
        final String xLower = xRestrict.toLowerCase();
        if (xLower == 'safe' && xRestrictVal > 0) {
          continue;
        } else if (xLower == 'r18' && xRestrictVal == 0) {
          continue;
        }
      }

      if (workType != null &&
          workType != 'all' &&
          workType != 'illust_manga_ugoira') {
        final String rawType = itemMap['type'] as String? ?? '';
        if (rawType != workType) {
          continue;
        }
      }

      final int userId = itemMap['user']?['id'] as int? ?? 0;
      if (mutedUserIdSet.contains(userId)) {
        continue;
      }

      final tagsObj = itemMap['tags'] as List<dynamic>? ?? [];
      bool hasMutedTag = false;
      for (var t in tagsObj) {
        final tMap = t as Map<String, dynamic>?;
        final tName = (tMap?['name'] as String? ?? '').toLowerCase();
        final tTranslated = (tMap?['translated_name'] as String? ?? '')
            .toLowerCase();
        if (mutedTagSet.any(
          (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
        )) {
          hasMutedTag = true;
          break;
        }
      }
      if (hasMutedTag) continue;

      final int aiType = itemMap['illust_ai_type'] as int? ?? 0;
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

      filtered.add(itemMap);
    } catch (e, stack) {
      final idStr = (item is Map && item['id'] != null)
          ? item['id'].toString()
          : 'unknown';
      print('[API][PARSE ERROR] Illust id=$idStr, error=$e');
      print(stack);
    }
  }

  print(
    '[API] filterIllusts(Isolate): input=${list.length}, output=${filtered.length}',
  );
  return filtered;
}

/// Isolate 上で小説の JSON デコード＋ミュート適用を行い、
/// シリアライズ可能な List<Map<String, dynamic>> を返す。
List<Map<String, dynamic>> _filterNovelsInIsolate(
  String rawBody,
  List<String> mutedTags,
  List<int> mutedUserIds,
  String? aiMuteValue,
  String? xRestrict,
) {
  final Set<String> mutedTagSet = mutedTags.toSet();
  final Set<int> mutedUserIdSet = mutedUserIds.toSet();

  // --- Isolate 内での jsonDecode を try-catch で保護（ハングアップ対策） ---
  // レスポンスJSONの構造が予期しない形式だった場合、Isolate 内で未捕捉例外が
  // 発生するとフリーズする。必ずキャッチして安全に空リストへフォールバックする。
  final List<dynamic> list;
  try {
    final Map<String, dynamic> decoded =
        jsonDecode(rawBody) as Map<String, dynamic>;
    // 必ず小説用の正しいキー名 'novels' からリストを取得
    list = decoded['novels'] as List<dynamic>? ?? [];
  } catch (e, stack) {
    print('❌ [API][ISOLATE FATAL] _filterNovelsInIsolate: JSONデコード失敗: $e');
    print(stack);
    return <Map<String, dynamic>>[];
  }

  final List<Map<String, dynamic>> filtered = [];

  for (var item in list) {
    try {
      final Map<String, dynamic> itemMap = item as Map<String, dynamic>;

      final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
      if (xRestrict != null) {
        final String xLower = xRestrict.toLowerCase();
        if (xLower == 'safe' && xRestrictVal > 0) {
          continue;
        } else if (xLower == 'r18' && xRestrictVal == 0) {
          continue;
        }
      }

      final int userId = itemMap['user']?['id'] as int? ?? 0;
      if (mutedUserIdSet.contains(userId)) {
        continue;
      }

      final tagsObj = itemMap['tags'] as List<dynamic>? ?? [];
      bool hasMutedTag = false;
      for (var t in tagsObj) {
        final tMap = t as Map<String, dynamic>?;
        final tName = (tMap?['name'] as String? ?? '').toLowerCase();
        final tTranslated = (tMap?['translated_name'] as String? ?? '')
            .toLowerCase();
        if (mutedTagSet.any(
          (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
        )) {
          hasMutedTag = true;
          break;
        }
      }
      if (hasMutedTag) continue;

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

      filtered.add(itemMap);
    } catch (e, stack) {
      // 個別小説のパース失敗は1件スキップし、残りの健全な小説を表示
      final idStr = (item is Map && item['id'] != null)
          ? item['id'].toString()
          : 'unknown';
      print('[API][PARSE ERROR] Novel id=$idStr, error=$e');
      print(stack);
    }
  }

  print(
    '[API] filterNovels(Isolate): input=${list.length}, output=${filtered.length}',
  );
  return filtered;
}
