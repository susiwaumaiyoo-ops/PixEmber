// 10-B1: Companion サービス（ペアリング/状態/設定/ジョブ）。
//
// - 設定変更は POST /config 後に必ず GET /config で実効値を返す（楽観UI禁止・§4-A）。
// - ジョブ作成は client_request_id 冪等。送信結果不明時は同じ crid で再送→
//   同一 job へ再アタッチ（「確認中」表示は UI 側。§4-C）。
// - ポーリングは画面表示中のみにて UI 側タイマーが本サービスの fetchJob を呼ぶ。
//   サーバ側は切断をキャンセル扱いしない（進み続ける）。
import 'dart:math';

import 'companion_models.dart';
import 'companion_repository.dart';
import 'companion_transport.dart';

/// API 側の種別エラー（HTTP 2xx 未満で error コードあり）。
class CompanionApiException implements Exception {
  CompanionApiException(this.code, [this.statusCode]);
  final String code;
  final int? statusCode;
  @override
  String toString() => 'CompanionApiException($code, http=$statusCode)';
}

/// 接続リンク状態（4-A 表示: 接続中/切断中/認証失効/証明書不一致）。
enum CompanionLink { none, connected, disconnected, authExpired, certMismatch }

String companionLinkLabel(CompanionLink l) {
  switch (l) {
    case CompanionLink.none:
      return '未登録';
    case CompanionLink.connected:
      return '接続中';
    case CompanionLink.disconnected:
      return '切断中';
    case CompanionLink.authExpired:
      return '認証失効';
    case CompanionLink.certMismatch:
      return '証明書不一致';
  }
}

class CompanionService {
  CompanionService({CompanionRepository? repository, this.transportFactory})
    : repo = repository ?? CompanionRepository();

  final CompanionRepository repo;

  /// テスト用にトランスポートを差し替え可能（未指定なら本物の HttpClient 版）。
  final CompanionTransport Function(CompanionSettings)? transportFactory;

  CompanionSettings? _settings;
  CompanionLink link = CompanionLink.none;

  bool get isPaired => _settings?.isPaired ?? false;

  /// 起動時: secure storage から設定をリストア（まだ通信はしない）。
  Future<bool> init() async {
    await repo.initPrefs();
    _settings = await repo.loadSettings();
    link = _settings == null ? CompanionLink.none : CompanionLink.connected;
    return _settings != null;
  }

  Future<void> unregister() async {
    await repo.clearSettings();
    _settings = null;
    link = CompanionLink.none;
  }

  CompanionTransport _transportFor(CompanionSettings s) =>
      transportFactory?.call(s) ??
      CompanionTransport(
        baseUrl: s.baseUrl,
        pinnedCertSha256: s.certSha256,
        deviceToken: s.deviceToken,
      );

  CompanionTransport get _t {
    final s = _settings;
    if (s == null || !s.isPaired) {
      throw CompanionApiException('not_paired');
    }
    return _transportFor(s);
  }

