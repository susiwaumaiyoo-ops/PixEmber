// Phase 9-B2/B2-4+5: 推論実行の仲裁者（LlmRunArbiter）。
//
// FGS TaskHandler 側 FlutterEngine 内に存在し、手動・自動の両方の
// 生成要求を単一の LocalLlmService で直列処理する。
//
// 規則（ユーザー承認 2026-09-11）:
// - 生成中の作品は常に1つだけ。
// - 手動要求は現在の作品終了後、次の自動作品より先に実行。
// - 強制割込み・途中 context 交換はしない。
// - pause ≠ モデル解放（pause しても context は保持）。
// - requestId で二重配送を防止。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'local_llm_service.dart';
import 'llm_model_preset.dart';
import 'llm_summary_service.dart';

/// 手動要約の要求。
class ManualSummaryRequest {
  const ManualSummaryRequest({
    required this.requestId,
    required this.workId,
    required this.title,
    required this.tags,
    required this.body,
    this.description = '',
    this.modelLabel = '',
  });

  final String requestId;
  final int workId;
  final String title;
  final List<String> tags;
  final String body;
  final String description;
  final String modelLabel;
}

/// 手動要約の状態遷移。
enum ManualRequestStatus {
  queued,
  waiting,
  generating,
  completed,
  cancelled,
  error,
}

/// 推論実行の仲裁者。
///
/// [LocalLlmService] の唯一の所有者。手動・自動の生成要求を
/// 直列に処理し、同時生成を構造的に防止する。
class LlmRunArbiter {
  /// [serviceFactory] / [modelPathResolver] はテスト用の注入シーム。
  /// 本番はいずれも null（既定で実装を解決する）。
  LlmRunArbiter({
    @visibleForTesting this.serviceFactory,
    @visibleForTesting this.modelPathResolver,
  });

  /// テスト注入用（本番は null）。推論主体を差し替える。
  @visibleForTesting
  final LocalLlmService Function(String modelPath)? serviceFactory;

  /// テスト注入用（本番は null）。モデルパス解決を差し替える。
  @visibleForTesting
  final Future<String?> Function()? modelPathResolver;

  // ---- 推論サービス（唯一の所有者）----
  LocalLlmService? _service;
  String? _modelPath;
  String? _modelId;
  bool _modelReady = false;

  // ---- 生成状態 ----
  bool _generating = false;
  String? _activeRequestId;

  // ---- 手動キュー（自動より優先）----
  final List<ManualSummaryRequest> _manualQueue = [];
  final Set<String> _processedRequestIds = {};

  // ---- 自動要約の直前結果（saveSummary 用）----
  LlmSummaryResult? lastAutoResult;
  String? lastAutoFingerprint;

  // ---- コールバック ----
  /// 手動要求の状態変化を UI へ通知。
  void Function(
    String requestId,
    ManualRequestStatus status, {
    String? token,
    LlmSummaryResult? result,
    String? error,
  })?
  onManualEvent;

  // ---- 公開状態 ----
  bool get isGenerating => _generating;
  bool get hasManualPending => _manualQueue.isNotEmpty;
  bool get isModelReady => _modelReady;
  String? get modelPath => _modelPath;
  String? get modelId => _modelId;

  // ===========================================================================
  // モデル管理
  // ===========================================================================

  /// モデルを準備する（セッション内で1回のみ・同一モデル再利用）。
  Future<void> ensureModel() async {
    if (_modelReady) return;

    final path =
        await (modelPathResolver?.call() ?? LlmModelPaths.resolveModelPath());
    if (path == null) {
      throw StateError('モデルが未導入です');
    }

    // 別のモデルがロード済みなら一旦解放。
    if (_service != null && _modelPath != path) {
      await _service!.dispose();
      _service = null;
      _modelReady = false;
    }

    if (_service == null) {
      _modelPath = path;
      _modelId = p.basename(path);
      final factory = serviceFactory;
      if (factory != null) {
        // テスト注入: 渡されたエンジンを持つ LocalLlmService を生成。
        _service = factory(path);
      } else {
        final runtimeSettings = await LlmRuntimeSettings.load();
        final preset = LlmInferencePreset.resolveForFileName(path, const []);
        _service = LocalLlmService(
          preset: preset,
          runtimeSettings: runtimeSettings,
        );
      }
    }

    final ok = await _service!.loadModel(_modelPath!);
    if (!ok) {
      throw StateError(_service!.errorMessage ?? 'モデルの読み込みに失敗しました');
    }
    _modelReady = true;
    debugPrint('[LlmRunArbiter] model ready: $_modelId');
  }

  // ===========================================================================
  // 自動要約の生成（AutoSummaryService → ports.generate から呼ばれる）
  // ===========================================================================

