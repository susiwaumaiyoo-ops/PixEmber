// 10-B1: Companion データモデルの §5 検証・状態マシン・パースのテスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/companion/companion_models.dart';

void main() {
  group('companionJobStageLabel', () {
    test('状態ごとの日本語ラベル', () {
      expect(companionJobStageLabel('queued'), '待機中');
      expect(companionJobStageLabel('fetching'), '本文を取得中');
      expect(companionJobStageLabel('loading'), '本文を解析中');
      expect(companionJobStageLabel('reducing'), '統合中');
      expect(companionJobStageLabel('saving'), '保存中');
      expect(companionJobStageLabel('cancel_requested'), 'キャンセル処理中');
      expect(companionJobStageLabel('completed'), '完了');
      expect(companionJobStageLabel('cancelled'), 'キャンセル済み');
      expect(companionJobStageLabel('failed'), '失敗');
    });

    test('mapping は chunk 進捗を含む', () {
      // total が 0（または未指定）なら進捗数字を付けない。
      expect(companionJobStageLabel('mapping'), 'チャンク解析中');
      expect(companionJobStageLabel('mapping', done: 0, total: 0), 'チャンク解析中');
      expect(
        companionJobStageLabel('mapping', done: 0, total: 5),
        'チャンク解析中（0/5）',
      );
      expect(
        companionJobStageLabel('mapping', done: 3, total: 5),
        'チャンク解析中（3/5）',
      );
    });

    test('未知の状態はそのまま返す（前方互換）', () {
      expect(companionJobStageLabel('some_future_state'), 'some_future_state');
    });
  });

  group('CompanionResult.tryParse', () {
    test('正常ペイロードを検証してパースする', () {
      final r = CompanionResult.tryParse({
        'work_id': 12345,
        'model_id': 'qwen2.5-3b',
        'model_artifact_sha256': 'abc123def456',
        'prompt_version': 3,
        'source_fingerprint': 'fp-abc',
        'generated_at': '2026-09-15T12:00:00Z',
        'synopsis': 'あらすじ本文',
        'spoiler_free_intro': 'ネタバレなし紹介',
        'suggested_tags': ['百合', ' ', '学園', ''],
        'copy_warning': true,
        'generation_ms': 4500,
        'model_file_hash': 'model.gguf:1024:123',
        'mode': 'map-reduce',
      });
      expect(r, isNotNull);
      expect(r!.workId, 12345);
      expect(r.modelId, 'qwen2.5-3b');
      expect(r.promptVersion, 3);
      expect(r.synopsis, 'あらすじ本文');
      expect(r.spoilerFreeIntro, 'ネタバレなし紹介');
      // §5: 空文字・空白のみのタグは除外する。
      expect(r.suggestedTags, ['百合', '学園']);
      expect(r.copyWarning, isTrue);
      expect(r.generationMs, 4500);
      expect(r.modelFileHash, 'model.gguf:1024:123');
      expect(r.mode, 'map-reduce');
    });

    test('copy_warning/generation_ms 省略時は既定値', () {
      final r = CompanionResult.tryParse({
        'work_id': 1,
        'model_id': 'm',
        'model_artifact_sha256': 'a1',
        'prompt_version': 1,
        'source_fingerprint': 'f1',
        'generated_at': '2026-09-15T12:00:00Z',
        'synopsis': 's',
        'spoiler_free_intro': 'i',
      });
      expect(r, isNotNull);
      expect(r!.copyWarning, isFalse);
      expect(r.generationMs, 0);
      expect(r.modelFileHash, isNull);
      expect(r.mode, isNull);
    });

    test('必須フィールド欠落は null（§5 検証）', () {
      final base = <String, dynamic>{
        'work_id': 1,
        'model_id': 'm',
        'model_artifact_sha256': 'a1',
        'prompt_version': 1,
        'source_fingerprint': 'f1',
        'generated_at': '2026-09-15T12:00:00Z',
        'synopsis': 's',
        'spoiler_free_intro': 'i',
      };
      for (final key in [
        'work_id',
        'model_id',
        'model_artifact_sha256',
        'prompt_version',
        'source_fingerprint',
        'generated_at',
        'synopsis',
        'spoiler_free_intro',
      ]) {
        final broken = Map<String, dynamic>.from(base)..remove(key);
        expect(CompanionResult.tryParse(broken), isNull, reason: '$key 欠落');
      }
      expect(CompanionResult.tryParse(null), isNull);
      // synopsis が文字列でない。
      expect(
        CompanionResult.tryParse(
          Map<String, dynamic>.from(base)..['synopsis'] = 5,
        ),
        isNull,
      );
    });

    test('サイズ上限超過は null（§5 検証）', () {
      final base = <String, dynamic>{
        'work_id': 1,
        'model_id': 'm',
        'model_artifact_sha256': 'a1',
        'prompt_version': 1,
        'source_fingerprint': 'f1',
        'generated_at': '2026-09-15T12:00:00Z',
        'synopsis': 's',
        'spoiler_free_intro': 'i',
      };
      expect(
        CompanionResult.tryParse(
          Map<String, dynamic>.from(base)
            ..['synopsis'] = 'あ' * (kMaxSynopsisChars + 1),
        ),
        isNull,
      );
      expect(
        CompanionResult.tryParse(
          Map<String, dynamic>.from(base)
            ..['spoiler_free_intro'] = 'あ' * (kMaxIntroChars + 1),
        ),
        isNull,
      );
      expect(
        CompanionResult.tryParse(
          Map<String, dynamic>.from(base)
            ..['model_artifact_sha256'] = 'a' * (kMaxShaHex + 1),
        ),
        isNull,
      );
      expect(
        CompanionResult.tryParse(
          Map<String, dynamic>.from(base)
            ..['source_fingerprint'] = 'a' * (kMaxShaHex + 1),
        ),
        isNull,
      );
    });

    test('タグは kMaxTags 件に切り詰める', () {
      final tags = List<String>.generate(kMaxTags + 20, (i) => 'tag$i');
      final r = CompanionResult.tryParse({
        'work_id': 1,
        'model_id': 'm',
        'model_artifact_sha256': 'a1',
        'prompt_version': 1,
        'source_fingerprint': 'f1',
        'generated_at': '2026-09-15T12:00:00Z',
        'synopsis': 's',
        'spoiler_free_intro': 'i',
        'suggested_tags': tags,
      });
      expect(r, isNotNull);
      expect(r!.suggestedTags.length, kMaxTags);
      expect(r.suggestedTags.first, 'tag0');
    });
  });

  group('CompanionJob.tryParse', () {
    Map<String, dynamic> baseJob() => {
      'job_id': 42,
      'client_request_id': 'and-1-1-1',
      'work_id': 111,
      'state': 'queued',
      'chunks_done': 0,
      'chunks_total': 0,
      'created_at': '2026-09-15T10:00:00Z',
      'updated_at': '2026-09-15T10:00:00Z',
    };

    test('基本フィールドと chunk 進捗', () {
      final j = CompanionJob.tryParse(
        Map<String, dynamic>.from(baseJob())
          ..['state'] = 'mapping'
          ..['chunks_done'] = 3
          ..['chunks_total'] = 5
          ..['stage'] = 'map'
          ..['error'] = null
          ..['summary_id'] = 7
          ..['overwrite'] = true,
      )!;
      expect(j.jobId, 42);
      expect(j.clientRequestId, 'and-1-1-1');
      expect(j.workId, 111);
      expect(j.state, 'mapping');
      expect(j.stage, 'map'); // 非空の stage はそのまま保持
      expect(j.error, isNull); // 空文字/null は null に正規化
      expect(j.chunksDone, 3);
      expect(j.chunksTotal, 5);
      expect(j.summaryId, 7);
      expect(j.overwrite, isTrue);
      expect(j.isTerminal, isFalse);
      expect(j.isCompleted, isFalse);
    });

    test('未知の state は queued に丸める', () {
      final j = CompanionJob.tryParse(
        Map<String, dynamic>.from(baseJob())..['state'] = 'some_future_state',
      )!;
      expect(j.state, 'queued');
    });

    test('終端状態の判定', () {
      for (final s in ['completed', 'cancelled', 'failed']) {
        final j = CompanionJob.tryParse(
          Map<String, dynamic>.from(baseJob())..['state'] = s,
        )!;
        expect(j.isTerminal, isTrue, reason: s);
      }
      for (final s in ['queued', 'cancel_requested', 'saving']) {
        final j = CompanionJob.tryParse(
          Map<String, dynamic>.from(baseJob())..['state'] = s,
        )!;
        expect(j.isTerminal, isFalse, reason: s);
      }
      final done = CompanionJob.tryParse(
        Map<String, dynamic>.from(baseJob())..['state'] = 'completed',
      )!;
      expect(done.isCompleted, isTrue);
      expect(done.isTerminal, isTrue);
    });

    test('completed 時は result ネストを検証する', () {
      final j = CompanionJob.tryParse(
        Map<String, dynamic>.from(baseJob())
          ..['state'] = 'completed'
          ..['result'] = {
            'work_id': 111,
            'model_id': 'm',
            'model_artifact_sha256': 'a1',
            'prompt_version': 1,
            'source_fingerprint': 'f1',
            'generated_at': '2026-09-15T12:00:00Z',
            'synopsis': 'srv-あらすじ',
            'spoiler_free_intro': 'srv-紹介',
            'suggested_tags': ['tag1', 'tag2'],
            'copy_warning': true,
            'generation_ms': 9000,
            'mode': 'map-reduce',
          },
      )!;
      expect(j.result, isNotNull);
      expect(j.result!.synopsis, 'srv-あらすじ');
      expect(j.result!.suggestedTags, ['tag1', 'tag2']);
      expect(j.result!.mode, 'map-reduce');
    });

    test('completed でも result が不正なら result は null', () {
      final j = CompanionJob.tryParse(
        Map<String, dynamic>.from(baseJob())
          ..['state'] = 'completed'
          ..['result'] = {'work_id': 111}, // 必須欠落
      )!;
      expect(j.result, isNull);
    });

    test('必須フィールド欠落は null', () {
      final base = baseJob();
      for (final key in ['job_id', 'work_id', 'client_request_id', 'state']) {
        final broken = Map<String, dynamic>.from(base)..remove(key);
        expect(CompanionJob.tryParse(broken), isNull, reason: '$key 欠落');
      }
      expect(CompanionJob.tryParse(null), isNull);
      // created_at/updated_at は省略可能（空文字許容）。
      final noTs = Map<String, dynamic>.from(base)
        ..remove('created_at')
        ..remove('updated_at');
      expect(CompanionJob.tryParse(noTs), isNotNull);
    });
  });

  group('CompanionStatus.fromJson', () {
    test('必要なものだけ型化し未知キーは無視する', () {
      final s = CompanionStatus.fromJson({
        'ok': true,
        'stage': 'idle',
        'auto_enabled': true,
        'pixiv_auth': 'ok',
        'generated_today': 3,
        'max_per_day': 10,
        'jobs_active': 1,
        'manual_today': 2,
        'manual_max_per_day': 10,
        'pairing_window_open': true,
        'version': '0.10-b1',
        'server_id': 'srv-1',
        'unknown_future_key': 'ignored',
      });
      expect(s.stage, 'idle');
      expect(s.autoEnabled, isTrue);
      expect(s.pixivAuth, 'ok');
      expect(s.generatedToday, 3);
      expect(s.jobsActive, 1);
      expect(s.manualToday, 2);
      expect(s.pairingWindowOpen, isTrue);
      expect(s.version, '0.10-b1');
      expect(s.serverId, 'srv-1');
      expect(s.raw['unknown_future_key'], 'ignored');
    });

    test('欠落時は null', () {
      final s = CompanionStatus.fromJson({'ok': true});
      expect(s.stage, isNull);
      expect(s.autoEnabled, isNull);
      expect(s.generatedToday, isNull);
      expect(s.pairingWindowOpen, isNull);
    });
  });

  group('CompanionConfig.fromJson', () {
    test('config ネストを取り出す', () {
      final c = CompanionConfig.fromJson({
        'ok': true,
        'config': {
          'enabled': true,
          'tags': ['百合', '学園'],
          'max_per_day': 10,
          'interval_seconds': 600,
          'active_hours': '22-06',
          'settings_file': '/tmp/s.json',
        },
      });
      expect(c.enabled, isTrue);
      expect(c.tags, ['百合', '学園']);
      expect(c.maxPerDay, 10);
      expect(c.intervalSeconds, 600);
      expect(c.activeHours, '22-06');
      expect(c.raw['settings_file'], '/tmp/s.json');
    });

    test('config が無くても壊れない', () {
      final c = CompanionConfig.fromJson({'ok': true});
      expect(c.enabled, isNull);
      expect(c.tags, isEmpty);
      expect(c.maxPerDay, isNull);
    });

    test('tags の非 String 要素は除外する', () {
      final c = CompanionConfig.fromJson({
        'ok': true,
        'config': {
          'tags': ['百合', 7, null, '学園'],
        },
      });
      expect(c.tags, ['百合', '学園']);
    });
  });

  group('CompanionSummaryItem.tryParse', () {
    test('正常/不正', () {
      final ok = CompanionSummaryItem.tryParse({
        'id': 5,
        'work_id': 999,
        'model_id': 'm',
        'synopsis': 'あらすじ',
        'generated_at': '2026-09-01T00:00:00Z',
      });
      expect(ok, isNotNull);
      expect(ok!.id, 5);
      expect(ok.workId, 999);
      expect(ok.synopsis, 'あらすじ');

      expect(
        CompanionSummaryItem.tryParse({
          'id': 5,
          'work_id': 999,
          'model_id': 'm',
        }),
        isNull,
      ); // synopsis 欠落
      expect(
        CompanionSummaryItem.tryParse({
          'work_id': 999,
          'model_id': 'm',
          'synopsis': 'x',
        }),
        isNull,
      ); // id 欠落
    });
  });
}
