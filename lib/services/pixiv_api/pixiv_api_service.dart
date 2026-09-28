import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database_service.dart';
import '../pixiv_api_http.dart';
import '../../illust_model.dart';
import '../../models/search_filter.dart';
import '../../models/trending_tag.dart';
import '../../models/user_model.dart';
import '../../novel_model.dart';

// 分割予定（Phase 9〜11）:
//   part 'pixiv_api_auth.part.dart';        // OAuth（PixivHttpClient へ委譲）
//   part 'pixiv_api_filter.part.dart';      // ミュートフィルタ + Isolate 関数
//   part 'pixiv_api_search_utils.part.dart';// 純粋 static 関数
//   part 'pixiv_api_endpoints.part.dart';   // API エンドポイント群

/// 429 Rate Limit エラー用のカスタム例外クラス
class RateLimitException implements Exception {
  final String message;
  final int statusCode;

  RateLimitException(this.message, {this.statusCode = 429});

  @override
  String toString() => 'RateLimitException: $message (Status: $statusCode)';
}

/// 401 認証エラー（トークン切れ等）。リフレッシュ再試行または再ログイン誘導に使う。
class AuthException implements Exception {
  final String message;
  final int statusCode;

  AuthException(this.message, {this.statusCode = 401});

  @override
  String toString() => 'AuthException: $message (Status: $statusCode)';
}

/// 小説が存在しない / 削除済み / 非公開 等（404相当）。安全にスキップするために使う。
class NovelNotFoundException implements Exception {
  final int novelId;

  NovelNotFoundException(this.novelId);

  @override
  String toString() => 'NovelNotFoundException: id=$novelId';
}

class PixivApiService {
  static final PixivApiService _instance = PixivApiService._internal();

