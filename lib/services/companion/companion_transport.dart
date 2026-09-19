// 10-B1: LAN HTTPS トランスポート（証明書 pinning・Connection: close・認証ヘッダ管理）。
//
// セキュリティ方針（§2-B / §4-C）:
// - TOFU 禁止。ペアリングで受け取った cert の SHA-256(DER) と一致する証明書のみ信頼。
// - 不一致・失効は hard fail（CompanionCertException）。無条件信頼や blanket 許可はしない。
// - HttpOverrides のグローバル弱体化は行わない（この HttpClient インスタンスのみ）。
// - device token は pinning 済みホストへのリクエストにのみ付与。リダイレクト先へ転送しない
//   （followRedirects=false）。
// - 10-A 既知制限: サーバ側 keep-alive idle 未回収のため毎回 Connection: close。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 認証系の失敗（401/503）。code はサーバの snake_case エラーコード。
class CompanionAuthException implements Exception {
  CompanionAuthException(this.code, {this.statusCode});
  final String
  code; // unauthorized / device_revoked / pairing_required / invalid_pairing_code / pairing_disabled
  final int? statusCode;

  /// 「認証失効」を UI が判別できるようにする。
  bool get isRevoked => code == 'device_revoked';
  bool get needsPairing => code == 'pairing_required' || code == 'unauthorized';

  @override
  String toString() => 'CompanionAuthException($code, http=$statusCode)';
}

/// 証明書不一致・失効（hard fail・再接続で信頼し直してはならない）。
class CompanionCertException implements Exception {
  CompanionCertException(this.message);
  final String message;
  @override
  String toString() => 'CompanionCertException: $message';
}

/// 接続断・タイムアウト（ジョブ失敗とは区別する — §4-C）。
class CompanionNetworkException implements Exception {
  CompanionNetworkException(this.message);
  final String message;
  @override
  String toString() => 'CompanionNetworkException: $message';
}

/// HTTP レスポンス（JSON デコード済み）。
class CompanionResponse {
  CompanionResponse(this.statusCode, this.json);
  final int statusCode;
  final Map<String, dynamic> json;

  bool get is2xx => statusCode >= 200 && statusCode < 300;
  String? get error => json['error'] is String ? json['error'] as String : null;
}

class CompanionTransport {
  CompanionTransport({
    required this.baseUrl,
    required this.pinnedCertSha256,
    this.deviceToken,
  });

  final String baseUrl; // https://host:port
  final String pinnedCertSha256; // lowercase hex
  final String? deviceToken;

  late final Uri _root = Uri.parse(baseUrl);
  String get _host => _root.host;
  int get _port => _root.hasPort ? _root.port : 443;

  HttpClient _newClient() {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
          // 接続先が pinning 設定したホスト/ポートそのものであること。
          if (host.toLowerCase() != _host.toLowerCase() || port != _port) {
            return false;
          }
          // 有効期間（失効証明書は拒否）。dart:io は startValidity/endValidity を UTC 提供。
          final now = DateTime.now().toUtc();
          if (now.isBefore(cert.startValidity.toUtc()) ||
              now.isAfter(cert.endValidity.toUtc())) {
            return false;
          }
          // 最重要: DER の SHA-256 がペアリング時の pin と完全一致。
          final digest = sha256.convert(cert.der).toString().toLowerCase();
          return digest == pinnedCertSha256.toLowerCase();
        };
    return client;
  }

  /// device token を付与すべきパスか（/pair と /health は不要）。
  bool _needsAuth(String path) =>
      !path.startsWith('/pair') && !path.startsWith('/health');

  Future<CompanionResponse> request(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final url = Uri.parse('$baseUrl$path');
    final client = _newClient();
    try {
      final req = await client.openUrl(method, url).timeout(timeout);
      req.followRedirects = false; // 認証ヘッダをリダイレクト先へ転送しない
      req.headers.set(HttpHeaders.connectionHeader, 'close');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      debugPrint(
        '[COMPANION-REQ] $method $baseUrl$path '
        'body=${body == null ? "(none)" : "(${jsonEncode(body).length} bytes)"}',
      );
      if (auth &&
          _needsAuth(path) &&
          deviceToken != null &&
          deviceToken!.isNotEmpty) {
        req.headers.set('X-Pixember-Device', deviceToken!);
      }
      if (body != null) {
        final payload = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        // Python http.server は Content-Length を前提に本文を読む。
        // Dart は contentLength を明示しないと chunked 送信してしまい、
        // サーバが body={} 扱いになって bad_pair_request になる。
        req.headers.contentLength = payload.length;
        req.add(payload);
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join().timeout(timeout);
      Map<String, dynamic> json;
      if (text.trim().isEmpty) {
        json = <String, dynamic>{};
      } else {
        try {
          final decoded = jsonDecode(text);
          json = decoded is Map
              ? Map<String, dynamic>.from(decoded)
              : <String, dynamic>{'raw': decoded};
        } catch (_) {
          json = <String, dynamic>{'raw': text};
        }
      }
      // 401/503 は認証例外として型化する（UI が種別表示できるように）。
      // ログはステータス/エラーコードのみ（トークンや本文は絶対に出さない）。
      debugPrint(
        '[COMPANION-RESP] ${resp.statusCode} '
        "${json['error'] is String ? json['error'] : 'ok'}",
      );
      if (resp.statusCode == 401 || resp.statusCode == 503) {
        throw CompanionAuthException(
          json['error'] is String ? json['error'] as String : 'unauthorized',
          statusCode: resp.statusCode,
        );
      }
      return CompanionResponse(resp.statusCode, json);
    } on CompanionAuthException {
      rethrow;
    } on SocketException catch (e) {
      throw CompanionNetworkException(
        '接続できません: ${e.osError?.message ?? e.message}',
      );
    } on HandshakeException catch (e) {
      // pinning 不一致はここに来る（badCertificateCallback が false を返した）。
      throw CompanionCertException('証明書が信頼できません: ${e.message}');
    } on TimeoutException {
      throw CompanionNetworkException('タイムアウト');
    } finally {
      client.close(force: true);
    }
  }

  Future<CompanionResponse> get(
    String path, {
    bool auth = true,
    Duration? timeout,
  }) => request(
    'GET',
    path,
    auth: auth,
    timeout: timeout ?? const Duration(seconds: 12),
  );

  Future<CompanionResponse> post(
    String path,
    Object body, {
    bool auth = true,
    Duration? timeout,
  }) => request(
    'POST',
    path,
    body: body,
    auth: auth,
    timeout: timeout ?? const Duration(seconds: 15),
  );
}