  /// 例外からリンク状態を分類して反映する。
  void _classifyAndRethrow(Object e) {
    if (e is CompanionAuthException) {
      link = e.isRevoked
          ? CompanionLink.authExpired
          : CompanionLink.disconnected;
    } else if (e is CompanionCertException) {
      link = CompanionLink.certMismatch;
    } else if (e is CompanionNetworkException) {
      link = CompanionLink.disconnected;
    }
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      final out = await body();
      link = CompanionLink.connected;
      return out;
    } catch (e) {
      _classifyAndRethrow(e);
      rethrow;
    }
  }

  // ---- ペアリング（§2-B: pin は PairingInput 経由で事前に受け取る・TOFUなし） ----

  Future<void> pair({
    required String baseUrl,
    required String certSha256,
    required String code,
    required String deviceName,
  }) async {
    final t = CompanionTransport(
      baseUrl: baseUrl.trim(),
      pinnedCertSha256: certSha256.trim().toLowerCase(),
    );
    final CompanionResponse resp;
    try {
      resp = await t.post('/pair', {
        'code': code.trim().toUpperCase(),
        'device_name': deviceName.trim(),
      }, auth: false);
    } catch (e) {
      _classifyAndRethrow(e);
      rethrow;
    }
    final token = resp.json['device_token'];
    if (!resp.is2xx || token is! String || token.isEmpty) {
      throw CompanionApiException(resp.error ?? 'pair_failed', resp.statusCode);
    }
    await repo.saveSettings(
      CompanionSettings(
        baseUrl: baseUrl.trim(),
        certSha256: certSha256.trim().toLowerCase(),
        deviceToken: token,
        serverId: resp.json['server_id'] is String
            ? resp.json['server_id'] as String
            : '',
        deviceId: resp.json['device_id'] is String
            ? resp.json['device_id'] as String
            : '',
      ),
    );
    _settings = await repo.loadSettings();
    link = CompanionLink.connected;
  }

  // ---- 状態・設定 ----

  Future<CompanionStatus> status() => _guard(() async {
    final r = await _t.get('/status');
    return CompanionStatus.fromJson(r.json);
  });

  Future<CompanionConfig> getConfig() => _guard(() async {
    final r = await _t.get('/config');
    return CompanionConfig.fromJson(r.json);
  });

  /// POST → GET 確認。失敗時は CompanionApiException(error code)。
  Future<CompanionConfig> postConfig(Map<String, dynamic> patch) =>
      _guard(() async {
        final r = await _t.post('/config', patch);
        if (!r.is2xx) {
          throw CompanionApiException(r.error ?? 'config_failed', r.statusCode);
        }
        return getConfig();
      });

  Future<List<Map<String, dynamic>>> queue() => _guard(() async {
    final r = await _t.get('/queue');
    final q = r.json['queue'];
    return q is List
        ? q.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
  });

  // ---- ジョブ（§3-A） ----

  static String _newCrid(int workId) {
    final rnd = Random().nextInt(0x7fffffff);
    return 'and-$workId-${DateTime.now().millisecondsSinceEpoch}-$rnd';
  }

  /// 単発要約依頼。未完了 pending があれば同じ crid で再送（冪等再アタッチ）。
  Future<({int jobId, String clientRequestId, CompanionJob job})> createJob(
    int workId, {
    bool overwrite = false,
  }) => _guard(() async {
    final pending = await repo.loadPendingJob(workId);
    final crid = pending?.clientRequestId ?? _newCrid(workId);
    final r = await _t.post('/jobs', {
      'work_id': workId,
      'client_request_id': crid,
      'options': {'overwrite': overwrite},
    });
    if (!r.is2xx) {
      throw CompanionApiException(r.error ?? 'job_create_failed', r.statusCode);
    }
    final job = CompanionJob.tryParse(
      r.json['job'] is Map
          ? Map<String, dynamic>.from(r.json['job'] as Map)
          : null,
    );
    if (job == null) {
      throw CompanionApiException('bad_job_response', r.statusCode);
    }
    await repo.savePendingJob(workId, job.jobId, crid);
    return (jobId: job.jobId, clientRequestId: crid, job: job);
  });

  Future<CompanionJob> fetchJob(int jobId) => _guard(() async {
    final r = await _t.get('/jobs/$jobId');
    if (!r.is2xx) {
      throw CompanionApiException(r.error ?? 'job_fetch_failed', r.statusCode);
    }
    final job = CompanionJob.tryParse(
      r.json['job'] is Map
          ? Map<String, dynamic>.from(r.json['job'] as Map)
          : null,
    );
    if (job == null) {
      throw CompanionApiException('bad_job_response', r.statusCode);
    }
    return job;
  });

  Future<CompanionJob> cancelJob(int jobId) => _guard(() async {
    final r = await _t.post('/jobs/$jobId/cancel', <String, dynamic>{});
    if (!r.is2xx) {
      throw CompanionApiException(r.error ?? 'cancel_failed', r.statusCode);
    }
    final job = CompanionJob.tryParse(
      r.json['job'] is Map
          ? Map<String, dynamic>.from(r.json['job'] as Map)
          : null,
    );
    if (job == null) {
      throw CompanionApiException('bad_job_response', r.statusCode);
    }
    return job;
  });

  /// 終端ジョブなら prefs の pending を掃除する。
  Future<void> settleJob(CompanionJob job) async {
    if (job.isTerminal) {
      await repo.clearPendingJob(job.workId);
    }
  }

  /// §5: 検証済み結果を server_summaries へ保存（llm_summaries とは別テーブル）。
  Future<void> saveResult(CompanionResult result, int jobId) => repo
      .saveServerResult(result, serverId: _settings?.serverId, jobId: jobId);

  // ---- 保存済み要約一覧（4-A） ----

  Future<({List<CompanionSummaryItem> items, String? nextCursor})>
  listSummaries({int limit = 20, String? cursor}) => _guard(() async {
    final q = cursor == null
        ? '/summaries?limit=$limit'
        : '/summaries?limit=$limit&cursor=${Uri.encodeQueryComponent(cursor)}';
    final r = await _t.get(q);
    final raw = r.json['items'];
    final items = <CompanionSummaryItem>[
      if (raw is List)
        for (final e in raw)
          if (e is Map &&
              CompanionSummaryItem.tryParse(Map<String, dynamic>.from(e)) !=
                  null)
            CompanionSummaryItem.tryParse(Map<String, dynamic>.from(e))!,
    ];
    final next = r.json['next_cursor'];
    return (items: items, nextCursor: next is String ? next : null);
  });
}
