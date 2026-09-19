// Phase 9-B2/B2-4+5: AutoSummaryPorts の実サービス結線。
//
// このファイルは FGS TaskHandler 側 FlutterEngine でのみ生成されること。
// UI isolate からは絶対に直接呼ばない（推論所有者の統一）。
// 推論は LlmRunArbiter 経由のみ（手動・自動共通の直列キュー）。
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:battery_plus/battery_plus.dart';

import 'auto_summary_service.dart';
import 'auto_summary_settings.dart';
import 'auto_summary_snapshot.dart';
import 'auto_summary_repository.dart';
import 'database_service.dart';
import 'llm_run_arbiter.dart';
import 'llm_summary_cache_service.dart';
import 'llm_summary_service.dart';
import 'pixiv_api_service.dart';

/// FGS TaskHandler 内で呼ぶ実ポート生成。
///
/// 推論は [arbiter] 経由（手動・自動共通の直列キュー）。
AutoSummaryPorts createRealPorts({
  required AutoSummarySettings settings,
  AutoSummaryRepository? repository,
  LlmRunArbiter? arbiter,
}) {
  final api = PixivApiService();
  final db = DatabaseService();
  final cache = LlmSummaryCacheService(dbService: db);
  final repo = repository ?? AutoSummaryRepository(dbService: db);
  final arb = arbiter ?? LlmRunArbiter();

  // ミュートリスト（最初の候補取得時に1回だけ読む）。
  List<Map<String, dynamic>>? mutes;

  // run ごとに再読込して差し替える有効設定（バグ修正 #1）。
  // UI とは別 isolate のため AutoSummarySettings.load() 側で prefs.reload() 済み。
  var effective = settings;

  return AutoSummaryPorts(
    fetchCandidates: (tag, page) async {
      mutes ??= await db.getMutesList();
      final offset = page * 30;
      final result = await api.searchNovel(
        tag,
        'partial_match_for_tags',
        'date_desc',
        offset,
        'all',
        null,
        null,
      );
      final items = result.items
          .map(
            (n) => AutoSummaryItem(workId: n.id, tags: n.tags, title: n.title),
          )
          .toList();
      return AutoSummaryCandidatePage(
        items: items,
        hasNext: result.nextUrl != null,
      );
    },
    resolveBody: (workId) async {
      return LlmSummaryService.resolveNovelBody(
        workId: workId,
        getCached: (id) => db.getNovelText(id),
        fetchText: (id) => api.getNovelText(id),
        saveToCache: (data) => db.saveNovelText(
          workId: data.id,
          title: '',
          authorName: '',
          text: data.novelText,
          pagesJson: jsonEncode(data.novelPages),
        ),
      );
    },
    isCachedValid: (workId, fingerprint) async {
      final mid = arb.modelId;
      final mp = arb.modelPath;
      if (mid == null || mp == null) return false;
      // F2: 手動と同一の有効性判定。モデルファイル hash を条件に加え、
      // 取り直し後（size/mtime 変更）の旧キャッシュを誤って再利用しない。
      final modelFileHash = await LlmSummaryCacheService.computeModelFileHash(
        mp,
      );
      final cached = await cache.get(
        workId: workId,
        modelId: mid,
        sourceFingerprint: fingerprint,
        modelFileHash: modelFileHash,
      );
      return cached != null;
    },
    generate: (workId, title, tags, body, onStage) async {
      await arb.generateAuto(
        workId: workId,
        title: title,
        tags: tags,
        body: body,
        onStage: onStage,
      );
    },
    saveSummary: (workId) async {
      final result = arb.lastAutoResult;
      final fp = arb.lastAutoFingerprint;
      final mp = arb.modelPath;
      final mid = arb.modelId;
      if (result == null || mp == null || fp == null || mid == null) return;
      final modelFileHash = await LlmSummaryCacheService.computeModelFileHash(
        mp,
      );
      await cache.save(
        workId: workId,
        modelId: mid,
        modelFileHash: modelFileHash,
        sourceFingerprint: fp,
        result: result,
      );
    },
    prepareModel: () async {
      await arb.ensureModel();
      return AutoSummaryModelInfo(
        modelLabel: arb.modelId ?? '',
        backendName: null,
      );
    },
    fingerprintOf: (title, tags, body) {
      return LlmSummaryService.computeSourceFingerprint(
        title: title,
        tags: tags,
        body: body,
      );
    },
    isMuted: (workId, tags) {
      if (mutes == null) return false;
      for (final m in mutes!) {
        final type = m['mute_type'] as String? ?? '';
        final value = m['value'] as String? ?? '';
        if (type == 'tag') {
          for (final t in tags) {
            if (t.toLowerCase() == value.toLowerCase()) return true;
          }
        } else if (type == 'user') {
          // user mute は author id 比較（候補取得段階では不明→スキップ）
        } else if (type == 'work') {
          if (workId.toString() == value) return true;
        }
      }
      return false;
    },
    getSummarizedWorkIds: () => db.getSummarizedWorkIds(),
    reloadSettings: () async {
      final fresh = await AutoSummarySettings.load();
      effective = fresh; // checkConditions 等のクロージャも次回から新設定を参照。
      return fresh;
    },
    checkConditions: () async {
      // ログイン確認。
      try {
        await api.getRefreshToken();
      } catch (_) {
        return AutoSummaryWaitReason.loginRequired;
      }
      // 充電確認。
      if (effective.chargeOnly) {
        final battery = Battery();
        final state = await battery.batteryState;
        if (state != BatteryState.charging &&
            state != BatteryState.full &&
            state != BatteryState.connectedNotCharging) {
          return AutoSummaryWaitReason.power;
        }
      }
      // WiFi確認。
      if (effective.wifiOnly) {
        final connectivity = Connectivity();
        final results = await connectivity.checkConnectivity();
        if (!results.contains(ConnectivityResult.wifi)) {
          return AutoSummaryWaitReason.wifi;
        }
      }
      return null;
    },
    persist: (snapshot) => repo.saveSnapshot(snapshot),
    requestGap: const Duration(seconds: 5),
  );
}
