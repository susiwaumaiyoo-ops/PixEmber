// 10-B1: PC Companion LAN API のデータモデル（Android 側）。
//
// 契約の正は server/docs/PHASE10_B1_API.md とサーバ実コード（lan_api.py / job_store.py）。
// 未知フィールドは無視（前方互換）、必須欠落は null/例外で弾く。
import 'package:flutter/foundation.dart';

/// §5 結果ペイロードの検証上限。
const int kMaxSynopsisChars = 20000;
const int kMaxIntroChars = 20000;
const int kMaxTags = 40;
const int kMaxShaHex = 128;

/// job の非終端/終端状態（§3-A 状態機械と一致させる）。
const Set<String> kJobTerminalStates = {'completed', 'cancelled', 'failed'};
const Set<String> kJobKnownStates = {
  'queued',
  'fetching',
  'loading',
  'mapping',
  'reducing',
  'saving',
  'completed',
  'cancel_requested',
  'cancelled',
  'failed',
};

/// 状態 → 日本語ラベル（4-B 進捗表示「待機・取得・チャンク解析・統合・保存」）。
String companionJobStageLabel(String state, {int done = 0, int total = 0}) {
  switch (state) {
    case 'queued':
      return '待機中';
    case 'fetching':
      return '本文を取得中';
    case 'loading':
      return '本文を解析中';
    case 'mapping':
      return total > 0 ? 'チャンク解析中（$done/$total）' : 'チャンク解析中';
    case 'reducing':
      return '統合中';
    case 'saving':
      return '保存中';
    case 'cancel_requested':
      return 'キャンセル処理中';
    case 'completed':
      return '完了';
    case 'cancelled':
      return 'キャンセル済み';
    case 'failed':
      return '失敗';
    default:
      return state;
  }
}

  /// §5 検証済みサーバー生成結果。
  @immutable
  class CompanionResult {
  const CompanionResult._({
    required this.workId,
    required this.modelId,
    required this.modelArtifactSha256,
    required this.promptVersion,
    required this.sourceFingerprint,
    required this.generatedAt,
    required this.synopsis,
    required this.spoilerFreeIntro,
    required this.suggestedTags,
    required this.copyWarning,
    required this.generationMs,
    this.modelFileHash,
    this.mode,
  });

  /// ローカルDB（server_summaries）リストア用。保存済みの検証済みデータのため再検証しない。
  factory CompanionResult.fromRow({
    required int workId,
    required String modelId,
    required String artifactSha,
    required int promptVersion,
    required String fingerprint,
    required String synopsis,
    required String intro,
    required List<String> tags,
    required bool copyWarning,
    required int generationMs,
    required String generatedAt,
  }) =>
      CompanionResult._(
        workId: workId,
        modelId: modelId,
        modelArtifactSha256: artifactSha,
        promptVersion: promptVersion,
        sourceFingerprint: fingerprint,
        generatedAt: generatedAt,
        synopsis: synopsis,
        spoilerFreeIntro: intro,
        suggestedTags: tags,
        copyWarning: copyWarning,
        generationMs: generationMs,
      );

  final int workId;
  final String modelId;
  final String modelArtifactSha256;
  final int promptVersion;
  final String sourceFingerprint;
  final String generatedAt;
  final String synopsis;
  final String spoilerFreeIntro;
  final List<String> suggestedTags;
  final bool copyWarning;
  final int generationMs;

  /// PC 環境値（basename:size:mtime）。他端末へ移植禁止 — 表示専用。
  final String? modelFileHash;
  final String? mode;

  /// サーバ result を §5 検証しつつパース。不正なら null。
  static CompanionResult? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final workId = _asInt(json['work_id']);
    final modelId = _asNonEmptyString(json['model_id']);
    final artifact = _asNonEmptyString(json['model_artifact_sha256']);
    final promptVersion = _asInt(json['prompt_version']);
    final fingerprint = _asNonEmptyString(json['source_fingerprint']);
    final generatedAt = _asNonEmptyString(json['generated_at']);
    final synopsis = json['synopsis'];
    final intro = json['spoiler_free_intro'];
    if (workId == null ||
        modelId == null ||
        artifact == null ||
        promptVersion == null ||
        fingerprint == null ||
        generatedAt == null ||
        synopsis is! String ||
        intro is! String) {
      return null;
    }
    if (synopsis.length > kMaxSynopsisChars || intro.length > kMaxIntroChars) {
      return null;
    }
    if (artifact.length > kMaxShaHex || fingerprint.length > kMaxShaHex) {
      return null;
    }
    final rawTags = json['suggested_tags'];
    final tags = <String>[
      if (rawTags is List)
        for (final t in rawTags.take(kMaxTags))
          if (t is String && t.trim().isNotEmpty) t.trim(),
    ];
    return CompanionResult._(
      workId: workId,
      modelId: modelId,
      modelArtifactSha256: artifact,
      promptVersion: promptVersion,
      sourceFingerprint: fingerprint,
      generatedAt: generatedAt,
      synopsis: synopsis,
      spoilerFreeIntro: intro,
      suggestedTags: tags,
      copyWarning: json['copy_warning'] == true,
      generationMs: _asInt(json['generation_ms']) ?? 0,
      modelFileHash: _asNonEmptyString(json['model_file_hash']),
      mode: _asNonEmptyString(json['mode']),
    );
  }
}

/// 単発要約ジョブ（§3-A）。result は completed 時のみ付随。
@immutable
class CompanionJob {
  const CompanionJob({
    required this.jobId,
    required this.clientRequestId,
    required this.workId,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.stage,
    this.chunksDone = 0,
    this.chunksTotal = 0,
    this.error,
    this.summaryId,
    this.overwrite = false,
    this.result,
  });

