// 10-B1: CompanionService のペアリング状態・POST→GET 確認・crid 冪等・
// 例外のリンク分類を、fake トランスポート＋インメモリリポジトリで検証する。
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/companion/companion_models.dart';
import 'package:pixiv_viewer/services/companion/companion_repository.dart';
import 'package:pixiv_viewer/services/companion/companion_service.dart';
import 'package:pixiv_viewer/services/companion/companion_transport.dart';

const CompanionSettings _paired = CompanionSettings(
  baseUrl: 'https://192.168.11.24:8766',
  certSha256: 'abcdef0123456789',
  deviceToken: 'dev-token-1',
  serverId: 'srv-1',
  deviceId: 'dev-1',
);

class _FakeRepository extends CompanionRepository {
  _FakeRepository() : super(secure: const FlutterSecureStorage());

  CompanionSettings? _settings;
  final Map<int, Map<String, Object?>> _pending = {};
  final List<Map<String, Object?>> saved = [];

  @override
  Future<void> initPrefs() async {}

  @override
  Future<CompanionSettings?> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(CompanionSettings s) async => _settings = s;

  @override
  Future<void> clearSettings() async => _settings = null;

  @override
  Future<void> savePendingJob(
    int workId,
    int jobId,
    String clientRequestId,
  ) async {
    _pending[workId] = {'job_id': jobId, 'crid': clientRequestId};
  }

  @override
  Future<({int jobId, String clientRequestId})?> loadPendingJob(
    int workId,
  ) async {
    final m = _pending[workId];
    if (m == null) return null;
    return (jobId: m['job_id'] as int, clientRequestId: m['crid'] as String);
  }

  @override
  Future<void> clearPendingJob(int workId) async {
    _pending.remove(workId);
  }

  @override
  Future<List<({int workId, int jobId})>> listAllPendingJobs() async {
    return [
      for (final e in _pending.entries)
        (workId: e.key, jobId: e.value['job_id'] as int),
    ];
  }

  @override
  Future<void> saveServerResult(
    CompanionResult r, {
    String? serverId,
    int? jobId,
  }) async {
    saved.add({'result': r, 'serverId': serverId, 'jobId': jobId});
  }

  @override
  Future<CompanionResult?> loadServerResultForWork(int workId) async => null;
}

/// ルーター: メソッド+パス+ボディから CompanionResponse を作るか、例外を投げる。
class _Router {
  Map<String, dynamic> statusBody = {
    'ok': true,
    'stage': 'idle',
    'auto_enabled': true,
    'generated_today': 2,
    'max_per_day': 10,
    'pixiv_auth': 'ok',
  };

  /// 実効 config（POST で更新→GET で確認される）。
  Map<String, dynamic> config = {
    'enabled': false,
    'tags': ['百合'],
    'max_per_day': 10,
    'interval_seconds': 600,
    'active_hours': '22-06',
  };

  Map<String, dynamic> queueBody = {
    'queue': [
      {'job_id': 7, 'state': 'queued'},
      {'job_id': 8, 'state': 'mapping'},
    ],
  };

  Map<String, dynamic> summariesBody = {
    'items': [
      {
        'id': 1,
        'work_id': 9,
        'model_id': 'm',
        'synopsis': 'srv-あらすじ',
        'generated_at': '2026-09-01T00:00:00Z',
      },
    ],
    'next_cursor': 'cur1',
  };

  /// 認証系エラー（401/503 相当）。null なら投げない。
  String? authError;
  bool certError = false;
  bool netError = false;

  /// POST /config を 2xx 未満で拒否する（サーバ側バリデーション失敗のシミュレート）。
  bool configFail = false;
  String configErrorCode = 'invalid_config';

  /// POST /jobs を 2xx 未満で拒否する（サーバ側バリデーション失敗のシミュレート）。
  bool jobCreateFail = false;
  String jobCreateErrorCode = 'invalid_work_id';

  String? lastCrid;
  String? lastCancelPath;
  final List<String> seenPaths = [];

  final Map<int, Map<String, dynamic>> jobs = {};
  int _nextJobId = 100;
  String? _firstCrid;
  int? _firstJobId;

  CompanionResponse _ok(Map<String, dynamic> body) =>
      CompanionResponse(200, {'ok': true, ...body});