  /// 自動要約の1作品を生成する。
  /// 手動要求がキューにある場合、先に手動を処理する。
  /// 戻り値は生成結果（saveSummary で使用）。
  Future<LlmSummaryResult> generateAuto({
    required int workId,
    required String title,
    required List<String> tags,
    required String body,
    void Function(int current, int total)? onStage,
  }) async {
    // 手動キューを先に消化（手動優先）。
    while (_manualQueue.isNotEmpty) {
      await _processNextManual();
    }

    if (!_modelReady) {
      await ensureModel();
    }

    _generating = true;
    _activeRequestId = 'auto-$workId';
    try {
      final fingerprint = LlmSummaryService.computeSourceFingerprint(
        title: title,
        tags: tags,
        body: body,
      );
      lastAutoFingerprint = fingerprint;
      final result = await LlmSummaryService.generate(
        service: _service!,
        title: title,
        body: body,
        tags: tags,
        modelLabel: _modelId ?? '',
        onStageProgress: onStage,
      );
      lastAutoResult = result;
      return result;
    } finally {
      _generating = false;
      _activeRequestId = null;
      // 自動完了後に手動キューが残っていれば消化を開始。
      // （次回の generateAuto が呼ばれない場合の救済）
      _scheduleDrain();
    }
  }

  // ===========================================================================
  // 手動要約
  // ===========================================================================

  /// 手動要約をキューに入れる。
  /// 自動が生成中なら完了を待ち、その後手動を実行する。
  Future<void> submitManual(ManualSummaryRequest req) async {
    // requestId 二重配送防止。
    if (_processedRequestIds.contains(req.requestId)) {
      debugPrint(
        '[LlmRunArbiter] duplicate requestId ignored: ${req.requestId}',
      );
      return;
    }
    _processedRequestIds.add(req.requestId);

    if (!_modelReady) {
      try {
        await ensureModel();
      } catch (e) {
        onManualEvent?.call(
          req.requestId,
          ManualRequestStatus.error,
          error: e.toString(),
        );
        return;
      }
    }

    if (_generating) {
      // 自動が生成中 → キューに入れて完了を待つ。
      _manualQueue.add(req);
      onManualEvent?.call(req.requestId, ManualRequestStatus.waiting);
      return;
    }

    // 即座に実行。
    await _executeManual(req);
  }

  Future<void> _processNextManual() async {
    if (_manualQueue.isEmpty) return;
    final req = _manualQueue.removeAt(0);
    await _executeManual(req);
  }

  Future<void> _executeManual(ManualSummaryRequest req) async {
    onManualEvent?.call(req.requestId, ManualRequestStatus.generating);
    _generating = true;
    _activeRequestId = req.requestId;
    try {
      final result = await LlmSummaryService.generate(
        service: _service!,
        title: req.title,
        body: req.body,
        tags: req.tags,
        description: req.description,
        modelLabel: req.modelLabel.isNotEmpty
            ? req.modelLabel
            : (_modelId ?? ''),
        onToken: (token) {
          onManualEvent?.call(
            req.requestId,
            ManualRequestStatus.generating,
            token: token,
          );
        },
      );
      onManualEvent?.call(
        req.requestId,
        ManualRequestStatus.completed,
        result: result,
      );
    } on LlmCancelledException {
      onManualEvent?.call(req.requestId, ManualRequestStatus.cancelled);
    } catch (e) {
      onManualEvent?.call(
        req.requestId,
        ManualRequestStatus.error,
        error: e.toString(),
      );
    } finally {
      _generating = false;
      _activeRequestId = null;
      // 手動完了後に次の手動キューがあれば消化。
      _scheduleDrain();
    }
  }

  /// 生成完了後に手動キューを消化する（fire-and-forget）。
  ///
  /// 自動要約の最終作品完了後や手動キャンセル後など、
  /// 次に generateAuto が呼ばれない状況でキューが滞留するのを防ぐ。
  void _scheduleDrain() {
    if (_manualQueue.isEmpty || _generating) return;
    scheduleMicrotask(() async {
      while (_manualQueue.isNotEmpty && !_generating) {
        await _processNextManual();
      }
    });
  }

  /// 手動要約をキャンセルする（安全: 現在のトークン出力完了を待つ）。
  void cancelManual(String requestId) {
    if (_activeRequestId == requestId) {
      _service?.cancel();
    }
    // キュー内なら除去。
    _manualQueue.removeWhere((r) => r.requestId == requestId);
  }

  // ===========================================================================
  // 停止・解放
  // ===========================================================================

  /// 生成完了を待つ（安全な停止のため）。
  Future<void> waitForIdle() async {
    while (_generating) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// モデル・サービスを解放する（サービス停止時）。
  Future<void> disposeModel() async {
    _manualQueue.clear();
    _service?.cancel();
    await _service?.dispose();
    _service = null;
    _modelReady = false;
    _modelPath = null;
    _modelId = null;
    debugPrint('[LlmRunArbiter] model disposed');
  }

  void dispose() {
    _manualQueue.clear();
    _service?.dispose();
    _service = null;
  }
}
