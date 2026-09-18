// Phase 9b-3: 並行リフレッシュの直列化（バグ B-8）。
//
// 確認すること:
//   - 同一リフレッシュトークンの並行呼び出しは1回の HTTP にまとまり、
//     全ての呼び出しが同じ値を受け取る。
//   - 失敗は全ての待ち受けに伝播し、in-flight は解除されるため
//     次の呼び出しは再試行できる（失敗が sticky にならない）。
//   - 異なるリフレッシュトークンは並行しても共有しない。
//   - clearTokenCache を完了前に呼ぶと、結果はキャッシュに書き戻らない。
//
// タイミング制御: Completer で遅延する MockClient を使い、本物の待ち時間を
// 発生させずに並行状態を作る。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_viewer/services/pixiv_api_http.dart';

void main() {
  late PixivHttpClient httpClient;
  late List<http.Request> tokenCalls;

  /// OAuth トークンエンドポイントのモックレスポンスを構築する。
  String tokenResponseBody({required String accessToken, int expiresIn = 3600}) {
    return jsonEncode({
      'response': {'access_token': accessToken, 'expires_in': expiresIn},
    });
  }

  /// 全ての要求を完了ゲートが開くまで待たせるモック（共有ゲート）。
  /// 並行 join の確認用: 複数の要求が同じ Future を待つ状況を作る。
  http.Client mockGatedTokenClient(Completer<http.Response> gate) {
    tokenCalls = [];
    return MockClient((request) async {
      tokenCalls.add(request);
      return gate.future;
    });
  }

  /// 1回目の要求だけ完了ゲートを待ち、以降は即座に成功レスポンスを返すモック。
  /// 失敗後の再試行確認用。
  http.Client mockFirstGatedTokenClient(Completer<http.Response> gate) {
    tokenCalls = [];
    var gated = true;
    return MockClient((request) async {
      tokenCalls.add(request);
      if (gated) {
        gated = false;
        return gate.future;
      }
      return http.Response(
        tokenResponseBody(accessToken: 'access-retry', expiresIn: 3600),
        200,
      );
    });
  }

  /// マイクロタスクを数回消化する。
  ///
  /// このバージョンの package:http は send() の呼び出しをマイクロタック
  /// スケジュールするため、並行に発行された要求が落ち着くまでキューを
  /// 回してからカウントしないと実測できない。本物の待ち時間は発生しない。
  Future<void> pump([int times = 8]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.microtask(() {});
    }
  }

  setUp(() {
    tokenCalls = [];
    httpClient = PixivHttpClient();
    httpClient.clearTokenCache();
    httpClient.setTestNow(null);
  });

  tearDown(() {
    httpClient.setTestClient(null);
    httpClient.setTestNow(null);
    httpClient.clearTokenCache();
  });

  group('9b-3 並行リフレッシュの直列化', () {
    test('同一トークンの並行呼び出しは1回の HTTP で全員同じ値を得る', () async {
      final gate = Completer<http.Response>();
      httpClient.setTestClient(mockGatedTokenClient(gate));

      final f1 = httpClient.getAccessToken('refresh-A');
      final f2 = httpClient.getAccessToken('refresh-A');
      final f3 = httpClient.getAccessToken('refresh-A');

      // 3回呼んでも HTTP リクエストは1回だけ（直列化）。
      await pump();
      expect(tokenCalls.length, 1);

      gate.complete(
        http.Response(tokenResponseBody(accessToken: 'access-1'), 200),
      );

      final results = await Future.wait([f1, f2, f3]);
      expect(results, ['access-1', 'access-1', 'access-1']);
    });

    test('失敗は全ての待ち受けに伝播し、次の呼び出しは再試行する', () async {
      final gate = Completer<http.Response>();
      httpClient.setTestClient(mockFirstGatedTokenClient(gate));

      final f1 = httpClient.getAccessToken('refresh-A');
      final f2 = httpClient.getAccessToken('refresh-A');

      gate.complete(http.Response(jsonEncode({'error': 'invalid_grant'}), 400));

      for (final f in [f1, f2]) {
        try {
          await f;
          fail('expected to throw but completed normally');
        } on Exception {
          // expected: 400 invalid_grant。
        }
      }

      // in-flight が解除されているため、次の呼び出しは新しい HTTP を発行する
      // （失敗した Future が sticky になっていない）。
      expect(await httpClient.getAccessToken('refresh-A'), 'access-retry');
      expect(tokenCalls.length, 2);
    });

    test('異なるトークンは並行しても共有しない', () async {
      final gate = Completer<http.Response>();
      httpClient.setTestClient(mockGatedTokenClient(gate));

      final f1 = httpClient.getAccessToken('token-A');
      final f2 = httpClient.getAccessToken('token-B');

      // トークンが異なれば並行してもそれぞれ1回ずつ発行する。
      await pump();
      expect(tokenCalls.length, 2);

      gate.complete(
        http.Response(tokenResponseBody(accessToken: 'access-1'), 200),
      );

      final results = await Future.wait([f1, f2]);
      expect(results, ['access-1', 'access-1']);
    });

    test('clearTokenCache を完了前に呼ぶと結果をキャッシュしない', () async {
      final gate = Completer<http.Response>();
      httpClient.setTestClient(mockFirstGatedTokenClient(gate));

      final f1 = httpClient.getAccessToken('refresh-A');
      // 通信完了前にキャッシュを破棄する。
      httpClient.clearTokenCache();
      await pump();
      expect(tokenCalls.length, 1);

      gate.complete(
        http.Response(tokenResponseBody(accessToken: 'access-1'), 200),
      );
      await f1;

      // キャッシュに書き戻されていないため、次の呼び出しで再取得する。
      expect(await httpClient.getAccessToken('refresh-A'), 'access-retry');
      expect(tokenCalls.length, 2);
    });
  });
}
