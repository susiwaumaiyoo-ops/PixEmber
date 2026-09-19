// 10-B1: PC Companion の永続化リポジトリ。
//
// - 接続設定（URL / 証明書pin / device token）→ flutter_secure_storage
//   （Android Keystore 後端。SharedPreferences 平文・Drive バックアップ対象外）。
// - 送信中/未完了ジョブ（job_id + client_request_id）→ SharedPreferences
//   （秘密ではない。アプリ再起動後の再接続・「確認中」判定に使う）。
// - サーバー生成結果 → sqflite `server_summaries`（llm_summaries とは分離・§5）。
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import 'companion_models.dart';

class CompanionSettings {
  const CompanionSettings({
    required this.baseUrl,
    required this.certSha256,
    required this.deviceToken,
    this.serverId = '',
    this.deviceId = '',
  });

  final String baseUrl;
  final String certSha256;
  final String deviceToken;
  final String serverId;
  final String deviceId;

  bool get isPaired =>
      baseUrl.isNotEmpty && certSha256.isNotEmpty && deviceToken.isNotEmpty;
}

class CompanionRepository {
  CompanionRepository({FlutterSecureStorage? secure, SharedPreferences? prefs})
      : _secure = secure ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            ),
        _prefs = prefs; // ignore: prefer_initializing_formals (secure側にデフォルト注入があるため)

  final FlutterSecureStorage _secure;
  SharedPreferences? _prefs;

  static const _kUrl = 'companion_base_url';
  static const _kCert = 'companion_cert_sha256';
  static const _kToken = 'companion_device_token';
  static const _kServerId = 'companion_server_id';
  static const _kDeviceId = 'companion_device_id';
  static const _pendingPrefix = 'companion_pending_';

  Future<CompanionSettings?> loadSettings() async {
    try {
      final url = await _secure.read(key: _kUrl) ?? '';
      final cert = await _secure.read(key: _kCert) ?? '';
      final token = await _secure.read(key: _kToken) ?? '';
      if (url.isEmpty || cert.isEmpty || token.isEmpty) return null;
      return CompanionSettings(
        baseUrl: url,
        certSha256: cert,
        deviceToken: token,
        serverId: await _secure.read(key: _kServerId) ?? '',
        deviceId: await _secure.read(key: _kDeviceId) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSettings(CompanionSettings s) async {
    await _secure.write(key: _kUrl, value: s.baseUrl);
    await _secure.write(key: _kCert, value: s.certSha256);
    await _secure.write(key: _kToken, value: s.deviceToken);
    await _secure.write(key: _kServerId, value: s.serverId);
    await _secure.write(key: _kDeviceId, value: s.deviceId);
  }

  Future<void> clearSettings() async {
    for (final k in [_kUrl, _kCert, _kToken, _kServerId, _kDeviceId]) {
      await _secure.delete(key: k);
    }
  }

  // ---- 未完了ジョブ（秘密ではないので prefs でよい） ----

  SharedPreferences get _p {
    final p = _prefs;
    if (p == null) {
      throw StateError('CompanionRepository: prefs 未設定（initPrefs を先に呼ぶ）');
    }
    return p;
  }

  Future<void> initPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  Future<void> savePendingJob(
      int workId, int jobId, String clientRequestId) async {
    await _p.setString(
      '$_pendingPrefix$workId',
      jsonEncode({'job_id': jobId, 'crid': clientRequestId, 'work_id': workId}),
    );
  }

  Future<({int jobId, String clientRequestId})?> loadPendingJob(int workId) async {
    final raw = _p.getString('$_pendingPrefix$workId');
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw);
      if (m is Map && m['job_id'] is int && m['crid'] is String) {
        return (jobId: m['job_id'] as int, clientRequestId: m['crid'] as String);
      }
    } catch (_) {}
    return null;
  }

  Future<void> clearPendingJob(int workId) async {
    await _p.remove('$_pendingPrefix$workId');
  }

  /// 再起動後リストア用の全未完了ジョブ。
  Future<List<({int workId, int jobId})>> listAllPendingJobs() {
    final out = <({int workId, int jobId})>[];
    for (final key in _p.getKeys().where((k) => k.startsWith(_pendingPrefix))) {
      final raw = _p.getString(key);
      if (raw == null) continue;
      try {
        final m = jsonDecode(raw);
        if (m is Map && m['job_id'] is int && m['work_id'] is int) {
          out.add((workId: m['work_id'] as int, jobId: m['job_id'] as int));
        }
      } catch (_) {}
    }
    return Future.value(out);
  }

  // ---- サーバー生成結果（server_summaries テーブルへ LAN 取得分のみ保存） ----

  Future<void> saveServerResult(
    CompanionResult r, {
    String? serverId,
    int? jobId,
  }) async {
    final db = await DatabaseService().database;
    await db.insert(
      'server_summaries',
      {
        'server_id': serverId,
        'job_id': jobId,
        'work_id': r.workId,
        'model_id': r.modelId,
        'model_artifact_sha256': r.modelArtifactSha256,
        'prompt_version': r.promptVersion,
        'source_fingerprint': r.sourceFingerprint,
        'synopsis': r.synopsis,
        'spoiler_free_intro': r.spoilerFreeIntro,
        'suggested_tags_json': jsonEncode(r.suggestedTags),
        'copy_warning': r.copyWarning ? 1 : 0,
        'generation_ms': r.generationMs,
        'generated_at': r.generatedAt,
        'fetched_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<CompanionResult?> loadServerResultForWork(int workId) async {
    final db = await DatabaseService().database;
    final rows = await db.query(
      'server_summaries',
      where: 'work_id = ?',
      whereArgs: [workId],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _resultFromRow(rows.first);
  }

  static CompanionResult? _resultFromRow(Map<String, Object?> row) {
    try {
      final tags = (row['suggested_tags_json'] as String?) == null
          ? <String>[]
          : (jsonDecode(row['suggested_tags_json'] as String) as List).cast<String>();
      return CompanionResult.fromRow(
        workId: row['work_id'] as int,
        modelId: row['model_id'] as String,
        artifactSha: (row['model_artifact_sha256'] ?? '') as String,
        promptVersion: row['prompt_version'] as int,
        fingerprint: row['source_fingerprint'] as String,
        synopsis: row['synopsis'] as String,
        intro: (row['spoiler_free_intro'] ?? '') as String,
        tags: tags,
        copyWarning: row['copy_warning'] == 1,
        generationMs: (row['generation_ms'] ?? 0) as int,
        generatedAt: (row['generated_at'] ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }
}