  /// 19A-1: AI作品ミュートの判定を1箇所に集約する。
  ///
  /// 戻り値は「その作品を残すか」。
  /// - `aiMuteValue == '1'`: AI作品を非表示にする（非AIのみ残す）
  /// - `aiMuteValue == '2'`: **AI作品のみにする（逆フィルタ）**。
  ///   旧実装はここで全件を `continue` して全作品を非表示にするバグだった。
  /// - `null` / `'0'` / その他: 除外しない（すべて残す）。
  ///
  /// `'2'` のとき非AIを除外する（AIのみ残す）のが mute_settings_screen の
  /// ラベル「AI作品のみにする (逆フィルタ)」と一致する挙動。
  @visibleForTesting
  static bool shouldKeepAiWork(String? aiMuteValue, bool isAiWork) {
    if (aiMuteValue == '1') return !isAiWork;
    if (aiMuteValue == '2') return isAiWork;
    return true;
  }

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
    'Accept-Encoding': 'gzip',
  };

  final DatabaseService _dbService = DatabaseService();

  /// 認証アクセストークンの取得（必要に応じて自動リフレッシュ）
  ///
  /// Phase 9a: 実体は [PixivHttpClient.getAccessToken] が持つ（委譲）。
  /// トークンキャッシュ・有効期限管理も HttpClient 側に一本化され、
  /// 本クラスは互換用の薄い転送のみ残す。
  Future<String> getAccessToken(String refreshToken) =>
      PixivHttpClient().getAccessToken(refreshToken);

  /// SharedPreferences からリフレッシュトークンを取得（未設定なら例外）
  ///
  /// Phase 9a: 実体は [PixivHttpClient.getRefreshToken] が持つ（委譲）。
  Future<String> getRefreshToken() => PixivHttpClient().getRefreshToken();

  /// 共通のGETリクエストメソッド
  /// 注意: JSON デコードはメインスレッドで軽量に行い、重いリスト解析は
  /// 各メソッドが生 body 文字列を Isolate.run に渡して実行する。
  ///
  /// Phase 9c-1: 実体は [PixivHttpClient.get] に委譲する（URL・ヘッダーは
  /// HttpClient 側の baseUrl/clientHeaders と同一値）。
  /// 401 時のキャッシュ破棄（B-6）は HttpClient.get が行う。
  /// 戻り値は従来どおり body 文字列。外向きの例外契約は境界変換で維持:
  ///   PixivRateLimitException → RateLimitException
  ///   PixivAuthException     → AuthException
  ///   上記以外              → 従来の生 Exception（403/404 を含む）
  Future<String> _get(String endpoint, {Map<String, String>? params}) async {
    try {
      final body = await PixivHttpClient().get(endpoint, params: params);
      debugPrint('[API] Status: 200, endpoint: $endpoint');
      return body;
    } on PixivRateLimitException catch (e) {
      debugPrint('[API] ERROR Status: 429 (Rate Limited), endpoint: $endpoint');
      throw RateLimitException(e.message, statusCode: e.statusCode);
    } on PixivAuthException catch (e) {
      debugPrint('[API] ERROR Status: 401 (Unauthorized), endpoint: $endpoint');
      throw AuthException(
        'Pixiv APIの認証に失敗しました（401）。再ログインが必要です。',
        statusCode: e.statusCode,
      );
    } on PixivForbiddenException catch (e) {
      // 従来 _get は 403 を生 Exception にしていたのでその表現を維持する。
      debugPrint('[API] ERROR Status: ${e.statusCode}, endpoint: $endpoint');
      throw Exception('Pixiv APIエラー: ${e.statusCode}\n${e.message}');
    } on PixivNotFoundException catch (e) {
      // 従来 _get は 404 を生 Exception にしていた。NovelNotFoundException は
      // getNovelById 等の data==null 判定で作る既存ロジックのまま（ここでは作らない）。
      debugPrint('[API] ERROR Status: ${e.statusCode}, endpoint: $endpoint');
      throw Exception('Pixiv APIエラー: ${e.statusCode}\n${e.message}');
    }
  }

  /// テスト用: `_get` の境界例外変換を直接観測する（Phase 9c-1）。
  ///
  /// 通常のエンドポイントは `_wrap` が例外を握りつぶして空結果を返すため、
  /// 変換後の例外型を検証できない。本 getter は `_get` そのものを呼び、
  /// 例外をそのまま外に伝える。公開 API ではない。
  @visibleForTesting
  Future<String> testGet(String endpoint, {Map<String, String>? params}) =>
      _get(endpoint, params: params);

  /// テスト用: `_post` の境界例外変換を直接観測する（Phase 9c-2）。
  ///
  /// toggleBookmark は catch-all で例外を握りつぶすため、変換後の例外型を
  /// 検証できない。本メソッドは `_post` そのものを呼び、例外をそのまま
  /// 外に伝える。公開 API ではない。
  @visibleForTesting
  Future<Map<String, dynamic>> testPost(
    String endpoint, {
    Map<String, String>? body,
  }) => _post(endpoint, body: body);

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

    // AI作品ミュート設定（19A-1: 判定は shouldKeepAiWork を参照）
    // '0': 除外しない（すべて表示）
    // '1': AI作品を非表示にする
    // '2': AI作品のみにする（逆フィルタ）
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

    // AI作品ミュート設定（19A-1: 判定は shouldKeepAiWork を参照）
    // '0': 除外しない（すべて表示）
    // '1': AI作品を非表示にする
    // '2': AI作品のみにする（逆フィルタ）
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

        // 0. 年齢制限（x_restrict）フィルタリング（レスポンスの x_restrict フィールドで判定）
        // all=全年齢のみ(0), include_r18=R-18含む(0,1,2), r18=R-18のみ(1), r18g=R-18G含む(0,1,2)
        final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
        final String xLower = (xRestrict ?? '').toLowerCase();
        if (xLower == 'all' && xRestrictVal != 0) {
          continue; // 全年齢のみ：R-18(1)/R-18G(2)を除外
        } else if (xLower == 'r18' && xRestrictVal != 1) {
          continue; // R-18のみ：全年齢(0)・R-18G(2)を除外
        } else if (xLower == 'r18g' && xRestrictVal != 2) {
          continue; // R-18Gのみ：全年齢(0)・R-18(1)を除外
        }
        // include_r18 / その他はすべて表示

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

        // 3. AI作品ミュート（illust_ai_type == 2 がAI作品）
        // 19A-1: 判定は shouldKeepAiWork に集約（'2'=AIのみ残す）。
        final int aiType = itemMap['illust_ai_type'] as int? ?? 0;
        if (!PixivApiService.shouldKeepAiWork(aiMuteValue, aiType == 2)) {
          continue;
        }

        final illust = Illust.fromJson(itemMap);
        filtered.add(illust);
      } catch (e, stack) {
        // 個別パースエラーはスルー（デバッグログを出力）
        final idStr = (item is Map && item['id'] != null)
            ? item['id'].toString()
            : 'unknown';
        debugPrint('[API][PARSE ERROR] Illust id=$idStr, error=$e');
        debugPrint(stack.toString());
      }
    }

    debugPrint(
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
        debugPrint('[API][PARSE ERROR] Illust.fromJson id=$idStr, error=$e');
        debugPrint(stack.toString());
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

        // 0. 年齢制限（x_restrict）フィルタリング（レスポンスの x_restrict フィールドで判定）
        // all=全年齢のみ(0), include_r18=R-18含む(0,1,2), r18=R-18のみ(1), r18g=R-18G含む(0,1,2)
        final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
        final String xLower = (xRestrict ?? '').toLowerCase();
        if (xLower == 'all' && xRestrictVal != 0) {
          continue; // 全年齢のみ：R-18(1)/R-18G(2)を除外
        } else if (xLower == 'r18' && xRestrictVal != 1) {
          continue; // R-18のみ：全年齢(0)・R-18G(2)を除外
        } else if (xLower == 'r18g' && xRestrictVal != 2) {
          continue; // R-18Gのみ：全年齢(0)・R-18(1)を除外
        }
        // include_r18 / その他はすべて表示

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

        // 3. AI作品ミュート（novel_ai_type == 2 がAI作品）
        // 19A-1: 判定は shouldKeepAiWork に集約（'2'=AIのみ残す）。
        final int aiType = itemMap['novel_ai_type'] as int? ?? 0;
        if (!PixivApiService.shouldKeepAiWork(aiMuteValue, aiType == 2)) {
          continue;
        }

        final novel = Novel.fromJson(itemMap);
        filtered.add(novel);
      } catch (e, stack) {
        // 個別パースエラーはスルー（デバッグログを出力）
        final idStr = (item is Map && item['id'] != null)
            ? item['id'].toString()
            : 'unknown';
        debugPrint('[API][PARSE ERROR] Novel id=$idStr, error=$e');
        debugPrint(stack.toString());
      }
    }

    debugPrint(
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
        debugPrint('[API][PARSE ERROR] Novel.fromJson id=$idStr, error=$e');
        debugPrint(stack.toString());
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

  /// 検索リクエストパラメータを組み立てる（純粋関数・単体テスト用）。
  ///
  /// searchIllust / searchNovel が共通するパラメータ構築ロジックを
  /// 抽出したもので、単体テストで「URLパラメータに含まれるか」を検証できる。
  static Map<String, String> buildSearchParams({
    required String word,
    required String searchTarget,
    required bool isNovel,
    required String sort,
    required int offset,
    int bookmarkFilter = 0,
    String xRestrict = 'all',
    String? duration,
    DateTime? startDate,
    DateTime? endDate,
    int? bookmarkNumMin,
    int? bookmarkNumMax,
    int? startTextLength,
    int? endTextLength,
  }) {
    // 検索ワードの正規化（前後空白の除去、全角スペース・連続空白・改行・
    // タブを単一の半角スペースに統一）。スペース区切り検索（例: 「猫 イラスト」）
    // がどの入力形でも正しくキーワード分割されるようにする。
    var effectiveWord = normalizeSearchQuery(word);
    // main.py 互換: bookmark_filter の検索ワード書き換え
    if (bookmarkFilter > 0) {
      effectiveWord = '$effectiveWord ${bookmarkFilter}users入り';
    }
    // 年齢制限（x_restrict）は原則ワードに含めず、API 結果を x_restrict
    // フィールドで絞り込む。例外的にタグ検索のみ R-18 を補助ワードとして
    // 付与する（全文検索で付与すると「R-18」という文字列を本文に含む
    // 作品が誤ってヒットするため）。
    final target = normalizeSearchTarget(searchTarget, isNovel: isNovel);
    effectiveWord = buildSearchWord(
      rawQuery: effectiveWord,
      ageLimit: xRestrict,
      searchTarget: target,
    );
    debugPrint(
      '[API] buildSearchParams: word="$effectiveWord" (raw="$word", '
      'ageLimit=$xRestrict, target=$target)',
    );
    final params = <String, String>{
      'word': effectiveWord,
      'search_target': target,
      'sort': sort,
      'offset': offset.toString(),
      'filter': 'for_android',
      // 複数キーワード（スペース区切り）検索で複数タグにまたがる結果を
      // マージして返すためのフラグ。削除前の pixiv_api_search.dart も
      // merge_results=true を送信していたため同等に復元する。
      'merge_results': 'true',
    };
    // 小説の文字数制限
    if (startTextLength != null) {
      params['start_text_length'] = startTextLength.toString();
    }
    if (endTextLength != null) {
      params['end_text_length'] = endTextLength.toString();
    }
    // 日付範囲が指定されていれば duration より優先して送信する。
    // pixiv App-API は start_date/end_date を `yyyy-MM-dd` 文字列で要求する
    // （Unix 秒は受け付けないため、必ず formatDateForPixivApi で変換）。
    if (SearchFilter.hasDateRange(startDate, endDate)) {
      final start = SearchFilter.formatDateForPixivApi(startDate);
      final end = SearchFilter.formatDateForPixivApi(endDate);
      if (start != null) params['start_date'] = start;
      if (end != null) params['end_date'] = end;
    } else {
      final apiDuration = SearchFilter.durationToApiValue(duration);
      if (apiDuration != null) params['duration'] = apiDuration;
    }
    if (bookmarkNumMin != null && bookmarkNumMin > 0) {
      params['bookmark_num_min'] = bookmarkNumMin.toString();
    }
    if (bookmarkNumMax != null && bookmarkNumMax > 0) {
      params['bookmark_num_max'] = bookmarkNumMax.toString();
    }
    return params;
  }

  /// pixiv App-API が受け付ける search_target の有効値。
  static const Set<String> illustSearchTargets = {
    'partial_match_for_tags',
    'exact_match_for_tags',
    'title_and_caption',
  };
  static const Set<String> novelSearchTargets = {
    'partial_match_for_tags',
    'exact_match_for_tags',
    'title_and_caption',
    'text',
    'keyword',
  };

  /// 無効な search_target（旧UIの 'title'/'description'/'tags'/'all_text' 等）が
  /// 渡された場合に API エラーを起こさないよう既定値へ丸める。
  static String normalizeSearchTarget(String target, {required bool isNovel}) {
    final valid = isNovel ? novelSearchTargets : illustSearchTargets;
    if (valid.contains(target)) return target;
    return 'partial_match_for_tags';
  }

  /// R-18 / R18 / R-18G / R18G トークン検出用パターン。
  ///
  /// タグ名や本文の一部（例: 「R-18作品まとめ」のタグ文字列の一部）を
  /// 誤検出しないよう、トークンの前後が空白または文字列境界である場合のみ
  /// 一致させる。
  static final RegExp _r18TokenPattern = RegExp(
    r'(^|\s)(r-?18g?)(\s|$)',
    caseSensitive: false,
  );

  /// 検索クエリを正規化する（純粋関数・単体テスト用）。
  ///
  /// - 前後の空白を除去（trim）
  /// - 全角スペース（U+3000）・改行・タブを含む連続する空白文字列を
  ///   単一の半角スペースに圧縮
  ///
  /// 「猫　イラスト」や「猫  イラスト」も「猫 イラスト」として
  /// pixiv API へ送信され、AND 検索として正しく処理される。
  static String normalizeSearchQuery(String query) {
    return query.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// [normalizeSearchQuery] の別名（既存呼び出し互換用）。
  static String normalizeSearchWord(String word) {
    return normalizeSearchQuery(word);
  }

  /// クエリに R-18 / R-18G トークンが既に含まれるか
  /// （純粋関数・単体テスト用）。
  ///
  /// ワードへの R-18 二重付与を防ぐために使用する。
  static bool containsR18Token(String query) {
    return _r18TokenPattern.hasMatch(query);
  }

  /// 検索ワードと年齢制限から API へ送信するワードを組み立てる
  /// （純粋関数・単体テスト用）。
  ///
  /// ルール:
  /// - ワードは [normalizeSearchQuery] でのみ正規化する。年齢制限は
  ///   原則ワードに含めない（pixiv App API に x_restrict 検索パラメータは
  ///   存在せず、絞り込みは API 結果の x_restrict フィールドで行う）。
  /// - 例外としてタグ検索（partial_match_for_tags / exact_match_for_tags）
  ///   の場合のみ R-18 を補助ワードとして付与する。全文検索
  ///   （text / title_and_caption / keyword）で付与すると、本文に
  ///   「R-18」という文字列を含む作品が誤ってヒットするため。
  /// - クエリに既に R-18 トークンが含まれる場合は二重付与しない。
  /// - 'include_r18'（R-18を含む）や全年齢指定では付与しない。
  static String buildSearchWord({
    required String rawQuery,
    required String ageLimit,
    required String searchTarget,
  }) {
    final base = normalizeSearchQuery(rawQuery);
    final isTagSearch =
        searchTarget == 'partial_match_for_tags' ||
        searchTarget == 'exact_match_for_tags';
    final wantsR18 = ageLimit.toLowerCase() == 'r18';
    if (wantsR18 && isTagSearch && !containsR18Token(base)) {
      return '$base R-18';
    }
    return base;
  }

  /// 年齢制限（ageLimit）に応じて x_restrict フィールドでリストを絞り込む
  /// （純粋関数・単体テスト用）。
  ///
  /// x_restrict の値: 0=全年齢, 1=R-18, 2=R-18G
  ///
  /// ポリシー（アプリUIのラベルと整合させる。既存のクライアント側フィルタ
  /// と同一の挙動を維持）:
  /// - 'all' / 'all_ages' / 'safe': 全年齢のみ → x_restrict == 0 のみ表示
  /// - 'include_r18' / その他未知の値: R-18 を含む → すべて表示
  /// - 'r18': R-18のみ → x_restrict == 1 のみ表示（R-18G(2) は含めない。
  ///   UIラベル「R-18のみ」に R-18G が混ざると不自然なため既存挙動を維持）
  /// - 'r18g': R-18Gのみ → x_restrict == 2 のみ表示
  static List<T> applyAgeLimitFilter<T>(
    List<T> items,
    String ageLimit,
    int Function(T) xRestrictOf,
  ) {
    final x = ageLimit.toLowerCase();
    if (x == 'all' || x == 'all_ages' || x == 'safe') {
      return items.where((item) => xRestrictOf(item) == 0).toList();
    }
    if (x == 'r18') {
      return items.where((item) => xRestrictOf(item) == 1).toList();
    }
    if (x == 'r18g') {
      return items.where((item) => xRestrictOf(item) == 2).toList();
    }
    // include_r18 とその他の値は絞り込まずすべて表示
    return List<T>.of(items);
  }

  /// 2つの検索結果リストを ID で統合しつつ重複除去する（純粋関数・単体テスト用）。
  ///
  /// [primary]（タグ検索結果）をベースに、[secondary]（本文検索結果）のうち
  /// 未含のものを末尾へ追加する。順序は primary → secondary の追加順を維持。
  /// [keyOf] は重複判定に使うキー（通常は作品 ID）を取り出す関数。
  /// 全文検索で片方の並行検索が失敗した場合も、成功側のリストをそのまま
  /// 渡すことで結果を守れる。
  static List<T> mergeById<T>(
    List<T> primary,
    List<T> secondary,
    Object Function(T) keyOf,
  ) {
    final Map<Object, T> merged = {};
    for (final item in primary) {
      merged[keyOf(item)] = item;
    }
    for (final item in secondary) {
      merged.putIfAbsent(keyOf(item), () => item);
    }
    return merged.values.toList();
  }

  /// イラスト検索
  ///
  /// 新規プレミアム相当パラメータ（すべて optional。null で既存動作を維持）:
  /// - [duration]: within_last_day / within_last_week / within_last_month /
  ///   within_last_halfyear / within_last_year
  /// - [startDate]/[endDate]: 日付範囲（ローカル日付で指定。API 送信時に
  ///   `yyyy-MM-dd` 文字列へ変換される）。指定時は [duration] より優先され、
  ///   duration は送信しない。
  /// - [bookmarkNumMin]/[bookmarkNumMax]: ブックマーク数範囲
  Future<FetchResult<Illust>> searchIllust(
    String word,
    String searchTarget,
    String sort,
    int offset,
    String xRestrict, {
    int bookmarkFilter = 0,
    String? workType,
    String? duration,
    DateTime? startDate,
    DateTime? endDate,
    int? bookmarkNumMin,
    int? bookmarkNumMax,
  }) async {
    // NOTE: /v1/search/illust に x_restrict 検索パラメータは存在しない。
    // R-18 が結果に出るかはアカウントの年齢確認・表示設定に依存する。
    // 作品単位の R-18 判定はレスポンスの x_restrict フィールドで
    // クライアント側フィルタ（filterIllustsIsolated）が行う。
    final params = buildSearchParams(
      word: word,
      searchTarget: searchTarget,
      isNovel: false,
      sort: sort,
      offset: offset,
      bookmarkFilter: bookmarkFilter,
      xRestrict: xRestrict,
      duration: duration,
      startDate: startDate,
      endDate: endDate,
      bookmarkNumMin: bookmarkNumMin,
      bookmarkNumMax: bookmarkNumMax,
    );
    debugPrint(
      '[API] searchIllust: word="$word", xRestrict=$xRestrict, '
      'bookmarkFilter=$bookmarkFilter, workType=$workType, '
      'duration=$duration, startDate=$startDate, endDate=$endDate, '
      'bookmarkNumMin=$bookmarkNumMin, bookmarkNumMax=$bookmarkNumMax',
    );

    final body = await _get('/v1/search/illust', params: params);
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
    int? startTextLength,
    int? endTextLength,
  }) async {
    try {
      final params = {'mode': mode, 'offset': offset.toString()};
      if (startTextLength != null) {
        params['start_text_length'] = startTextLength.toString();
      }
      if (endTextLength != null) {
        params['end_text_length'] = endTextLength.toString();
      }
      final body = await _get('/v1/novel/ranking', params: params);
      final items = await filterNovelsIsolated(body);
      return _wrap(items: items, rawBody: body);
    } catch (e, stack) {
      // 存在しない mode 等で API エラーが発生してもクラッシュさせず空結果を返す。
      // Phase 10c: ただし空リストを「成功」と偽装しないため hasError を立てる。
      debugPrint('[API] getNovelRanking failed: mode=$mode, error=$e');
      debugPrint(stack.toString());
      return const FetchResult<Novel>(items: [], hasError: true);
    }
  }

  /// 小説おすすめ取得
  Future<FetchResult<Novel>> getNovelRecommend({
    int offset = 0,
    int? startTextLength,
    int? endTextLength,
  }) async {
    final params = {'offset': offset.toString()};
    if (startTextLength != null) {
      params['start_text_length'] = startTextLength.toString();
    }
    if (endTextLength != null) {
      params['end_text_length'] = endTextLength.toString();
    }
    final body = await _get('/v1/novel/recommended', params: params);
    final items = await filterNovelsIsolated(body);
    return _wrap(items: items, rawBody: body);
  }

  /// 小説検索
  ///
  /// 新規プレミアム相当パラメータ（すべて optional。null で既存動作を維持）:
  /// - [duration]: within_last_day / within_last_week / within_last_month /
  ///   within_last_halfyear / within_last_year
  /// - [startDate]/[endDate]: 日付範囲（ローカル日付で指定。API 送信時に
  ///   `yyyy-MM-dd` 文字列へ変換される）。指定時は [duration] より優先され、
  ///   duration は送信しない。
  /// - [bookmarkNumMin]/[bookmarkNumMax]: ブックマーク数範囲
  Future<FetchResult<Novel>> searchNovel(
    String word,
    String searchTarget,
    String sort,
    int offset,
    String xRestrict,
    int? minLength,
    int? maxLength, {
    int bookmarkFilter = 0,
    String? duration,
    DateTime? startDate,
    DateTime? endDate,
    int? bookmarkNumMin,
    int? bookmarkNumMax,
  }) async {
    // NOTE: /v1/search/novel に x_restrict 検索パラメータは存在しない。
    // R-18 が結果に出るかはアカウントの年齢確認・表示設定に依存する。
    // 作品単位の R-18 判定はレスポンスの x_restrict フィールドで
    // クライアント側フィルタ（filterNovelsIsolated）が行う。
    final params = buildSearchParams(
      word: word,
      searchTarget: searchTarget,
      isNovel: true,
      sort: sort,
      offset: offset,
      bookmarkFilter: bookmarkFilter,
      xRestrict: xRestrict,
      duration: duration,
      startDate: startDate,
      endDate: endDate,
      bookmarkNumMin: bookmarkNumMin,
      bookmarkNumMax: bookmarkNumMax,
      startTextLength: minLength,
      endTextLength: maxLength,
    );
    debugPrint(
      '[API] searchNovel: word="$word", '
      'xRestrict=$xRestrict, bookmarkFilter=$bookmarkFilter, '
      'minLength=$minLength, maxLength=$maxLength, '
      'duration=$duration, startDate=$startDate, endDate=$endDate, '
      'bookmarkNumMin=$bookmarkNumMin, bookmarkNumMax=$bookmarkNumMax',
    );

    final body = await _get('/v1/search/novel', params: params);
    final items = await filterNovelsIsolated(body, xRestrict: xRestrict);
    final searchItem = _extractSearchItem(body);
    return _wrap(items: items, rawBody: body, searchItem: searchItem);
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
    String word,
    String sort,
    String xRestrict,
    int? minLength,
    int? maxLength, {
    int bookmarkFilter = 0,
    AllTextSearchState? state,
  }) async {
    // 初回呼び出し時は空の状態から開始
    state ??= AllTextSearchState.empty;

    // タグ検索と本文検索をそれぞれの offset で並行実行。
    // Future.wait は片方が例外を投げると全体が失敗して成功側の結果も
    // 破棄されるため、各検索を個別に捕捉して失敗を状態に記録する。
    // 片方が失敗（レート制限・ネットワークエラー等）しても、
    // 成功したもう片方の結果は必ず返す。
    Object? tagError;
    Object? textError;

    // 年齢制限（x_restrict）の R-18 補助ワードはタグ検索側にのみ付与する。
    // 本文検索側は「R-18」という文字列を本文に含む作品の誤ヒットを
    // 避けるため、常に元のワードのまま送信する。最終的な年齢制限の
    // 絞り込みは searchNovel 内の x_restrict フィルタで行われる。
    final tagWord = buildSearchWord(
      rawQuery: word,
      ageLimit: xRestrict,
      searchTarget: 'partial_match_for_tags',
    );
    final textWord = buildSearchWord(
      rawQuery: word,
      ageLimit: xRestrict,
      searchTarget: 'text',
    );

    final results = await Future.wait<FetchResult<Novel>?>([
      _searchNovelSafely(
        tagWord,
        'partial_match_for_tags',
        sort,
        state.tagNextOffset ?? 0,
        xRestrict,
        minLength,
        maxLength,
        bookmarkFilter: bookmarkFilter,
        onError: (e) => tagError = e,
      ),
      _searchNovelSafely(
        textWord,
        'text',
        sort,
        state.textNextOffset ?? 0,
        xRestrict,
        minLength,
        maxLength,
        bookmarkFilter: bookmarkFilter,
        onError: (e) => textError = e,
      ),
    ]);

    final tagResult = results[0];
    final textResult = results[1];

    // 両方失敗した場合のみ上位（UI）へエラーを伝播する。
    if (tagResult == null && textResult == null) {
      throw Exception('全文検索に失敗しました（タグ: $tagError / 本文: $textError）');
    }

    // ID で統合しつつ重複除去（タグ側をベースに、本文側の未含のものを追加）。
    // 片方の検索が失敗した場合は成功した側のみで結果を構成する。
    final items = mergeById<Novel>(
      tagResult?.items ?? const [],
      textResult?.items ?? const [],
      (n) => n.id,
    );

    // 新しい状態を構築（それぞれの検索の nextUrl/offset とエラーを保持）
    final newState = AllTextSearchState(
      tagNextOffset: tagResult?.nextOffset,
      textNextOffset: textResult?.nextOffset,
      tagNextUrl: tagResult?.nextUrl,
      textNextUrl: textResult?.nextUrl,
      searchItem: tagResult?.searchItem ?? textResult?.searchItem,
      tagError: tagError?.toString(),
      textError: textError?.toString(),
    );

    // nextUrl は片方でもあれば継続可能（呼び出し側では state.hasNext で判定）
    // 互換性のため、どちらかの nextUrl を代表として返す
    final nextUrl = tagResult?.nextUrl ?? textResult?.nextUrl;

    final fetchResult = FetchResult<Novel>(
      items: items,
      nextUrl: nextUrl,
      searchItem: newState.searchItem,
    );

    return AllTextSearchResult<Novel>(result: fetchResult, state: newState);
  }

  /// [searchNovel] を例外が外に漏れないように実行する。
  /// 失敗時は [onError] に通知し null を返す（全文検索の並行実行用）。
  /// これにより片方の検索が失敗してももう片方の結果を返せる。
  Future<FetchResult<Novel>?> _searchNovelSafely(
    String word,
    String searchTarget,
    String sort,
    int offset,
    String xRestrict,
    int? minLength,
    int? maxLength, {
    required int bookmarkFilter,
    required void Function(Object error) onError,
  }) async {
    try {
      return await searchNovel(
        word,
        searchTarget,
        sort,
        offset,
        xRestrict,
        minLength,
        maxLength,
        bookmarkFilter: bookmarkFilter,
      );
    } catch (e) {
      debugPrint(
        '[API] searchNovelAllText: 検索失敗 target=$searchTarget, '
        'offset=$offset: $e',
      );
      onError(e);
      return null;
    }
  }

  /// 小説本文の取得（NovelTextDataモデルへの変換）。
  ///
  /// Phase 1（設計書 §5.2 / §12）: Web 版公開エンドポイント
  /// `GET /ajax/novel/{id}`（未認証 OK・webview と同一の本文データ源）を
  /// **優先取得元**とし、`body.content` と `body.textEmbeddedImages`
  /// （Phase 0 確定の挿絵キー、[報告書](../../docs/plans/09-phase0-illustration-keys.md)）を取得する。
  /// 失敗時のみ従来の webview HTML 正規表現抽出にフォールバックする。
  Future<NovelTextData> getNovelText(int novelId) async {
    debugPrint('📍 [DEBUG API] getNovelText リクエスト直前: novelId = $novelId');
    try {
      final data = await _getNovelTextViaAjax(novelId);
      debugPrint(
        '📍 [DEBUG API] getNovelText: ajax 成功 '
        'text.length=${data.novelText.length} '
        'illustrations=${data.illustrations.length}',
      );
      return data;
    } catch (e) {
      debugPrint(
        '📍 [DEBUG API] getNovelText: ajax 取得失敗 → webview にフォールバック: $e',
      );
      return _getNovelTextViaWebview(novelId);
    }
  }

  /// `/ajax/novel/{id}` から本文 + textEmbeddedImages を取得する。
  ///
  /// 挿絵 original URL は Referer + UA のみで取得可能（Phase 0 実測）。
  /// R-18 等の未認証取得不可作品はここで例外 → webview フォールバック。
  Future<NovelTextData> _getNovelTextViaAjax(int novelId) async {
    final uri = Uri.parse('https://www.pixiv.net/ajax/novel/$novelId');
    final response = await PixivHttpClient().client.get(
      uri,
      headers: {
        'User-Agent': _clientHeaders['User-Agent']!,
        'Referer': 'https://www.pixiv.net/',
        'Accept-Language': 'ja-JP',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Pixiv ajax novel HTTPエラー: ${response.statusCode}');
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['error'] == true) {
      throw Exception('Pixiv ajax novel エラー応答（未認証制限等）');
    }
    final body = decoded['body'];
    if (body is! Map<String, dynamic>) {
      throw Exception('Pixiv ajax novel body が不正');
    }

    final String text = body['content'] as String? ?? '';
    if (text.isEmpty) {
      throw Exception('Pixiv ajax novel content が空');
    }

    final illustrations = _extractIllustrationUrls(body['textEmbeddedImages']);

    return NovelTextData(
      id: novelId,
      novelText: text,
      novelPages: text.split('[newpage]').map((p) => p.trim()).toList(),
      illustrations: illustrations,
    );
  }

  /// textEmbeddedImages（Phase 0 確定キー）から localId → 表示 URL のマップを
  /// 構築する。URL は urls.original → urls.1200x1200 → urls.480mw の順で優先
  /// する（設計書 §5.2 / ユーザー確定事項）。
  Map<String, String> _extractIllustrationUrls(dynamic raw) {
    final result = <String, String>{};
    if (raw is! Map) return result;
    raw.forEach((key, value) {
      if (value is! Map) return;
      final urls = value['urls'];
      if (urls is! Map) return;
      final url =
          (urls['original'] as String?) ??
          (urls['1200x1200'] as String?) ??
          (urls['480mw'] as String?);
      if (url != null && url.isNotEmpty) {
        result[key.toString()] = url;
      }
    });
    return result;
  }

  /// webview 応答（ログイン状態）に textEmbeddedImages が同梱されるかの
  /// 確認ログを 1 回だけ出す（設計書 §12 残タスク / §13.1）。
  static bool _loggedWebviewTextEmbeddedImages = false;

  /// 従来の webview HTML 正規表現抽出（フォールバック経路）。
  ///
  /// Pixiv は /v1/novel/text を廃止したため、HTML を返す
  /// /webview/v2/novel を使用する。レスポンス本文から正規表現で
  /// 埋め込み JSON（novel オブジェクト）を抽出し、その中の 'text' キーから
  /// 本文を取得する。
  Future<NovelTextData> _getNovelTextViaWebview(int novelId) async {
    final token = await getAccessToken(await getRefreshToken());

    final uri = Uri.parse('$_baseUrl/webview/v2/novel').replace(
      queryParameters: {
        'id': novelId.toString(),
        'viewer_version': '20221031_ai',
      },
    );

    final response = await PixivHttpClient().client.get(
      uri,
      headers: {..._clientHeaders, 'Authorization': 'Bearer $token'},
    );

    if (response.statusCode != 200) {
      debugPrint('📍 [DEBUG API] getNovelText HTTPエラー: ${response.statusCode}');
      throw Exception('Pixiv APIエラー: ${response.statusCode}');
    }

    final String body = response.body;

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

    if (kDebugMode && !_loggedWebviewTextEmbeddedImages) {
      _loggedWebviewTextEmbeddedImages = true;
      debugPrint(
        '[API] getNovelText(webview): textEmbeddedImages 同梱 = '
        '${novelJson.containsKey('textEmbeddedImages')}',
      );
    }

    final String text = novelJson['text'] as String? ?? '';
    debugPrint('📍 [DEBUG API] getNovelText 本文長: text.length = ${text.length}');

    // webview 応答にも同キーがあれば挿絵マップを拾う（無ければ空マップ）
    final illustrations = _extractIllustrationUrls(
      novelJson['textEmbeddedImages'],
    );

    return NovelTextData(
      id: novelId,
      novelText: text,
      novelPages: text.split('[newpage]').map((p) => p.trim()).toList(),
      illustrations: illustrations,
    );
  }

  /// 小説シリーズのエピソード一覧取得
  Future<List<Novel>> getNovelSeries(int seriesId, {int? lastOrder}) async {
    debugPrint('📍 [DEBUG API] getNovelSeries リクエスト直前: seriesId = $seriesId');
    final params = {'series_id': seriesId.toString(), 'filter': 'for_android'};
    if (lastOrder != null) {
      params['last_order'] = lastOrder.toString();
    }

    final body = await _get('/v1/novel/series', params: params);
    debugPrint('📍 [DEBUG API] getNovelSeries デコード直前');
    return await filterNovelsIsolated(body);
  }

  /// 小説シリーズのエピソード一覧を全ページ取得する（ページネーション対応）。
  /// /v1/novel/series は last_order によるページングを返すため、next_url が
  /// なくなるまで繰り返し取得し、全エピソードを結合して返す。
  /// シリーズ統計文字数検索で全話の文字数を合算するために使用する。
  Future<List<Novel>> getNovelSeriesAll(int seriesId) async {
    debugPrint('📍 [DEBUG API] getNovelSeriesAll 開始: seriesId = $seriesId');
    final all = <Novel>[];
    int? lastOrder;
    const maxPages = 50; // 無限ループ防止
    for (var page = 0; page < maxPages; page++) {
      final params = {
        'series_id': seriesId.toString(),
        'filter': 'for_android',
      };
      if (lastOrder != null) {
        params['last_order'] = lastOrder.toString();
      }
      final body = await _get('/v1/novel/series', params: params);
      final episodes = await filterNovelsIsolated(body);
      if (episodes.isEmpty) break;
      all.addAll(episodes);
      // next_url の有無で継続判定（_wrap と同様に抽出）
      String? nextUrl;
      try {
        final data = jsonDecode(body) as Map<String, dynamic>;
        nextUrl = data['next_url'] as String?;
      } catch (_) {
        nextUrl = null;
      }
      if (nextUrl == null || nextUrl.isEmpty) break;
      // next_url 内の last_order を次ページの last_order として使用
      try {
        final uri = Uri.parse(nextUrl);
        final orderStr =
            uri.queryParameters['last_order'] ?? uri.queryParameters['offset'];
        lastOrder = orderStr != null ? int.tryParse(orderStr) : null;
      } catch (_) {
        lastOrder = null;
      }
    }
    debugPrint(
      '📍 [DEBUG API] getNovelSeriesAll 完了: seriesId=$seriesId, count=${all.length}',
    );
    return all;
  }

  /// イラスト/マンガ/うごイラ単体取得（ディープリンク用）
  Future<Illust> getIllustById(int id) async {
    final body = await _get(
      '/v1/illust/detail',
      params: {'illust_id': id.toString()},
    );
    final data = jsonDecode(body) as Map<String, dynamic>;
    final illustJson = data['illust'] as Map<String, dynamic>?;
    if (illustJson == null) {
      throw Exception('イラストが見つかりませんでした (id=$id)');
    }
    return Illust.fromJson(illustJson);
  }

  /// 小説単体取得（ディープリンク用）
  ///
  /// エンドポイントは /v2/novel/detail を使用（/v1 は廃止済みで
  /// 「指定されたエンドポイントは存在しません」の 404 を返す）。
  Future<Novel> getNovelById(int id) async {
    const endpoint = '/v2/novel/detail';
    try {
      final body = await _get(endpoint, params: {'novel_id': id.toString()});
      final data = jsonDecode(body) as Map<String, dynamic>;
      final novelJson = data['novel'] as Map<String, dynamic>?;
      if (novelJson == null) {
        throw NovelNotFoundException(id);
      }
      return Novel.fromJson(novelJson);
    } on RateLimitException {
      rethrow;
    } on Exception catch (e) {
      debugPrint(
        '[NovelDetail] 小説詳細取得失敗: endpoint=$endpoint, novel_id=$id, error=$e',
      );
      rethrow;
    }
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
  ///
  /// Phase 9c-2: 実体は [PixivHttpClient.post] に委譲する（URL・ヘッダー・
  /// body の組み立ては HttpClient 側と等価）。401 時のキャッシュ破棄（B-6）
  /// は HttpClient.post が行う。
  /// 戻り値は従来どおり デコード済み Map（空ボディなら {}）。
  /// 外向きの例外契約は _get と同じ境界変換で維持:
  ///   PixivRateLimitException → RateLimitException
  ///   PixivAuthException     → AuthException
  ///   上記以外              → 従来の生 Exception
  ///
  /// ※ 従来 _post は全ステータスを生 Exception にしていたため、429/401 も
  ///    生 Exception 相当を維持する（従来互換）。toggleBookmark の catch-all
  ///    はそのまま（B-7 は別フェーズ）。
  Future<Map<String, dynamic>> _post(
    String endpoint, {
    Map<String, String>? body,
  }) async {
    try {
      return await PixivHttpClient().post(endpoint, body: body);
    } on PixivRateLimitException catch (e) {
      throw RateLimitException(e.message, statusCode: e.statusCode);
    } on PixivAuthException catch (e) {
      throw AuthException(
        'Pixiv APIの認証に失敗しました（401）。再ログインが必要です。',
        statusCode: e.statusCode,
      );
    } on PixivForbiddenException catch (e) {
      throw Exception('Pixiv APIエラー: ${e.statusCode}\n${e.message}');
    } on PixivNotFoundException catch (e) {
      throw Exception('Pixiv APIエラー: ${e.statusCode}\n${e.message}');
    }
  }

  /// ブックマーク追加/削除
  ///
  /// Phase 10a (B-7): 失敗を握りつぶさず例外をそのまま投げる。
  /// _post は 429 → RateLimitException / 401 → AuthException /
  /// 403・404 → 生 Exception に変換済み（Phase 9c-2）。
  /// 呼び出し側（IllustDetailHandler / NovelDetailScreen）が型別に
  /// catch してユーザーに理由を伝える。成功時のみ true を返す。
  Future<bool> toggleBookmark(int id, bool isNovel, bool isAdd) async {
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
  }

  /// リフレッシュトークンを登録（永続化）
  /// ユーザーがブックマークしたイラスト一覧を取得
  Future<FetchResult<Illust>> getUserBookmarks({
    int offset = 0,
    String xRestrict = 'all',
    String? tag,
  }) async {
    try {
      final params = <String, String>{
        'user_id': 'me',
        'restrict': 'public',
        'offset': offset.toString(),
        'filter': 'for_android',
        'x_restrict': xRestrict,
      };
      if (tag != null && tag.isNotEmpty) {
        params['tag'] = tag;
      }
      final body = await _get('/v1/user/bookmarks/illust', params: params);
      final items = await filterIllustsIsolated(body, xRestrict: xRestrict);
      return _wrap(items: items, rawBody: body);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getUserBookmarks failed: offset=$offset, error=$e');
      return const FetchResult<Illust>(items: []);
    }
  }

  /// ユーザーがブックマークした小説一覧を取得
  Future<FetchResult<Novel>> getUserBookmarkNovels({
    int offset = 0,
    String xRestrict = 'all',
    String? tag,
  }) async {
    try {
      final params = <String, String>{
        'user_id': 'me',
        'restrict': 'public',
        'offset': offset.toString(),
        'x_restrict': xRestrict,
      };
      if (tag != null && tag.isNotEmpty) {
        params['tag'] = tag;
      }
      final body = await _get('/v1/user/bookmarks/novel', params: params);
      final items = await filterNovelsIsolated(body, xRestrict: xRestrict);
      return _wrap(items: items, rawBody: body);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint(
        '[API] getUserBookmarkNovels failed: offset=$offset, error=$e',
      );
      return const FetchResult<Novel>(items: []);
    }
  }

  /// フォロー中イラスト一覧を取得
  Future<FetchResult<Illust>> getFollowedIllusts({
    int offset = 0,
    String xRestrict = 'all',
  }) async {
    try {
      final body = await _get(
        '/v2/illust/follow',
        params: {
          'offset': offset.toString(),
          'filter': 'for_android',
          'x_restrict': xRestrict,
        },
      );
      final items = await filterIllustsIsolated(body, xRestrict: xRestrict);
      return _wrap(items: items, rawBody: body);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getFollowedIllusts failed: offset=$offset, error=$e');
      return const FetchResult<Illust>(items: []);
    }
  }

  /// フォロー中新着一覧を取得
  Future<FetchResult<Novel>> getFollowedNovels({
    int offset = 0,
    String xRestrict = 'all',
  }) async {
    try {
      final body = await _get(
        '/v1/novel/follow',
        params: {
          'offset': offset.toString(),
          'filter': 'for_android',
          'x_restrict': xRestrict,
        },
      );
      final items = await filterNovelsIsolated(body, xRestrict: xRestrict);
      return _wrap(items: items, rawBody: body);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getFollowedNovels failed: offset=$offset, error=$e');
      return const FetchResult<Novel>(items: []);
    }
  }

  /// 新着イラスト一覧を取得
  Future<FetchResult<Illust>> getNewIllusts({
    int offset = 0,
    String xRestrict = 'all',
  }) async {
    try {
      final body = await _get(
        '/v1/illust/new',
        params: {
          'offset': offset.toString(),
          'filter': 'for_android',
          'x_restrict': xRestrict,
        },
      );
      final items = await filterIllustsIsolated(body, xRestrict: xRestrict);
      return _wrap(items: items, rawBody: body);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getNewIllusts failed: offset=$offset, error=$e');
      return const FetchResult<Illust>(items: []);
    }
  }

  /// 新着小説一覧を取得
  Future<FetchResult<Novel>> getNewNovels({
    int offset = 0,
    String xRestrict = 'all',
  }) async {
    try {
      final body = await _get(
        '/v1/novel/new',
        params: {
          'offset': offset.toString(),
          'filter': 'for_android',
          'x_restrict': xRestrict,
        },
      );
      final items = await filterNovelsIsolated(body, xRestrict: xRestrict);
      return _wrap(items: items, rawBody: body);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getNewNovels failed: offset=$offset, error=$e');
      return const FetchResult<Novel>(items: []);
    }
  }

  /// トレンドタグ一覧を取得
  Future<List<TrendingTag>> getTrendingTags(String type) async {
    try {
      final body = await _get('/v1/trending-tags/$type');
      final data = jsonDecode(body) as Map<String, dynamic>;
      final tagsJson = data['trend_tags'] as List<dynamic>? ?? const [];
      return tagsJson
          .map((e) => TrendingTag.fromJson(e as Map<String, dynamic>))
          .toList();
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getTrendingTags failed: type=$type, error=$e');
      return const <TrendingTag>[];
    }
  }

  /// フォロー中のユーザー一覧を取得
  Future<FetchResult<User>> getFollowedUsers({
    int offset = 0,
    bool restrictPublic = true,
  }) async {
    try {
      final body = await _get(
        '/v1/user/following',
        params: {
          'user_id': 'me',
          'restrict': restrictPublic ? 'public' : 'private',
          'offset': offset.toString(),
        },
      );
      final data = jsonDecode(body) as Map<String, dynamic>;
      final usersJson = data['user_previews'] as List<dynamic>? ?? const [];
      final items = usersJson
          .map((e) => User.fromJson(e as Map<String, dynamic>))
          .toList();
      return _wrap(items: items, rawBody: body);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getFollowedUsers failed: offset=$offset, error=$e');
      return const FetchResult<User>(items: []);
    }
  }

  /// おすすめユーザー一覧を取得
  Future<FetchResult<User>> getRecommendedUsers({int offset = 0}) async {
    try {
      final body = await _get(
        '/v1/user/recommended',
        params: {'offset': offset.toString()},
      );
      final data = jsonDecode(body) as Map<String, dynamic>;
      final usersJson = data['user_previews'] as List<dynamic>? ?? const [];
      final items = usersJson
          .map((e) => User.fromJson(e as Map<String, dynamic>))
          .toList();
      return _wrap(items: items, rawBody: body);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getRecommendedUsers failed: offset=$offset, error=$e');
      return const FetchResult<User>(items: []);
    }
  }

  /// ユーザー検索
  Future<FetchResult<User>> searchUsers(
    String word, {
    int offset = 0,
    String? sort,
  }) async {
    try {
      final params = <String, String>{
        'word': word,
        'offset': offset.toString(),
        'filter': 'for_android',
      };
      if (sort != null && sort.isNotEmpty) {
        params['sort'] = sort;
      }
      final body = await _get('/v1/search/user', params: params);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final usersJson = data['user_previews'] as List<dynamic>? ?? const [];
      final items = usersJson
          .map((e) => User.fromJson(e as Map<String, dynamic>))
          .toList();
      final searchItem = _extractSearchItem(body);
      return _wrap(items: items, rawBody: body, searchItem: searchItem);
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint(
        '[API] searchUsers failed: word=$word, offset=$offset, error=$e',
      );
      return const FetchResult<User>(items: []);
    }
  }

  /// ピックアップ記事一覧を取得
  Future<List<Map<String, dynamic>>> getSpotlightArticles({
    String? category,
    int offset = 0,
  }) async {
    try {
      final params = <String, String>{'offset': offset.toString()};
      if (category != null && category.isNotEmpty) {
        params['category'] = category;
      }
      final body = await _get('/v1/spotlight/articles', params: params);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final articles = data['articles'] as List<dynamic>? ?? const [];
      return articles
          .map((e) => (e as Map<String, dynamic>).cast<String, dynamic>())
          .toList();
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[API] getSpotlightArticles failed: offset=$offset, error=$e');
      return const <Map<String, dynamic>>[];
    }
  }

  /// フォロー中ユーザーの詳細情報を一覧取得
  Future<List<Map<String, dynamic>>> getFollowedUserDetails({
    int offset = 0,
    bool restrictPublic = true,
  }) async {
    try {
      final body = await _get(
        '/v1/user/following/detail',
        params: {
          'user_id': 'me',
          'restrict': restrictPublic ? 'public' : 'private',
          'offset': offset.toString(),
        },
      );
      final data = jsonDecode(body) as Map<String, dynamic>;
      final usersJson = data['user_previews'] as List<dynamic>? ?? const [];
      return usersJson
          .map((e) => (e as Map<String, dynamic>).cast<String, dynamic>())
          .toList();
    } on RateLimitException {
      rethrow;
    } on AuthException {
      rethrow;
    } on Exception catch (e) {
      debugPrint(
        '[API] getFollowedUserDetails failed: offset=$offset, error=$e',
      );
      return const <Map<String, dynamic>>[];
    }
  }

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
///
/// [hasError] は取得失敗時に true になる（Phase 10c）。
/// items が空でも「無反応の空リスト」ではなく「エラー＋再試行」を表示するために使う。
class FetchResult<T> {
  final List<T> items;
  final String? nextUrl;
  final SearchItem? searchItem;
  final bool hasError;

  const FetchResult({
    required this.items,
    this.nextUrl,
    this.searchItem,
    this.hasError = false,
  });

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

  List<T> get items => result.items;
  String? get nextUrl => result.nextUrl;
  SearchItem? get searchItem => result.searchItem;
  int? get nextOffset => result.nextOffset;
  bool get hasNext => result.hasNext || state.hasNext;
}

/// 全文検索（all_text）用の検索状態を保持するクラス。
/// タグ検索（partial_match_for_tags）と本文検索（text）は独立したページング状態を持つため、
/// それぞれの nextUrl/offset を別々に管理する。
class AllTextSearchState {
  final int? tagNextOffset;
  final int? textNextOffset;
  final String? tagNextUrl;
  final String? textNextUrl;
  final SearchItem? searchItem;

  /// タグ検索（partial_match_for_tags）の最終エラー。成功時は null。
  final String? tagError;

  /// 本文検索（text）の最終エラー。成功時は null。
  final String? textError;

  const AllTextSearchState({
    this.tagNextOffset,
    this.textNextOffset,
    this.tagNextUrl,
    this.textNextUrl,
    this.searchItem,
    this.tagError,
    this.textError,
  });

  /// いずれかの検索に次ページがあるか
  bool get hasNext => tagNextOffset != null || textNextOffset != null;

  /// タグ検索・本文検索のいずれかにエラーがあるか
  bool get hasError => tagError != null || textError != null;

  /// ページング継続判定に使う代表 offset（タグ側を優先）。
  /// UI 側の nextOffset ガード（null なら無限スクロール停止）に供給する。
  /// text 検索が先に終了していても tag 検索が続いていれば非 null を返す。
  int? get primaryNextOffset => tagNextOffset ?? textNextOffset;

  /// 空の状態（初回検索前など）を生成
  static const AllTextSearchState empty = AllTextSearchState();
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
/// シリアライズ可能な `List<Map<String, dynamic>>` を返す。
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
    debugPrint(
      '❌ [API][ISOLATE FATAL] _filterIllustsInIsolate: JSONデコード失敗: $e',
    );
    debugPrint(stack.toString());
    return <Map<String, dynamic>>[];
  }

  final List<Map<String, dynamic>> filtered = [];

  for (var item in list) {
    try {
      final Map<String, dynamic> itemMap = item as Map<String, dynamic>;

      final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
      final String xLower = (xRestrict ?? '').toLowerCase();
      if (xLower == 'all' && xRestrictVal != 0) {
        continue; // 全年齢のみ：R-18(1)/R-18G(2)を除外
      } else if (xLower == 'r18' && xRestrictVal != 1) {
        continue; // R-18のみ：全年齢(0)・R-18G(2)を除外
      } else if (xLower == 'r18g' && xRestrictVal != 2) {
        continue; // R-18Gのみ：全年齢(0)・R-18(1)を除外
      }
      // include_r18 / その他はすべて表示

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

      // AI作品ミュート（19A-1: shouldKeepAiWork に集約）
      final int aiType = itemMap['illust_ai_type'] as int? ?? 0;
      if (!PixivApiService.shouldKeepAiWork(aiMuteValue, aiType == 2)) {
        continue;
      }

      filtered.add(itemMap);
    } catch (e, stack) {
      final idStr = (item is Map && item['id'] != null)
          ? item['id'].toString()
          : 'unknown';
      debugPrint('[API][PARSE ERROR] Illust id=$idStr, error=$e');
      debugPrint(stack.toString());
    }
  }

  debugPrint(
    '[API] filterIllusts(Isolate): input=${list.length}, output=${filtered.length}',
  );
  return filtered;
}

/// Isolate 上で小説の JSON デコード＋ミュート適用を行い、
/// シリアライズ可能な `List<Map<String, dynamic>>` を返す。
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
    debugPrint('❌ [API][ISOLATE FATAL] _filterNovelsInIsolate: JSONデコード失敗: $e');
    debugPrint(stack.toString());
    return <Map<String, dynamic>>[];
  }

  final List<Map<String, dynamic>> filtered = [];

  for (var item in list) {
    try {
      final Map<String, dynamic> itemMap = item as Map<String, dynamic>;
      // 0. 年齢制限（x_restrict）フィルタリング
      final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
      final String xLower = (xRestrict ?? '').toLowerCase();
      if (xLower == 'all' && xRestrictVal != 0) {
        continue; // 全年齢のみ
      } else if (xLower == 'r18' && xRestrictVal != 1) {
        continue; // R-18のみ
      } else if (xLower == 'r18g' && xRestrictVal != 2) {
        continue; // R-18Gのみ
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

      // AI作品ミュート（19A-1: shouldKeepAiWork に集約）
      final int aiType = itemMap['novel_ai_type'] as int? ?? 0;
      if (!PixivApiService.shouldKeepAiWork(aiMuteValue, aiType == 2)) {
        continue;
      }

      filtered.add(itemMap);
    } catch (e, stack) {
      // 個別小説のパース失敗は1件スキップし、残りの健全な小説を表示
      final idStr = (item is Map && item['id'] != null)
          ? item['id'].toString()
          : 'unknown';
      debugPrint('[API][PARSE ERROR] Novel id=$idStr, error=$e');
      debugPrint(stack.toString());
    }
  }

  debugPrint(
    '[API] filterNovels(Isolate): input=${list.length}, output=${filtered.length}',
  );
  return filtered;
}