  final int jobId;
  final String clientRequestId;
  final int workId;
  final String state;
  final String? stage;
  final int chunksDone;
  final int chunksTotal;
  final String? error;
  final int? summaryId;
  final bool overwrite;
  final String createdAt;
  final String updatedAt;
  final CompanionResult? result;

  bool get isTerminal => kJobTerminalStates.contains(state);
  bool get isCompleted => state == 'completed';

  static CompanionJob? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final jobId = _asInt(json['job_id']);
    final workId = _asInt(json['work_id']);
    final crid = _asNonEmptyString(json['client_request_id']);
    final state = _asNonEmptyString(json['state']);
    final createdAt = _asNonEmptyString(json['created_at']) ?? '';
    final updatedAt = _asNonEmptyString(json['updated_at']) ?? '';
    if (jobId == null || workId == null || crid == null || state == null) {
      return null;
    }
    return CompanionJob(
      jobId: jobId,
      clientRequestId: crid,
      workId: workId,
      state: kJobKnownStates.contains(state) ? state : 'queued',
      stage: _asNonEmptyString(json['stage']),
      chunksDone: _asInt(json['chunks_done']) ?? 0,
      chunksTotal: _asInt(json['chunks_total']) ?? 0,
      error: _asNonEmptyString(json['error']),
      summaryId: _asInt(json['summary_id']),
      overwrite: json['overwrite'] == true,
      createdAt: createdAt,
      updatedAt: updatedAt,
      result: CompanionResult.tryParse(
        json['result'] is Map ? Map<String, dynamic>.from(json['result'] as Map) : null,
      ),
    );
  }
}

/// GET /status（runner.status_snapshot）。未知キーは無視、必要なものだけ型化する。
@immutable
class CompanionStatus {
  const CompanionStatus({
    required this.raw,
    this.stage,
    this.autoEnabled,
    this.pixivAuth,
    this.generatedToday,
    this.maxPerDay,
    this.jobsActive,
    this.manualToday,
    this.manualMaxPerDay,
    this.pairingWindowOpen,
    this.version,
    this.serverId,
  });

  final Map<String, dynamic> raw;
  final String? stage;
  final bool? autoEnabled;
  final String? pixivAuth;
  final int? generatedToday;
  final int? maxPerDay;
  final int? jobsActive;
  final int? manualToday;
  final int? manualMaxPerDay;
  final bool? pairingWindowOpen;
  final String? version;
  final String? serverId;

  static CompanionStatus fromJson(Map<String, dynamic> j) => CompanionStatus(
        raw: j,
        stage: _asNonEmptyString(j['stage']),
        autoEnabled: j['auto_enabled'] is bool ? j['auto_enabled'] as bool : null,
        pixivAuth: _asNonEmptyString(j['pixiv_auth']),
        generatedToday: _asInt(j['generated_today']),
        maxPerDay: _asInt(j['max_per_day']),
        jobsActive: _asInt(j['jobs_active']),
        manualToday: _asInt(j['manual_today']),
        manualMaxPerDay: _asInt(j['manual_max_per_day']),
        pairingWindowOpen:
            j['pairing_window_open'] is bool ? j['pairing_window_open'] as bool : null,
        version: _asNonEmptyString(j['version']),
        serverId: _asNonEmptyString(j['server_id']),
      );
}

/// GET /config → {ok, config:{...}} の config 部。
@immutable
class CompanionConfig {
  const CompanionConfig({
    required this.raw,
    this.enabled,
    this.tags = const [],
    this.maxPerDay,
    this.intervalSeconds,
    this.activeHours,
  });

  final Map<String, dynamic> raw;
  final bool? enabled;
  final List<String> tags;
  final int? maxPerDay;
  final int? intervalSeconds;
  final String? activeHours;

  static CompanionConfig fromJson(Map<String, dynamic> j) {
    final raw = j['config'] is Map
        ? Map<String, dynamic>.from(j['config'] as Map)
        : <String, dynamic>{};
    final tagsRaw = raw['tags'];
    return CompanionConfig(
      raw: raw,
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : null,
      tags: <String>[
        if (tagsRaw is List) for (final t in tagsRaw) if (t is String) t,
      ],
      maxPerDay: _asInt(raw['max_per_day']),
      intervalSeconds: _asInt(raw['interval_seconds']),
      activeHours: _asNonEmptyString(raw['active_hours']),
    );
  }
}

/// GET /summaries の 1 件（保存済み要約一覧・4-A）。
@immutable
class CompanionSummaryItem {
  const CompanionSummaryItem({
    required this.id,
    required this.workId,
    required this.modelId,
    required this.synopsis,
    required this.generatedAt,
  });

  final int id;
  final int workId;
  final String modelId;
  final String synopsis;
  final String generatedAt;

  static CompanionSummaryItem? tryParse(Map<String, dynamic> j) {
    final id = _asInt(j['id']);
    final workId = _asInt(j['work_id']);
    final modelId = _asNonEmptyString(j['model_id']);
    final synopsis = j['synopsis'];
    if (id == null || workId == null || modelId == null || synopsis is! String) {
      return null;
    }
    return CompanionSummaryItem(
      id: id,
      workId: workId,
      modelId: modelId,
      synopsis: synopsis,
      generatedAt: _asNonEmptyString(j['generated_at']) ?? '',
    );
  }
}

int? _asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

String? _asNonEmptyString(Object? v) {
  if (v is String && v.trim().isNotEmpty) return v;
  return null;
}
