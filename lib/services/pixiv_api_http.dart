import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'pixiv_http_headers.dart';

/// 429 Rate Limit エラー用のカスタム例外クラス
class PixivRateLimitException implements Exception {
  final String message;
  final int statusCode;

  PixivRateLimitException(this.message, {this.statusCode = 429});

  @override
  String toString() =>
      'PixivRateLimitException: $message (Status: $statusCode)';
}

/// 401 認証エラー用のカスタム例外クラス
/// DownloadService がトークンリフレッシュ要否を判別するために使用する。
class PixivAuthException implements Exception {
  final String message;
  final int statusCode;

  PixivAuthException(this.message, {this.statusCode = 401});

  @override
  String toString() => 'PixivAuthException: $message (Status: $statusCode)';
}

/// 403 Forbidden エラー用のカスタム例外クラス
class PixivForbiddenException implements Exception {
  final String message;
  final int statusCode;
  final String? errorCode;

  PixivForbiddenException(
    this.message, {
    this.statusCode = 403,
    this.errorCode,
  });

  @override
  String toString() =>
      'PixivForbiddenException: $message (Status: $statusCode${errorCode != null ? ", Code: $errorCode" : ""})';
}

/// 404 Not Found エラー用のカスタム例外クラス
class PixivNotFoundException implements Exception {
  final String message;
  final int statusCode;
  final String? errorCode;

  PixivNotFoundException(this.message, {this.statusCode = 404, this.errorCode});

  @override
  String toString() =>
      'PixivNotFoundException: $message (Status: $statusCode${errorCode != null ? ", Code: $errorCode" : ""})';
}

/// Pixiv App-API への共通 HTTP クライアント。
/// トークン取得・共通ヘッダー・GET/POST を一元化する。
class PixivHttpClient {
  static final PixivHttpClient _instance = PixivHttpClient._internal();
  factory PixivHttpClient() => _instance;
  PixivHttpClient._internal();

  /// 共有 HTTP クライアント（シングルトン）。
  /// TCP 接続と TLS セッションを再利用し、2回目以降のハンドシェイク時間を削減する。
  final http.Client _client = http.Client();

  /// テスト専用のクライアント差替（本番では常に null）。
  /// [client] getter がこちらを優先する。テスト終了時に null をセットして
  /// 本番の共有クライアントへ戻す（プロダクションの client を close しない）。
  http.Client? _testClient;

  /// テスト用注入点: HTTP クライアントを差し替える。
  /// デフォルト（null）は本番動作のまま。公開 API ではない。
  @visibleForTesting
  void setTestClient(http.Client? client) => _testClient = client;

  http.Client get client => _testClient ?? _client;

  /// テスト専用の現在時刻上書き（本番では常に null = 実時刻）。
  /// トークン有効期限の境界テストのためにだけ存在する。
  DateTime Function()? _testNow;

  /// テスト用注入点: 現在時刻を固定/制御する。
  /// デフォルト（null）は本番動作（DateTime.now()）のまま。公開 API ではない。
  @visibleForTesting
  void setTestNow(DateTime Function()? now) => _testNow = now;

  DateTime _now() => (_testNow ?? DateTime.now)().toUtc();

  /// キャッシュされたアクセストークン（force: false 時に再利用）。
  String? _cachedAccessToken;

  /// キャッシュの有効期限（UTC）。この時刻を過ぎたら再取得する。
  DateTime? _tokenExpiry;

  /// トークンキャッシュの有効期間（秒）。Pixiv の access_token は
  /// 通常 3600 秒（1 時間）有効だが、期限ギリギリを避けるため 5 分前に無効化する。
  static const int _tokenTtlSeconds = 3600;
  static const int _tokenSafetyMarginSeconds = 300;

  /// キャッシュされたトークンが有効かどうか。
  bool get _hasValidCachedToken {
    if (_cachedAccessToken == null || _tokenExpiry == null) return false;
    return _now().isBefore(_tokenExpiry!);
  }

  /// トークンキャッシュをクリアする（ログアウト時や 401 リフレッシュ失敗時に呼ぶ）。
  void clearTokenCache() {
    _cachedAccessToken = null;
    _tokenExpiry = null;
  }

  /// アプリ終了時に呼び出せるクローズ用（シングルトンのため通常は
  /// プロセス終了時に回収されるが、明示的に閉じたい場合に提供）。
  void dispose() {
    _client.close();
  }

  static const String baseUrl = 'https://app-api.pixiv.net';

  static const Map<String, String> clientHeaders = {
    'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
    'App-OS': 'android',
    'App-OS-Version': '11',
    'App-Version': '6.71.1',
    'Accept-Language': 'ja-JP',
    'Accept-Encoding': 'gzip',
  };

