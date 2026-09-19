import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/auto_summary_bridge_controller.dart';
import '../services/companion/companion_models.dart';
import '../services/companion/companion_service.dart';
import '../services/companion/companion_transport.dart';
import '../services/fgs_lifecycle_service.dart';
import '../services/llm_run_arbiter.dart';
import '../services/local_llm_service.dart';
import '../services/llm_model_preset.dart' show LlmModelChoice;
import '../services/llm_summary_cache_service.dart';
import '../services/llm_summary_service.dart';

/// 小説のAI要約を表示するボトムシート（実験機能）。
///
/// 開いた時点で生成を開始する。ストリーミング中のテキストをリアルタイム表示し、
/// 完了後に3セクション（あらすじ / 紹介 / タグ候補）として整形表示する。
/// キャンセル・リトライに対応。シート閉じ（dispose）時にサービスも破棄する。
///
/// M1: 生成元は小説本文のみ（[resolveBody] で解決）。
/// 本文取得失敗時は作者説明へのフォールバックなしでエラー表示する。
/// 作者説明は「作者による紹介」として別途表示し、プロンプトには含めない。
class LlmSummarySheet extends StatefulWidget {
  const LlmSummarySheet({
    super.key,
    required this.modelPath,
    required this.title,
    required this.description,
    this.tags = const [],
    required this.resolveBody,
    this.workId,
    this.availableModels = const <LlmModelChoice>[],
    this.serviceFactory,
    this.bridgeController,
    this.companionService,
  });

  /// 使用する GGUF モデルの絶対パス（初期値。「別モデルで再生成」で更新）。
  final String modelPath;

  /// 切替候補モデル一覧（M5）。空なら「別モデルで再生成」を表示しない。
  final List<LlmModelChoice> availableModels;

  /// サービス生成ファクトリ（テストで fake エンジン注入に使用）。
  /// 非 null ならローカル実行（テスト互換）。null なら FGS 経由。
  final LocalLlmService Function()? serviceFactory;

  /// FGS ブリッジコントローラ（手動要約の要求・応答）。
  /// null なら内部で生成・破棄する。
  final AutoSummaryBridgeController? bridgeController;

  /// PC Companion サービス（10-B1）。non-null かつペアリング済みなら
  /// PCサーバー経由で生成する（serviceFactory 指定時を除く・ローカル挙動不変）。
  final CompanionService? companionService;

  final String title;

  /// 作者の説明（表示・コピー検出専用 — AI生成プロンプトには含めない）。
  final String description;
  final List<String> tags;

  /// 小説本文を解決する（キャッシュ → 取得 + 保存）。
  ///
  /// null / 空を返すと「小説本文を取得できないため、AI要約を生成できません。」
  /// を表示する（作者説明へのフォールバックはしない）。
  final Future<String?> Function() resolveBody;

  /// 作品ID（M6・要約キャッシュ用）。null ならキャッシュしない。
  final int? workId;

  @override
  State<LlmSummarySheet> createState() => _LlmSummarySheetState();
}

enum _SheetPhase { loading, generating, done, error }

class _LlmSummarySheetState extends State<LlmSummarySheet> {
  LocalLlmService? _service;
  _SheetPhase _phase = _SheetPhase.loading;
  String _streamText = '';
  LlmSummaryResult? _result;
  String? _errorMessage;
  bool _noteCancelled = false;
  bool _busy = false;

  /// B: 本文解決の所要時間（ミリ秒）。「本文を処理中」表示とメタ計測用。
  int? _bodyMs;

  /// B: キャッシュヒットの有無（メタ計測用）。
  bool _cacheHit = false;

  /// B: 自動再生成（コピー検知リトライ）の回数。
  int _regenerations = 0;

  /// B-5: チャンク進捗（現在 / 全チャンク数）。0 = 非チャンク。
  int _chunkCurrent = 0;
  int _chunkTotal = 0;
  bool get _chunking => _chunkTotal > 1;

  /// B: loading 中に表示する進行ステージ（本文処理 / モデル準備）。
  String _stageText = 'モデルを準備中…（初回は数秒〜数十秒かかることがあります）';

  /// 現在選択中のモデルパス（M5）。「別モデルで再生成」で更新される。
  String _activeModelPath = '';

  /// FGS 経由の手動要約用。
  AutoSummaryBridgeController? _bridge;
  bool _ownsBridge = false;
  String _requestId = '';
  bool _waitingForAuto = false;

