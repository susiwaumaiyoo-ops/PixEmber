// Phase 9c-2: _post の PixivHttpClient.post 委譲と境界例外変換の契約テスト。
//
// 確認すること（外向きの例外型が従来と同一であること）:
//   200/201 → 従来どおりデコード済み Map（空ボディは {}）
//   429    → RateLimitException に変換されて届く
//   401    → AuthException に変換され、トークンキャッシュを破棄する
//   404/403→ 従来どおり生 Exception
//
// 手段: MockClient で共有クライアントを差し替える（実サーバー不使用・実待ちゼロ）。
// ※ toggleBookmark は catch-all で握りつぶすため、testPost で直接観測する。

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
  late List<http.Request> apiCalls;
  late List<http.Request> tokenCalls;
  late int tokenCallSnapshot;

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
    httpClient.setTestClient(null);
    httpClient.setTestNow(null);
    httpClient.clearTokenCache();
  });

  /// トークン取得は成功させ、API POST だけを指定ステータスで返すモック。
  void setApiOnlyClient({required int statusCode, String body = ''}) {
    apiCalls = [];
    tokenCalls = [];
    httpClient.setTestClient(
      MockClient((request) async {
        if (request.url.host == 'oauth.secure.pixiv.net') {
          tokenCalls.add(request);
          return http.Response(
            jsonEncode({
              'response': {'access_token': 'access-1', 'expires_in': 3600},
            }),
            200,
          );
        }
        apiCalls.add(request);
        return http.Response(body, statusCode);
      }),
    );
  }

  /// 非同期 throw を検証する。
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

  group('9c-2 _post の境界例外変換', () {
    test('200 ならデコード済み Map を返す', () async {
      setApiOnlyClient(statusCode: 200, body: '{"ok":true}');

      final result = await apiService.testPost('/v2/novel/bookmark/add');
      expect(result, {'ok': true});
      expect(apiCalls.length, 1);
    });

    test('201 ならデコード済み Map を返す', () async {
      setApiOnlyClient(statusCode: 201, body: '{"created":true}');

      final result = await apiService.testPost('/v2/novel/bookmark/add');
      expect(result, {'created': true});
    });

    test('空ボディの 200 は空 Map を返す', () async {
      setApiOnlyClient(statusCode: 200, body: '');

      final result = await apiService.testPost('/v1/novel/bookmark/delete');
      expect(result, isEmpty);
    });

    test('429 は RateLimitException に変換されて届く', () async {
      setApiOnlyClient(statusCode: 429);

      await expectThrowsAsync<RateLimitException>(
        () => apiService.testPost('/v2/novel/bookmark/add'),
      );
    });

    test('401 は AuthException に変換され、トークンキャッシュを破棄する', () async {
      setApiOnlyClient(statusCode: 401);
      final token = await apiService.getAccessToken('test-refresh-token-A');
      expect(token, 'access-1');
      tokenCallSnapshot = tokenCalls.length;

      await expectThrowsAsync<AuthException>(
        () => apiService.testPost('/v2/novel/bookmark/add'),
      );

      // B-6: 401 でキャッシュが破棄されているため、次の取得でトークンを
      // 再取得する（トークンエンドポイントへのリクエストが増える）。
      final token2 = await apiService.getAccessToken('test-refresh-token-A');
      expect(token2, 'access-1');
      expect(tokenCalls.length, greaterThan(tokenCallSnapshot));
    });

    test('404 は生 Exception のまま', () async {
      setApiOnlyClient(statusCode: 404);

      Object? caught;
      try {
        await apiService.testPost('/v2/novel/bookmark/add');
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isNot(isA<RateLimitException>()));
      expect(caught, isNot(isA<AuthException>()));
    });

    test('403 は生 Exception のまま', () async {
      setApiOnlyClient(statusCode: 403);

      Object? caught;
      try {
        await apiService.testPost('/v2/novel/bookmark/add');
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught, isNot(isA<RateLimitException>()));
      expect(caught, isNot(isA<AuthException>()));
    });
  });
}