  /// SharedPreferences からリフレッシュトークンを取得（未設定なら例外）
  Future<String> getRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('PIXIV_REFRESH_TOKEN');
    if (token == null || token.isEmpty) {
      throw Exception('Pixivリフレッシュトークンが設定されていません。再ログインが必要です。');
    }
    return token;
  }

  /// リフレッシュトークンからアクセストークンを取得する。
  /// [force] が true の場合はキャッシュを無視して必ず新しいトークンを取得する
  /// （401 エラー時のリフレッシュで使用）。
  /// [force] が false（デフォルト）の場合は、キャッシュが有効ならそれを返す。
  Future<String> getAccessToken(
    String refreshToken, {
    bool force = false,
  }) async {
    if (!force && _hasValidCachedToken) {
      return _cachedAccessToken!;
    }
    final now = _now();
    final clientTime =
        "${now.year.toString().padLeft(4, '0')}-"
        "${now.month.toString().padLeft(2, '0')}-"
        "${now.day.toString().padLeft(2, '0')}T"
        "${now.hour.toString().padLeft(2, '0')}:"
        "${now.minute.toString().padLeft(2, '0')}:"
        "${now.second.toString().padLeft(2, '0')}+00:00";

    const salt = '2821213q311543184o13o121o131o1o3';
    final clientHash = md5.convert(utf8.encode(clientTime + salt)).toString();

    final response = await client.post(
      Uri.parse('https://oauth.secure.pixiv.net/auth/token'),
      headers: {
        'User-Agent': 'PixivAndroidApp/5.0.234 (Android 11.0; Pixel 5)',
        'App-OS': 'android',
        'App-OS-Version': '11.0',
        'App-Version': '5.0.234',
        'X-Client-Time': clientTime,
        'X-Client-Hash': clientHash,
        'Accept-Language': 'ja_JP',
        'Accept-Encoding': 'gzip',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'client_id': 'MOBrBDS8blbauoSck0ZfDbtuzpyT',
        'client_secret': 'lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj',
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        'トークンのリフレッシュに失敗しました: ${response.statusCode}\n${response.body}',
      );
    }

    final resData = jsonDecode(response.body) as Map<String, dynamic>;
    final payload = resData['response'] as Map<String, dynamic>?;
    final accessToken = payload?['access_token'] as String?;
    if (accessToken == null) {
      throw Exception('レスポンス内に access_token が見つかりませんでした。');
    }
    // トークンをキャッシュし、有効期限を設定する。
    final expiresIn = payload?['expires_in'] as int? ?? _tokenTtlSeconds;
    final effectiveTtl = expiresIn > _tokenSafetyMarginSeconds
        ? expiresIn - _tokenSafetyMarginSeconds
        : expiresIn;
    _cachedAccessToken = accessToken;
    _tokenExpiry = _now().add(Duration(seconds: effectiveTtl));
    return accessToken;
  }

  /// 共通 GET（生のレスポンスボディ文字列を返す）
  Future<String> get(String endpoint, {Map<String, String>? params}) async {
    final token = await getAccessToken(await getRefreshToken());

    var uri = Uri.parse('$baseUrl$endpoint');
    if (params != null && params.isNotEmpty) {
      uri = uri.replace(queryParameters: params);
    }

    final response = await client.get(
      uri,
      headers: {...clientHeaders, 'Authorization': 'Bearer $token'},
    );

    final code = response.statusCode;
    if (code == 200) {
      return response.body;
    } else if (code == 401) {
      clearTokenCache();
      throw PixivAuthException('認証エラー（401）。アクセストークンが無効です。');
    } else if (code == 403) {
      throw PixivForbiddenException('アクセス拒否（403）。${response.body}');
    } else if (code == 404) {
      throw PixivNotFoundException('リソースが見つかりません（404）。${response.body}');
    } else if (code == 429) {
      throw PixivRateLimitException(
        'Pixiv APIのレート制限（429）に達しました。しばらく時間を置いてから再試行してください。',
      );
    }
    throw Exception('Pixiv APIエラー: $code\n${response.body}');
  }

  /// 共通 POST（JSON をデコードして返す）
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, String>? body,
  }) async {
    final token = await getAccessToken(await getRefreshToken());

    final response = await client.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        ...clientHeaders,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body,
    );

    final code = response.statusCode;
    if (code == 200 || code == 201) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else if (code == 401) {
      clearTokenCache();
      throw PixivAuthException('認証エラー（401）。アクセストークンが無効です。');
    } else if (code == 403) {
      throw PixivForbiddenException('アクセス拒否（403）。${response.body}');
    } else if (code == 404) {
      throw PixivNotFoundException('リソースが見つかりません（404）。${response.body}');
    } else if (code == 429) {
      throw PixivRateLimitException(
        'Pixiv APIのレート制限（429）に達しました。しばらく時間を置いてから再試行してください。',
      );
    }
    throw Exception('Pixiv APIエラー: $code\n${response.body}');
  }

  /// DownloadService 用: 画像 CDN 用ヘッダーを取得する。
  /// 認証不要（Referer + User-Agent のみ）。
  static Map<String, String> imageHeaders() {
    return PixivHttpHeaders.imageHeaders();
  }
}