  /// 10-B1: PC Companion 経由ジョブの状態。
  CompanionService? _companion;
  Timer? _companionPoll;
  int _companionJobId = 0;
  Duration _companionBackoff = const Duration(seconds: 4);
  bool _companionError = false;

  /// 「端末で生成する」選択時（手動のみ・自動フォールバック禁止）。
  bool _forceLocal = false;

  @override
  void dispose() {
    // 10-B1: PCサーバーへのポーリングを停止（PC側の生成は継続する・キャンセル扱いしない）。
    _companionPoll?.cancel();
    // 生成中・読み込み中でも確実に破棄（dispose 後の setState は起きない）。
    _service?.dispose();
    if (_ownsBridge) {
      _bridge?.dispose();
    } else if (_bridge != null) {
      _bridge!.onManualEvent = null;
    }
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy) return;
    _busy = true;
    setState(() {
      _phase = _SheetPhase.loading;
      _streamText = '';
      _result = null;
      _errorMessage = null;
      _noteCancelled = false;
      _bodyMs = null;
      _cacheHit = false;
      _regenerations = 0;
      _waitingForAuto = false;
      _stageText = '本文を処理中…';
      _companionJobId = 0;
      _companionError = false;
    });
    final bodyWatch = Stopwatch()..start();
    // テスト用ファクトリが指定されていればローカル実行（旧経路）。
    if (widget.serviceFactory != null) {
      await _startLocal(bodyWatch);
      return;
    }
    // 10-B1: Companion ペアリング済みなら PCサーバー経由（「端末で生成する」選択時を除く）。
    if (widget.companionService != null &&
        !_forceLocal &&
        widget.companionService!.isPaired) {
      if (widget.workId == null) {
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = 'PCサーバーでの生成には作品IDが必要です。「端末で生成する」をご利用ください。';
        });
        return;
      }
      await _startViaCompanion();
      return;
    }
    // FGS 経由の実行。
    await _startViaFgs(bodyWatch);
  }

  /// テスト互換のローカル実行経路（serviceFactory 指定時）。
  Future<void> _startLocal(Stopwatch bodyWatch) async {
    final old = _service;
    _service = null;
    old?.dispose();
    try {
      final body = (await widget.resolveBody()) ?? '';
      if (!mounted) return;
      bodyWatch.stop();
      setState(() {
        _bodyMs = bodyWatch.elapsedMilliseconds;
        _stageText = 'モデルを準備中…（初回は数秒〜数十秒かかることがあります）';
      });
      if (body.trim().isEmpty) {
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = '小説本文を取得できないため、AI要約を生成できません。';
        });
        return;
      }
      final svc = widget.serviceFactory!.call();
      _service = svc;
      final ok = await svc.loadModel(_activeModelPath);
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = svc.errorMessage ?? 'モデルを読み込めませんでした。';
        });
        return;
      }
      final fingerprint = LlmSummaryService.computeSourceFingerprint(
        title: widget.title,
        tags: widget.tags,
        body: body,
      );
      final modelId = p.basename(_activeModelPath);
      // F2: キャッシュ有効性判定にモデルファイル hash を含める（手動/自動共通）。
      // workId 指定時のみ計算（UI テストの pump 回数に影響しないよう lazy）。
      String? modelFileHash;
      if (widget.workId != null) {
        modelFileHash = await LlmSummaryCacheService.computeModelFileHash(
          _activeModelPath,
        );
        final cached = await LlmSummaryCacheService().get(
          workId: widget.workId!,
          modelId: modelId,
          sourceFingerprint: fingerprint,
          modelFileHash: modelFileHash,
        );
        if (cached != null) {
          if (!mounted) return;
          _cacheHit = true;
          setState(() {
            _phase = _SheetPhase.done;
            _result = cached;
          });
          return;
        }
      }
      final result = await LlmSummaryService.generate(
        service: svc,
        title: widget.title,
        body: body,
        tags: widget.tags,
        description: widget.description,
        modelLabel: _activeModelLabel,
        onRegeneration: () => _regenerations++,
        onStageProgress: (current, total) {
          if (!mounted) return;
          setState(() {
            _chunkCurrent = current;
            _chunkTotal = total;
          });
        },
        onToken: (piece) {
          if (!mounted) return;
          setState(() {
            if (_phase == _SheetPhase.loading) {
              _phase = _SheetPhase.generating;
            }
            _streamText += piece;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.done;
        _result = result;
      });
      if (widget.workId != null) {
        await LlmSummaryCacheService().save(
          workId: widget.workId!,
          modelId: modelId,
          modelFileHash:
              modelFileHash ??
              await LlmSummaryCacheService.computeModelFileHash(
                _activeModelPath,
              ),
          sourceFingerprint: fingerprint,
          result: result,
        );
      }
    } on LlmCancelledException {
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.loading;
        _noteCancelled = true;
        _chunkCurrent = 0;
        _chunkTotal = 0;
      });
    } on LlmSummaryException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.error;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      final firstLine = e.toString().split('\n').first.trim();
      setState(() {
        _phase = _SheetPhase.error;
        _errorMessage =
            '要約の生成に失敗しました: ${firstLine.length > 120 ? '${firstLine.substring(0, 120)}…' : firstLine}';
      });
    } finally {
      _busy = false;
    }
  }

  /// FGS 経由の手動要約実行（B2-4+5: 推論は FGS 側 LlmRunArbiter のみ）。
  Future<void> _startViaFgs(Stopwatch bodyWatch) async {
    try {
      // 1. 本文解決。
      final body = (await widget.resolveBody()) ?? '';
      if (!mounted) return;
      bodyWatch.stop();
      setState(() {
        _bodyMs = bodyWatch.elapsedMilliseconds;
        _stageText = 'モデルを準備中…（初回は数秒〜数十秒かかることがあります）';
      });
      if (body.trim().isEmpty) {
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = '小説本文を取得できないため、AI要約を生成できません。';
        });
        return;
      }

      // 2. キャッシュ確認（UI 側で DB 直接参照は許可）。
      final fingerprint = LlmSummaryService.computeSourceFingerprint(
        title: widget.title,
        tags: widget.tags,
        body: body,
      );
      final modelId = p.basename(_activeModelPath);
      if (widget.workId != null) {
        // F2: FGS 起動前にキャッシュを確認する際も、モデルファイル hash を
        // 条件に含め、旧モデルの別内容キャッシュを誤って使わない。
        final modelFileHash = await LlmSummaryCacheService.computeModelFileHash(
          _activeModelPath,
        );
        final cached = await LlmSummaryCacheService().get(
          workId: widget.workId!,
          modelId: modelId,
          sourceFingerprint: fingerprint,
          modelFileHash: modelFileHash,
        );
        if (cached != null) {
          if (!mounted) return;
          _cacheHit = true;
          setState(() {
            _phase = _SheetPhase.done;
            _result = cached;
          });
          return;
        }
      }

      // 3. FGS 起動・READY 確認。
      setState(() => _stageText = 'バックグラウンドサービスを起動中…');
      final ready = await FgsLifecycleService().ensureServiceReady();
      if (!mounted) return;
      if (!ready) {
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = 'バックグラウンドサービスの起動に失敗しました。';
        });
        return;
      }

      // 4. ブリッジ準備。
      if (_bridge == null) {
        _bridge = widget.bridgeController ?? AutoSummaryBridgeController();
        _ownsBridge = widget.bridgeController == null;
      }
      _requestId =
          'manual-${widget.workId ?? 0}-${DateTime.now().millisecondsSinceEpoch}';
      _bridge!.onManualEvent = _onManualEvent;

      // 5. 手動要約要求を送信。
      setState(() => _stageText = '生成を開始しています…');
      _bridge!.submitManualSummary(
        requestId: _requestId,
        workId: widget.workId ?? 0,
        title: widget.title,
        tags: widget.tags,
        body: body,
        description: widget.description,
        modelLabel: _activeModelLabel,
      );
    } catch (e) {
      if (!mounted) return;
      final firstLine = e.toString().split('\n').first.trim();
      setState(() {
        _phase = _SheetPhase.error;
        _errorMessage =
            '要約の生成に失敗しました: ${firstLine.length > 120 ? '${firstLine.substring(0, 120)}…' : firstLine}';
      });
    } finally {
      _busy = false;
    }
  }

  /// PC Companion サーバー経由の生成（10-B1・§4-B）。
  ///
  /// - 本文取得・生成はすべて PC 側で行う（端末の NPU/CPU は使わない）。
  /// - ローカル推論への自動フォールバックは禁止。「端末で生成する」は手動のみ。
  /// - ポーリングは画面表示中のみ。切断しても PC 側の生成は継続し、
  ///   再接続後に job_id から状態を再取得できる（キャンセル扱いしない）。
  Future<void> _startViaCompanion() async {
    _companion = widget.companionService!;
    try {
      setState(() => _stageText = 'PCサーバーへジョブを送信中…');
      // crid 冪等: 未完了 pending ジョブがあれば同じ crid で再送→同一 job へ再アタッチ。
      final created = await _companion!.createJob(widget.workId!);
      if (!mounted) return;
      _companionJobId = created.jobId;
      setState(() {
        _stageText = 'PCサーバー: ${companionJobStageLabel(created.job.state)}';
      });
      _companionBackoff = const Duration(seconds: 4);
      _scheduleCompanionPoll();
    } on CompanionAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.error;
        _companionError = true;
        _errorMessage = e.isRevoked
            ? 'PCサーバーの認証が失効しています。設定画面で再登録してください。'
            : 'PCサーバーとの認証に失敗しました。設定画面を確認してください。';
      });
    } on CompanionCertException {
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.error;
        _companionError = true;
        _errorMessage = 'PCサーバーの証明書が登録時と一致しません。通信を拒否しました（設定画面で確認）。';
      });
    } catch (e) {
      if (!mounted) return;
      final firstLine = e.toString().split('\n').first.trim();
      setState(() {
        _phase = _SheetPhase.error;
        _companionError = true;
        _errorMessage =
            'PCサーバーへのジョブ送信に失敗しました: ${firstLine.length > 100 ? '${firstLine.substring(0, 100)}…' : firstLine}';
      });
    } finally {
      _busy = false;
    }
  }

  /// §4-C: 表示中のみ 3〜5s ポーリング。通信失敗時は backoff して再試行。
  void _scheduleCompanionPoll() {
    _companionPoll?.cancel();
    _companionPoll = Timer(_companionBackoff, _pollCompanionJob);
  }

  Future<void> _pollCompanionJob() async {
    final jobId = _companionJobId;
    final svc = _companion;
    if (jobId == 0 || svc == null || !mounted) return;
    try {
      final job = await svc.fetchJob(jobId);
      if (!mounted) return;
      setState(() {
        _stageText =
            'PCサーバー: ${companionJobStageLabel(job.state, done: job.chunksDone, total: job.chunksTotal)}';
        if (job.state == 'mapping' && job.chunksTotal > 0) {
          _chunkCurrent = job.chunksDone;
          _chunkTotal = job.chunksTotal;
        }
      });
      if (job.isTerminal) {
        await _finishCompanionJob(job);
        return;
      }
      // 通常時は backoff を基本間隔に戻す。
      _companionBackoff = const Duration(seconds: 4);
      _scheduleCompanionPoll();
    } catch (e) {
      // 通信断でも PC 側の生成は継続。キャンセル扱いせず backoff 再試行する。
      if (!mounted) return;
      setState(() {
        _stageText = 'PCサーバーとの通信を再試行しています…（PC側の生成は継続します）';
      });
      _companionBackoff = Duration(
          seconds: (_companionBackoff.inSeconds * 2).clamp(4, 30));
      _scheduleCompanionPoll();
    }
  }

  Future<void> _finishCompanionJob(CompanionJob job) async {
    final svc = _companion;
    if (svc == null) return;
    // 終端ジョブの pending を掃除。
    try {
      await svc.settleJob(job);
    } catch (_) {}
    if (!mounted) return;
    if (job.isCompleted && job.result != null) {
      final r = job.result!;
      // §5: 検証済み結果を server_summaries へ保存（llm_summaries とは別テーブル）。
      try {
        await svc.saveResult(r, job.jobId);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _phase = _SheetPhase.done;
        _result = LlmSummaryResult(
          synopsis: r.synopsis,
          intro: r.spoilerFreeIntro,
          tagSuggestions: r.suggestedTags,
          copyWarning: r.copyWarning,
          bodySourceNote: '生成元：PCサーバー（${r.modelId}）',
          modelLabel: 'PCサーバー（${r.modelId}）',
          generationMs: r.generationMs == 0 ? null : r.generationMs,
          generatedAt: DateTime.tryParse(r.generatedAt),
          processingMode: r.mode,
        );
      });
      return;
    }
    setState(() {
      _phase = _SheetPhase.error;
      _companionError = true;
      _errorMessage = job.state == 'cancelled'
          ? 'PCサーバーでの生成をキャンセルしました。'
          : 'PCサーバーでの生成に失敗しました: ${job.error ?? '原因不明'}';
    });
  }

  /// FGS 側からの手動要約イベント受信。
  void _onManualEvent(
    String requestId,
    ManualRequestStatus status, {
    String? token,
    LlmSummaryResult? result,
    String? error,
  }) {
    if (requestId != _requestId) return;
    if (!mounted) return;
    switch (status) {
      case ManualRequestStatus.waiting:
        setState(() {
          _waitingForAuto = true;
          _stageText = '自動要約の処理終了を待っています…';
        });
        break;
      case ManualRequestStatus.generating:
        setState(() {
          _waitingForAuto = false;
          if (_phase == _SheetPhase.loading) {
            _phase = _SheetPhase.generating;
          }
          if (token != null) _streamText += token;
        });
        break;
      case ManualRequestStatus.completed:
        setState(() {
          _phase = _SheetPhase.done;
          _result = result;
        });
        // キャッシュ保存（失敗は無視）。
        if (widget.workId != null && result != null) {
          _saveToCache(result);
        }
        break;
      case ManualRequestStatus.cancelled:
        setState(() {
          _phase = _SheetPhase.loading;
          _noteCancelled = true;
        });
        break;
      case ManualRequestStatus.error:
        setState(() {
          _phase = _SheetPhase.error;
          _errorMessage = error ?? '生成に失敗しました。';
        });
        break;
      case ManualRequestStatus.queued:
        break;
    }
  }

  Future<void> _saveToCache(LlmSummaryResult result) async {
    try {
      final fingerprint = LlmSummaryService.computeSourceFingerprint(
        title: widget.title,
        tags: widget.tags,
        body: '', // 本文は既に解決済みだが、キャッシュキーには空で十分（workId+modelId で一意）
      );
      final modelId = p.basename(_activeModelPath);
      final modelFileHash = await LlmSummaryCacheService.computeModelFileHash(
        _activeModelPath,
      );
      await LlmSummaryCacheService().save(
        workId: widget.workId!,
        modelId: modelId,
        modelFileHash: modelFileHash,
        sourceFingerprint: fingerprint,
        result: result,
      );
    } catch (_) {}
  }

  void _cancel() {
    // 10-B1: PCサーバージョブのキャンセル要求（明示 API のみ・切断≠キャンセルではない）。
    final jobId = _companionJobId;
    final svc = _companion;
    if (jobId != 0 && svc != null) {
      unawaited(svc.cancelJob(jobId));
      // キャンセル要求後も終端状態までポーリングを継続。
      _scheduleCompanionPoll();
      return;
    }
    if (_requestId.isNotEmpty && _bridge != null) {
      _bridge!.cancelManualSummary(_requestId);
    }
    _service?.cancel();
  }

  /// M5: モデルを切り替えて再生成する。
  void _useModel(LlmModelChoice choice) {
    if (_busy) return;
    setState(() => _activeModelPath = choice.path);
    _start();
  }

  /// M5: 現在のモデルの表示ラベル（候補一覧から解決。未登録なら空）。
  String get _activeModelLabel {
    for (final m in widget.availableModels) {
      if (m.path == _activeModelPath) return m.label;
    }
    return '';
  }

  /// M5: 別モデル選択シート → 選択で再生成。
  Future<void> _showModelPicker() async {
    final picked = await showModalBottomSheet<LlmModelChoice>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1C),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '別のモデルで再生成',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final m in widget.availableModels)
              ListTile(
                title: Text(
                  m.label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: Text(
                  p.basename(m.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                trailing: m.path == _activeModelPath
                    ? const Icon(Icons.check, color: Colors.pinkAccent)
                    : null,
                onTap: () => Navigator.of(context).pop(m),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked.path == _activeModelPath) return;
    _useModel(picked);
  }

  @override
  void initState() {
    super.initState();
    _activeModelPath = widget.modelPath;
    _start();
  }

  @override
  Widget build(BuildContext context) {
    void closeSheet() => Navigator.of(context).pop();
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1C),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Text(
                  '🤖 AI要約（実験）',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_companionJobId != 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.tealAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.tealAccent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: const Text(
                    'PCサーバー',
                    style: TextStyle(color: Colors.tealAccent, fontSize: 11),
                  ),
                ),
              ],
              const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  tooltip: '閉じる',
                  onPressed: closeSheet,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _buildBody(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_phase == _SheetPhase.loading ||
                    _phase == _SheetPhase.generating)
                  OutlinedButton(
                    onPressed: _cancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                    ),
                    child: const Text('キャンセル'),
                  ),
                if (_phase == _SheetPhase.error || _noteCancelled)
                  OutlinedButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(_noteCancelled ? 'もう一度試す' : '再試行'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.pinkAccent,
                      side: const BorderSide(color: Colors.pinkAccent),
                    ),
                  ),
                if (_phase == _SheetPhase.error &&
                    _companionError &&
                    widget.serviceFactory == null &&
                    widget.companionService != null)
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() => _forceLocal = true);
                      _start();
                    },
                    icon: const Icon(Icons.phone_android, size: 16),
                    label: const Text('端末で生成する'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.tealAccent,
                      side: const BorderSide(color: Colors.tealAccent),
                    ),
                  ),
                if (_phase == _SheetPhase.done) ...[
                  if (widget.availableModels.length > 1)
                    OutlinedButton.icon(
                      onPressed: _showModelPicker,
                      icon: const Icon(Icons.swap_horiz, size: 16),
                      label: const Text('別モデルで再生成'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('このモデルで再生成'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.pinkAccent,
                      side: const BorderSide(color: Colors.pinkAccent),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_noteCancelled) {
      return const Text(
        '生成をキャンセルしました。',
        style: TextStyle(color: Colors.white70, fontSize: 13),
      );
    }
    switch (_phase) {
      case _SheetPhase.loading:
        return Column(
          children: [
            const SizedBox(
              height: 32,
              child: CircularProgressIndicator(color: Colors.pinkAccent),
            ),
            const SizedBox(height: 16),
            Text(
              _stageText,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (_waitingForAuto) ...[
              const SizedBox(height: 8),
              const Text(
                '自動要約の処理終了を待っています',
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ],
            if (_bodyMs != null) ...[
              const SizedBox(height: 4),
              Text(
                '本文の処理（${(_bodyMs! / 1000).toStringAsFixed(1)} 秒）',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ],
        );
      case _SheetPhase.generating:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.pinkAccent,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _chunking ? '全文解析中 ($_chunkCurrent/$_chunkTotal)…' : '生成中…',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _StreamTextBlock(text: _streamText),
          ],
        );
      case _SheetPhase.done:
        final result = _result;
        if (result == null) {
          return const Text(
            '結果がありません。',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          );
        }
        return _buildDone(result);
      case _SheetPhase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage ?? '生成に失敗しました。',
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            if (_streamText.isNotEmpty) ...[
              const SizedBox(height: 12),
              _StreamTextBlock(text: _streamText, muted: true),
            ],
          ],
        );
    }
  }

  Widget _buildDone(LlmSummaryResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildModelMeta(result),
        if (result.bodySourceNote != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const Icon(Icons.article, size: 14, color: Colors.white54),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    result.bodySourceNote!,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        if (result.copyWarning)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Colors.orange,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '作者紹介文・本文との重複の多い出力です（参考までに表示）。',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if ((result.thinking ?? '').isNotEmpty) ...[
          _buildThinking(result.thinking!),
          const SizedBox(height: 12),
        ],
        _SectionLabel(label: 'あらすじ'),
        Text(
          result.synopsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
        _SectionLabel(label: '紹介'),
        Text(
          result.intro,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 14),
        _SectionLabel(label: 'タグ候補'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tag in result.tagSuggestions)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.pinkAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.pinkAccent.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  tag,
                  style: const TextStyle(
                    color: Colors.pinkAccent,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
        if (widget.description.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          _SectionLabel(label: '作者による紹介（AI生成に使用せず）'),
          const SizedBox(height: 6),
          Text(
            widget.description.trim(),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          '※ 実験機能です。内容の正確性は保証されません。',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
      ],
    );
  }

  /// モデルが吐いた思考プロセス（本文から分離）を折りたたみ表示する。
  Widget _buildThinking(String thinking) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          iconColor: Colors.white54,
          collapsedIconColor: Colors.white54,
          title: const Row(
            children: [
              Icon(Icons.psychology_alt, size: 16, color: Colors.amberAccent),
              SizedBox(width: 6),
              Text(
                '思考プロセス',
                style: TextStyle(color: Colors.amberAccent, fontSize: 13),
              ),
            ],
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                thinking,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// M5: 生成メタ情報（モデル名・日時・所要時間・速度）。
  Widget _buildModelMeta(LlmSummaryResult result) {
    final label = (result.modelLabel?.isNotEmpty ?? false)
        ? result.modelLabel!
        : p.basename(_activeModelPath);
    final dt = result.generatedAt;
    final when = dt == null
        ? null
        : '${dt.year}/${_two(dt.month)}/${_two(dt.day)} '
              '${_two(dt.hour)}:${_two(dt.minute)}';
    final secs = result.generationMs == null
        ? null
        : (result.generationMs! / 1000).toStringAsFixed(1);
    final tps = result.tokensPerSecond;
    final stats = _service?.lastGenerationStats;
    final ttft = (stats?.timeToFirstTokenMs ?? result.timeToFirstTokenMs);
    final loadMs = stats?.loadMs;
    final nativeTps = stats?.nativeTokensPerSecond;
    final prefillMs = stats?.nativePromptEvalMs;
    final prefillTokens = stats?.nativePromptEvalTokens;
    final rows = <(String, String)>[
      ('モデル', label),
      if (when != null) ('生成日時', when),
      if (secs != null) ('処理時間', '$secs 秒'),
      if (ttft != null) ('最初の出力まで', '${(ttft / 1000).toStringAsFixed(1)} 秒'),
      if (loadMs != null)
        (
          'モデルロード',
          loadMs == 0 ? '再利用（0 秒）' : '${(loadMs / 1000).toStringAsFixed(1)} 秒',
        ),
      if (result.inputTokens != null) ('入力トークン', '${result.inputTokens}'),
      if (tps != null) ('速度', '${tps.toStringAsFixed(1)} トークン/秒'),
      if (stats?.backend != null) ('backend', stats!.backend!),
      if (stats?.usedCpuFallback ?? false) ('フォールバック', 'バックエンド失敗→CPUで実行'),
      if (stats?.requestedThreads != null)
        (
          'スレッド要求',
          't=${_threadLabel(stats!.requestedThreads)} / '
              'b=${_threadLabel(stats.requestedThreadsBatch)}',
        ),
      if (stats?.resolvedGpuLayers != null)
        ('GPU層', '${stats!.resolvedGpuLayers}'),
      if (stats?.backendName != null) ('native backend', stats!.backendName!),
      // 入力処理（prefill）はネイティブ計測が取れた場合のみ表示する。
      // 「TTFT − ロード時間」を prefill と呼ばない（未取得は明示）。
      if (prefillMs != null)
        (
          '入力処理',
          '${prefillMs.toStringAsFixed(0)} ms（${prefillTokens ?? '-'} トークン）',
        ),
      if (prefillMs == null) ('入力処理', '未取得'),
      if (nativeTps != null)
        ('ネイティブ速度', '${nativeTps.toStringAsFixed(1)} トークン/秒'),
      if (stats?.nativeEvalMs != null && (stats!.nativeEvalMs ?? 0) <= 0)
        ('ネイティブ速度', '未取得'),
      if (stats?.stopReason != null) ('停止理由', stats!.stopReason!),
      if (result.processingMode != null) ('処理方式', result.processingMode!),
      ('キャッシュ', _cacheHit ? 'ヒット' : 'なし'),
      if (_regenerations > 0) ('自動再生成', '$_regenerations 回'),
      // A-3: コンテキスト縮小フォールバックが発生した場合のみ表示する。
      if (_service?.contextShrinkNote != null)
        ('コンテキスト', _service!.contextShrinkNote!),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      k,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      v,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// スレッド要求値の表示（0 = 自動・推測で確定しない）。
  static String _threadLabel(int? t) => (t == null || t == 0) ? '自動' : '$t';

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// セクション見出し。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      '【$label】',
      style: const TextStyle(
        color: Colors.pinkAccent,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

/// ストリーミング中のテキスト表示（選択可能）。
class _StreamTextBlock extends StatelessWidget {
  const _StreamTextBlock({required this.text, this.muted = false});
  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: SelectableText(
        text.isEmpty ? '…' : text,
        style: TextStyle(
          color: muted ? Colors.white38 : Colors.white,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}