  Map<String, dynamic> _jobJson(
    int id,
    int workId,
    String crid,
    String state,
  ) => {
    'job_id': id,
    'client_request_id': crid,
    'work_id': workId,
    'state': state,
    'chunks_done': 0,
    'chunks_total': 0,
    'created_at': '2026-09-15T10:00:00Z',
    'updated_at': '2026-09-15T10:00:00Z',
  };

  CompanionResponse handle(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) {
    if (certError) throw CompanionCertException('pin 不一致');
    if (netError) throw CompanionNetworkException('接続できません');
    if (authError != null && !path.startsWith('/pair')) {
      throw CompanionAuthException(authError!, statusCode: 401);
    }
    seenPaths.add(path);
    if (method == 'GET' && path == '/status') return _ok(statusBody);
    if (method == 'GET' && path == '/config') return _ok({'config': config});
    if (method == 'POST' && path == '/config') {
      // サーバ側バリデーション失敗のシミュレート: 2xx 未満で error コードを返す。
      if (configFail) {
        return CompanionResponse(400, {'ok': false, 'error': configErrorCode});
      }
      // サーバが実効値に反映した体で、差分を取り込む。
      final patch = body ?? <String, dynamic>{};
      for (final e in patch.entries) {
        if (e.value is List) {
          config[e.key] = (e.value as List).whereType<String>().toList();
        } else {
          config[e.key] = e.value;
        }
      }
      return _ok({});
    }
    if (method == 'GET' && path == '/queue') return _ok(queueBody);
    if (method == 'GET' && path.startsWith('/summaries')) {
      return _ok(summariesBody);
    }
    if (method == 'POST' && path == '/jobs') {
      if (jobCreateFail) {
        return CompanionResponse(400, {
          'ok': false,
          'error': jobCreateErrorCode,
        });
      }
      final wid = body!['work_id'] as int;
      final crid = body['client_request_id'] as String;
      lastCrid = crid;
      // 同一 crid は同じジョブへ冪等再アタッチ。
      if (crid == _firstCrid && _firstJobId != null) {
        return _ok({'job': jobs[_firstJobId]!});
      }
      final id = _nextJobId++;
      _firstCrid = crid;
      _firstJobId = id;
      jobs[id] = _jobJson(id, wid, crid, 'queued');
      return _ok({'job': jobs[id]!});
    }
    if (method == 'GET' && path.startsWith('/jobs/')) {
      final id = int.parse(path.split('/').last);
      return _ok({'job': jobs[id] ?? _jobJson(id, 999, 'x', 'queued')});
    }
    if (method == 'POST' && path.endsWith('/cancel')) {
      lastCancelPath = path;
      final seg = path.split('/');
      final id = int.parse(seg[2]);
      final j = jobs[id];
      if (j != null) j['state'] = 'cancel_requested';
      return _ok({'job': j ?? _jobJson(id, 999, 'x', 'cancel_requested')});
    }
    throw StateError('unrouted $method $path');
  }
}

class _FakeTransport extends CompanionTransport {
  _FakeTransport(this.route)
    : super(baseUrl: 'https://192.168.11.24:8766', pinnedCertSha256: 'ab');
  final CompanionResponse Function(
    String method,
    String path,
    Map<String, dynamic>? body,
  )
  route;

  @override
  Future<CompanionResponse> request(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final b = body is Map ? Map<String, dynamic>.from(body) : null;
    return route(method, path, b);
  }
}

