// Phase 9a Section C: 外部通信なしの認証回帰テスト。
//
// 対象: PixivHttpClient（トークンキャッシュの本体）＋
//       PixivApiService の転送メソッド（Phase 9a で HttpClient へ委譲）。
// 手段: package:http/testing.dart の MockClient で共有クライアントを差し替え、
//       時刻注入点（setTestNow）で期限を制御する。
// ※ 本物の Pixiv アカウント・トークン・ネットワークは一切使わない。
// ※ プロダクションの共有 client は close せず、tearDown で差替を解除する。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_viewer/services/pixiv_api/pixiv_api_service.dart';
import 'package:pixiv_viewer/services/pixiv_api_http.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late PixivHttpClient httpClient;
  late PixivApiService apiService;
  late List<http.Request> tokenCalls;
  late List<http.Request> apiCalls;

  /// OAuth トークンエンドポイントのモックレスポンスを構築する。
  String tokenResponseBody({
    required String accessToken,
    String? refreshToken,
    int expiresIn = 3600,
  }) {
    return jsonEncode({
      'response': {
        'access_token': accessToken,
        'refresh_token': ?refreshToken,
        'expires_in': expiresIn,
      },
    });
  }

  http.Client mockTokenClient({required int statusCode, required String body}) {
    tokenCalls = [];
    return MockClient((request) async {
      tokenCalls.add(request);
      return http.Response(body, statusCode);
    });
  }

  http.Client mockApiClient({required int statusCode, String body = ''}) {
    apiCalls = [];
    return MockClient((request) async {
      apiCalls.add(request);
      return http.Response(body, statusCode);
    });
  }

  /// 非同期 throw を検証する（throwsA を Future に直接適用しない）。
  Future<void> expectThrowsAsync<T extends Object>(
    Future<Object> Function() fn,
  ) async {
    try {
      await fn();
      fail('expected to throw but completed normally');
    } on T {
      // expected
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'PIXIV_REFRESH_TOKEN': 'test-refresh-token-A',
    });
    httpClient = PixivHttpClient();
    httpClient.clearTokenCache();
    httpClient.setTestNow(null);
    apiService = PixivApiService();
  });

  tearDown(() {
    // プロダクションの共有クライアントは close せず、差替だけ解除する。
    httpClient.setTestClient(null);
    httpClient.setTestNow(null);
    httpClient.clearTokenCache();
  });

  group('C-1 リフレッシュトークン未保存', () {
    test('getRefreshToken が例外を投げる（トークン取得呼び出し前に失敗）', () async {
      SharedPreferences.setMockInitialValues({});
      httpClient = PixivHttpClient();
      httpClient.clearTokenCache();

      await expectThrowsAsync<Exception>(() => httpClient.getRefreshToken());
    });

    test('API 呼び出し経由でも未保存なら例外を投げる（HTTP 呼び出し前に失敗）', () async {
      SharedPreferences.setMockInitialValues({});
      httpClient = PixivHttpClient();
      httpClient.clearTokenCache();
      httpClient.setTestClient(mockTokenClient(statusCode: 200, body: '{}'));

      // get() は内部で getRefreshToken() を呼ぶので、未保存なら例外。
      // ※ getAccessToken(refreshToken) は引数でトークンを受け取るため、
      //   トークン未設定でも HTTP 呼び出しが発生する点は注意（実装仕様）。
      await expectThrowsAsync<Exception>(
        () => httpClient.get('/v1/user/detail'),
      );
      expect(tokenCalls, isEmpty);
    });
  });

  group('C-2 正常レスポンスの戻り値と保存の副作用', () {
    test('access_token を返し、expires_in から期限を計算してキャッシュする', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(
            accessToken: 'access-1',
            refreshToken: 'rotated-refresh',
            expiresIn: 3600,
          ),
        ),
      );

      final token = await httpClient.getAccessToken('refresh-A');

      expect(token, 'access-1');
      expect(await httpClient.getAccessToken('refresh-A'), 'access-1');
      expect(tokenCalls.length, 1);
    });

    test('PixivApiService.getAccessToken は同じ結果を返す（委譲の等価性）', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1'),
        ),
      );

      final fromService = await apiService.getAccessToken('refresh-A');
      final fromClient = await httpClient.getAccessToken('refresh-A');

      expect(fromService, fromClient);
      expect(fromService, 'access-1');
    });

    test('PixivApiService.getRefreshToken は HttpClient と同じ値を返す', () async {
      expect(await apiService.getRefreshToken(), 'test-refresh-token-A');
      expect(await httpClient.getRefreshToken(), 'test-refresh-token-A');
    });
  });

  group('C-3 grant_type / body / headers', () {
    test('grant_type=refresh_token とリフレッシュトークンが送信される', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1'),
        ),
      );

      await httpClient.getAccessToken('refresh-A');

      expect(tokenCalls.length, 1);
      final req = tokenCalls.first;
      expect(req.url.toString(), 'https://oauth.secure.pixiv.net/auth/token');
      expect(req.method, 'POST');
      expect(req.bodyFields['grant_type'], 'refresh_token');
      expect(req.bodyFields['refresh_token'], 'refresh-A');
      expect(req.bodyFields['client_id'], isNotEmpty);
    });

    test('認可エンドポイント用ヘッダーが付与される', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1'),
        ),
      );

      await httpClient.getAccessToken('refresh-A');

      final headers = tokenCalls.first.headers;
      expect(headers['X-Client-Time'], isNotNull);
      expect(headers['X-Client-Hash'], isNotNull);
      expect(headers['Content-Type'], contains('x-www-form-urlencoded'));
    });

    test('ミリ秒を含まない秒精度の X-Client-Time が生成される', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1'),
        ),
      );
      final fixed = DateTime.utc(2026, 1, 2, 3, 4, 5, 678);
      httpClient.setTestNow(() => fixed);

      await httpClient.getAccessToken('refresh-A');

      expect(
        tokenCalls.first.headers['X-Client-Time'],
        '2026-01-02T03:04:05+00:00',
      );
    });
  });

  group('C-4 HTTP 呼び出し回数（Service 側 / HttpClient 側で別々に計測）', () {
    test('キャッシュ有効なら HttpClient のトークン取得は1回だけ', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );

      await httpClient.getAccessToken('refresh-A');
      await httpClient.getAccessToken('refresh-A');
      await httpClient.getAccessToken('refresh-A');

      expect(tokenCalls.length, 1);
    });

    test('キャッシュ無効（force）なら毎回取得する', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );

      await httpClient.getAccessToken('refresh-A', force: true);
      await httpClient.getAccessToken('refresh-A', force: true);

      expect(tokenCalls.length, 2);
    });

    test('Service 経由でもキャッシュが効く（委譲がキャッシュを共有）', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );

      await apiService.getAccessToken('refresh-A');
      await httpClient.getAccessToken('refresh-A');

      expect(tokenCalls.length, 1);
    });

    test('API GET 呼び出しはトークン取得とは別物として計測される', () async {
      // 1) トークン取得用クライアントで access-token を取得
      //    ※ get() は prefs の 'test-refresh-token-A' でキャッシュを引くため、
      //    ここでも同じトークンを使う（Phase 9b-2 でキャッシュが識別される）。
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );
      await httpClient.getAccessToken('test-refresh-token-A');
      expect(tokenCalls.length, 1);

      // 2) API 呼び出し用クライアントに差し替え、GET を1回だけ行う。
      final apiClient = mockApiClient(statusCode: 200, body: '{}');
      httpClient.setTestClient(apiClient);

      final body = await httpClient.get('/v1/user/detail');
      expect(body, '{}');
      expect(apiCalls.length, 1);
      expect(apiCalls.first.headers['Authorization'], 'Bearer access-1');
    });
  });

  group('C-5 キャッシュ期限の境界', () {
    test('期限ちょうどでは再取得する（期限は他と共有しない）', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );
      final start = DateTime.utc(2026, 1, 1, 0, 0, 0);
      httpClient.setTestNow(() => start);

      await httpClient.getAccessToken('refresh-A');
      expect(tokenCalls.length, 1);

      // expires_in 3600 から安全マージン 300 を引いた 3300 秒後まではキャッシュ有効。
      httpClient.setTestNow(() => start.add(const Duration(seconds: 3299)));
      await httpClient.getAccessToken('refresh-A');
      expect(tokenCalls.length, 1);

      // 3300 秒ちょうどで期限切れ → 再取得。
      httpClient.setTestNow(() => start.add(const Duration(seconds: 3300)));
      await httpClient.getAccessToken('refresh-A');
      expect(tokenCalls.length, 2);
    });

    test('expires_in が安全マージン以下ならそのままの値を期限に使う', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 100),
        ),
      );
      final start = DateTime.utc(2026, 1, 1, 0, 0, 0);
      httpClient.setTestNow(() => start);

      await httpClient.getAccessToken('refresh-A');
      expect(tokenCalls.length, 1);

      // 100 秒（マージン未満なので丸めない）までは有効。
      httpClient.setTestNow(() => start.add(const Duration(seconds: 99)));
      await httpClient.getAccessToken('refresh-A');
      expect(tokenCalls.length, 1);

      httpClient.setTestNow(() => start.add(const Duration(seconds: 101)));
      await httpClient.getAccessToken('refresh-A');
      expect(tokenCalls.length, 2);
    });
  });

  group('C-6 clearTokenCache 後の再取得', () {
    test('キャッシュクリアすると次の取得で必ず HTTP 呼び出しが走る', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );

      await httpClient.getAccessToken('refresh-A');
      expect(tokenCalls.length, 1);

      httpClient.clearTokenCache();
      await httpClient.getAccessToken('refresh-A');
      expect(tokenCalls.length, 2);
    });
  });

  group('C-7 異常レスポンスの伝播', () {
    test('JSON として不正なボディは例外を投げる', () async {
      httpClient.setTestClient(
        mockTokenClient(statusCode: 200, body: 'not-json'),
      );

      await expectThrowsAsync<FormatException>(
        () => httpClient.getAccessToken('refresh-A'),
      );
    });

    test('access_token フィールド欠落は例外を投げる', () async {
      httpClient.setTestClient(
        mockTokenClient(statusCode: 200, body: jsonEncode({'response': {}})),
      );

      await expectThrowsAsync<Exception>(
        () => httpClient.getAccessToken('refresh-A'),
      );
    });

    test('認証エラー（401 相当）は例外を投げる', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 400,
          body: jsonEncode({'error': 'invalid_grant'}),
        ),
      );

      await expectThrowsAsync<Exception>(
        () => httpClient.getAccessToken('refresh-A'),
      );
    });

    test('429 相当のステータスも例外として伝播する', () async {
      httpClient.setTestClient(mockTokenClient(statusCode: 429, body: ''));

      await expectThrowsAsync<Exception>(
        () => httpClient.getAccessToken('refresh-A'),
      );
    });

    test('5xx 相当のステータスも例外として伝播する', () async {
      httpClient.setTestClient(
        mockTokenClient(statusCode: 500, body: 'server error'),
      );

      await expectThrowsAsync<Exception>(
        () => httpClient.getAccessToken('refresh-A'),
      );
    });

    test('ネットワーク例外はそのまま伝播する', () async {
      httpClient.setTestClient(
        MockClient((_) async => throw http.ClientException('network')),
      );

      await expectThrowsAsync<http.ClientException>(
        () => httpClient.getAccessToken('refresh-A'),
      );
    });
  });

  group('C-8 追加: トークンキャッシュの識別性', () {
    test('同一トークンを渡せばキャッシュを再利用する', () async {
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );

      await httpClient.getAccessToken('same-token');
      await httpClient.getAccessToken('same-token');

      expect(tokenCalls.length, 1);
    });

    test('異なるトークンではキャッシュを使わず再取得する（B-2 修正）', () async {
      // Phase 9b-2: キャッシュはリフレッシュトークンで識別する。
      // アカウントを切り替えた場合に前のアカウントのアクセストークンを
      // 使い回すバグ（B-2）を防ぐ。
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );

      await httpClient.getAccessToken('token-A');
      await httpClient.getAccessToken('token-B');

      expect(tokenCalls.length, 2);
    });

    test('異なるトークンで上書きされた後、元のトークンは再取得する（A→B→A）', () async {
      // 単一エントリキャッシュ: 最後に取得した内容で上書きされる。
      // A→B→A の順で呼ぶと、3 回目の A は B で上書きされたキャッシュと
      // トークンが異なるため再取得する（多アカウント機能は未実装なので
      // Map ではなく単一エントリで十分）。
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );

      await httpClient.getAccessToken('token-A');
      await httpClient.getAccessToken('token-B');
      await httpClient.getAccessToken('token-A');

      expect(tokenCalls.length, 3);
    });

    test('保存済みトークンを使った API 呼び出しが 401 のときキャッシュを破棄する', () async {
      // 1) トークンを取得してキャッシュする。
      //    ※ get() は prefs のトークン（= setUp の 'test-refresh-token-A'）で
      //    キャッシュを引くため、取得時も同じトークンを使う（Phase 9b-2 で
      //    キャッシュがリフレッシュトークンで識別されるようになったため）。
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-1', expiresIn: 3600),
        ),
      );
      await httpClient.getAccessToken('test-refresh-token-A');

      // 2) API クライアントを 401 で差し替え、キャッシュ破棄を確認する。
      httpClient.setTestClient(mockApiClient(statusCode: 401, body: ''));
      await expectThrowsAsync<PixivAuthException>(
        () => httpClient.get('/v1/user/detail'),
      );

      // 3) トークン再取得クライアントに戻し、キャッシュ破棄で再取得されることを確認。
      httpClient.setTestClient(
        mockTokenClient(
          statusCode: 200,
          body: tokenResponseBody(accessToken: 'access-2', expiresIn: 3600),
        ),
      );
      final token = await httpClient.getAccessToken('test-refresh-token-A');
      expect(token, 'access-2');
    });
  });
}