void main() {
  late _FakeRepository repo;
  late _Router router;

  CompanionService makeService() => CompanionService(
    repository: repo,
    transportFactory: (_) => _FakeTransport(router.handle),
  );

  setUp(() {
    repo = _FakeRepository();
    router = _Router();
  });

  group('init / ペアリング状態', () {
    test('未ペア時は false で none', () async {
      final svc = makeService();
      expect(await svc.init(), isFalse);
      expect(svc.isPaired, isFalse);
      expect(svc.link, CompanionLink.none);
    });

    test('登録済み設定をリストア', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      expect(await svc.init(), isTrue);
      expect(svc.isPaired, isTrue);
      expect(svc.link, CompanionLink.connected);
    });

    test('未 init で API を呼ぶと not_paired', () async {
      final svc = makeService();
      expect(
        () => svc.status(),
        throwsA(
          predicate(
            (Object? e) =>
                e is CompanionApiException &&
                e.code == 'not_paired' &&
                e.statusCode == null,
          ),
        ),
      );
    });

    test('unregister でクリア', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      await svc.unregister();
      expect(svc.isPaired, isFalse);
      expect(svc.link, CompanionLink.none);
      expect(repo.loadSettings(), completion(isNull));
    });
  });

  group('状態・設定', () {
    test('status は未知キーを保持して型化', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final s = await svc.status();
      expect(s.stage, 'idle');
      expect(s.autoEnabled, isTrue);
      expect(s.generatedToday, 2);
      expect(s.maxPerDay, 10);
      expect(svc.link, CompanionLink.connected);
    });

    test('getConfig', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final c = await svc.getConfig();
      expect(c.enabled, isFalse);
      expect(c.tags, ['百合']);
      expect(c.activeHours, '22-06');
    });

    test('POST /config 後は GET /config の実効値を返す（楽観UI禁止）', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final c = await svc.postConfig({
        'enabled': true,
        'tags': ['学園', '日常'],
        'max_per_day': 20,
      });
      // サーバ反映後の実効値（POST の Echo ではなく GET の結果）。
      expect(c.enabled, isTrue);
      expect(c.tags, ['学園', '日常']);
      expect(c.maxPerDay, 20);
      expect(router.config['enabled'], isTrue);
      expect(svc.link, CompanionLink.connected);
    });

    test('POST /config が 2xx でなければ例外（実効値不明のまま）', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      // サーバ側バリデーション失敗を 400 でシミュレートする。
      router.configFail = true;
      await expectLater(
        svc.postConfig({'max_per_day': -1}),
        throwsA(
          predicate(
            (Object? e) =>
                e is CompanionApiException &&
                e.code == 'invalid_config' &&
                e.statusCode == 400,
          ),
        ),
      );
      // 失敗時は実効値が変わらない（楽観UI禁止）。
      expect(router.config['max_per_day'], 10);
    });

    test('queue を List<Map> で返す', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final q = await svc.queue();
      expect(q.length, 2);
      expect(q.first['job_id'], 7);
      expect(q.last['state'], 'mapping');
    });
  });

  group('ジョブ（crid 冪等）', () {
    test('createJob で crid 採番し pending 保存', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final out = await svc.createJob(111);
      expect(out.job.jobId, greaterThan(0));
      expect(out.job.workId, 111);
      expect(out.job.state, 'queued');
      expect(out.clientRequestId, startsWith('and-111-'));
      expect(router.lastCrid, out.clientRequestId);
      final pending = await repo.loadPendingJob(111);
      expect(pending, isNotNull);
      expect(pending!.jobId, out.jobId);
      expect(pending.clientRequestId, out.clientRequestId);
    });

    test('同一 workId の再送は同じ crid で同じジョブへ再アタッチ', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final r1 = await svc.createJob(111);
      // 送信結果が不明になった体: pending が残っている。
      final r2 = await svc.createJob(111);
      expect(r2.clientRequestId, r1.clientRequestId);
      expect(r2.jobId, r1.jobId);
      expect(router.lastCrid, r1.clientRequestId);
    });

    test('fetchJob で状態/chunk 進捗を取り直す', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final created = await svc.createJob(222);
      router.jobs[created.jobId]!['state'] = 'mapping';
      router.jobs[created.jobId]!['chunks_done'] = 3;
      router.jobs[created.jobId]!['chunks_total'] = 5;
      final job = await svc.fetchJob(created.jobId);
      expect(job.state, 'mapping');
      expect(job.chunksDone, 3);
      expect(job.chunksTotal, 5);
      expect(job.isTerminal, isFalse);
    });

    test('cancelJob は明示キャンセル API を呼ぶ', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final created = await svc.createJob(333);
      final job = await svc.cancelJob(created.jobId);
      expect(router.lastCancelPath, '/jobs/${created.jobId}/cancel');
      expect(job.state, 'cancel_requested');
      expect(job.isTerminal, isFalse); // 要求直後はまだ終端でない
    });

    test('settleJob: 終端なら pending を掃除、そうでなければ保持', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final created = await svc.createJob(444);
      final running = await svc.fetchJob(created.jobId);
      await svc.settleJob(running);
      expect(await repo.loadPendingJob(444), isNotNull);

      router.jobs[created.jobId]!['state'] = 'completed';
      final done = await svc.fetchJob(created.jobId);
      await svc.settleJob(done);
      expect(await repo.loadPendingJob(444), isNull);
    });

    test('saveResult は server_summaries（repo）へ検証済み結果を保存', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final r = CompanionResult.tryParse({
        'work_id': 555,
        'model_id': 'qwen2.5-3b',
        'model_artifact_sha256': 'a1',
        'prompt_version': 3,
        'source_fingerprint': 'f1',
        'generated_at': '2026-09-15T12:00:00Z',
        'synopsis': 'srv-あらすじ',
        'spoiler_free_intro': 'srv-紹介',
        'suggested_tags': ['百合'],
        'copy_warning': true,
        'generation_ms': 9000,
        'mode': 'map-reduce',
      });
      expect(r, isNotNull);
      await svc.saveResult(r!, 77);
      expect(repo.saved.length, 1);
      expect(repo.saved.last['jobId'], 77);
      expect(repo.saved.last['serverId'], 'srv-1');
      expect((repo.saved.last['result'] as CompanionResult).workId, 555);
    });
  });

  group('保存済み要約一覧', () {
    test('items と next_cursor をパース', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      final out = await svc.listSummaries();
      expect(out.items.length, 1);
      expect(out.items.first.workId, 9);
      expect(out.items.first.synopsis, 'srv-あらすじ');
      expect(out.nextCursor, 'cur1');
    });

    test('cursor 指定でクエリに含める', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      await svc.listSummaries(cursor: 'cur1');
      expect(router.seenPaths.any((p) => p.contains('cursor=cur1')), isTrue);
    });

    test('不正アイテムは除外する', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      router.summariesBody = {
        'items': [
          {'id': 1, 'work_id': 9, 'model_id': 'm', 'synopsis': 'ok'},
          {'id': 2, 'work_id': 10}, // synopsis 欠落
          {'bad': 'row'},
        ],
      };
      final out = await svc.listSummaries();
      expect(out.items.length, 1);
      expect(out.items.first.id, 1);
    });
  });

  group('例外のリンク分類（4-A）', () {
    test('device_revoked は認証失効', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      router.authError = 'device_revoked';
      await expectLater(svc.status(), throwsA(isA<CompanionAuthException>()));
      expect(svc.link, CompanionLink.authExpired);
    });

    test('unauthorized は切断中', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      router.authError = 'unauthorized';
      await expectLater(svc.status(), throwsA(isA<CompanionAuthException>()));
      expect(svc.link, CompanionLink.disconnected);
    });

    test('pairing_required は切断中（再ペアリングが必要）', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      router.authError = 'pairing_required';
      await expectLater(
        svc.getConfig(),
        throwsA(
          predicate(
            (Object? e) => e is CompanionAuthException && e.needsPairing,
          ),
        ),
      );
      expect(svc.link, CompanionLink.disconnected);
    });

    test('証明書不一致は hard fail（certMismatch）', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      router.certError = true;
      await expectLater(svc.status(), throwsA(isA<CompanionCertException>()));
      expect(svc.link, CompanionLink.certMismatch);
    });

    test('ネットワーク断は切断中（ジョブ失敗とは区別）', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      router.netError = true;
      await expectLater(
        svc.status(),
        throwsA(isA<CompanionNetworkException>()),
      );
      expect(svc.link, CompanionLink.disconnected);
    });

    test('API エラー（2xx 未満）は CompanionApiException', () async {
      await repo.saveSettings(_paired);
      final svc = makeService();
      await svc.init();
      // POST /jobs を 400 で拒否する（サーバ側バリデーション失敗）。
      router.jobCreateFail = true;
      await expectLater(
        svc.createJob(666),
        throwsA(
          predicate(
            (Object? e) =>
                e is CompanionApiException &&
                e.code == 'invalid_work_id' &&
                e.statusCode == 400,
          ),
        ),
      );
      // 失敗時は pending を保存しない（次回同じ crid で再送できる）。
      expect(await repo.loadPendingJob(666), isNull);
    });
  });

  group('ラベル', () {
    test('companionLinkLabel', () {
      expect(companionLinkLabel(CompanionLink.none), '未登録');
      expect(companionLinkLabel(CompanionLink.connected), '接続中');
      expect(companionLinkLabel(CompanionLink.disconnected), '切断中');
      expect(companionLinkLabel(CompanionLink.authExpired), '認証失効');
      expect(companionLinkLabel(CompanionLink.certMismatch), '証明書不一致');
    });
  });
}
