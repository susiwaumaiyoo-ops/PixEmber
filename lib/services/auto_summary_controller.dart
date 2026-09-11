// Phase 9-B2: 自動要約の「実行主体」と「UI表示」を分ける境界。
//
// 設計方針（BRIEF.md / ユーザー承認構成）:
// - 正本スナップショット（AutoSummarySnapshot）は実行主体（B2-3=in-process実装、
//   B2-4以降=FGS TaskHandler側 FlutterEngine）が1つだけ保持し、件数は items から
//   毎回導出する（独立カウンタを持たない → 二重計上を構造的に防止）。
// - UI isolate / 設定カード / 詳細画面は [AutoSummaryController.state] を購読して
//   「表示するだけ」。状態変更の命令（run/pause/resume/stop）も必ずこの共通
//   インターフェース経由とし、通知アクションと画面ボタンが同一メソッドを呼ぶ。
// - engine 間移行時はこの実装だけを差し替える（ValueNotifier / ネイティブポインタ /
//   Service 実体は engine 間で共有しない — Map スナップショットのみ受け渡す）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;

import 'auto_summary_snapshot.dart';

/// 自動要約の実行制御インターフェース。
abstract class AutoSummaryController {
  /// 表示用の購読ポイント。必ず [AutoSummarySnapshotBatcher] で 250〜500ms に
  /// バッチング済み（端末負荷・再構築抑制）。terminal phase では即時反映。
  ValueListenable<AutoSummarySnapshot> get state;

  /// 同期した最新のスナップショット（正本）。表示バッチではなく実状態。
  AutoSummarySnapshot get current;

  /// 「今すぐ実行」。実行中・予約済みの場合は二重起動しない（idempotent）。
  void runNow();

  /// 一時停止。停止処理中は多重の停止要求を無視する。
  void pause();

  /// 再開（一時停止中のみ意味を持つ）。
  void resume();

  /// 今回の処理を終了（キューを打ち切って後始末）。多重終了要求は無視。
  void stop();

  void dispose();
}

/// 実行主体の種類に依らず共通の UI 文言・アイコン（色に依存せず状態を判別）。
String autoSummaryPhaseLabel(AutoSummaryPhase phase) {
  switch (phase) {
    case AutoSummaryPhase.disabled:
      return '無効';
    case AutoSummaryPhase.scheduled:
      return '実行予約済み';
    case AutoSummaryPhase.waitingCondition:
      return '条件待ち';
    case AutoSummaryPhase.fetchingCandidates:
      return '候補取得中';
    case AutoSummaryPhase.preparingModel:
      return 'モデル準備中';
    case AutoSummaryPhase.fetchingBody:
      return '本文取得中';
    case AutoSummaryPhase.parsingBody:
      return '本文解析中';
    case AutoSummaryPhase.integratingPoints:
      return '要点統合中';
    case AutoSummaryPhase.saving:
      return '保存中';
    case AutoSummaryPhase.coolingDown:
      return 'クールダウン中';
    case AutoSummaryPhase.pausing:
      return '一時停止処理中';
    case AutoSummaryPhase.paused:
      return '一時停止中';
    case AutoSummaryPhase.finishing:
      return '終了処理中';
    case AutoSummaryPhase.completed:
      return '完了';
    case AutoSummaryPhase.completedWithErrors:
      return '一部失敗で完了';
    case AutoSummaryPhase.error:
      return 'エラー';
  }
}

/// 「実行中 / 待機中 / 停止中」の3区分ラベル（設定カードの要約表示用・§3-A）。
String autoSummaryRunStateLabel(AutoSummarySnapshot s) {
  if (s.phase == AutoSummaryPhase.disabled) return '停止中';
  if (s.phase == AutoSummaryPhase.paused) return '停止中';
  if (s.isRunning) {
    // 条件待ち・予約・クールダウンは「待機中」に寄せる。
    if (s.phase == AutoSummaryPhase.scheduled ||
        s.phase == AutoSummaryPhase.waitingCondition ||
        s.phase == AutoSummaryPhase.coolingDown) {
      return '待機中';
    }
    return '実行中';
  }
  // completed / completedWithErrors / error は直前まで動いていた = 停止扱い。
  return '停止中';
}

IconData autoSummaryPhaseIcon(AutoSummaryPhase phase) {
  switch (phase) {
    case AutoSummaryPhase.disabled:
      return Icons.remove_circle_outline;
    case AutoSummaryPhase.scheduled:
      return Icons.schedule;
    case AutoSummaryPhase.waitingCondition:
      return Icons.hourglass_top;
    case AutoSummaryPhase.fetchingCandidates:
      return Icons.search;
    case AutoSummaryPhase.preparingModel:
      return Icons.memory;
    case AutoSummaryPhase.fetchingBody:
      return Icons.article_outlined;
    case AutoSummaryPhase.parsingBody:
      return Icons.psychology_alt_outlined;
    case AutoSummaryPhase.integratingPoints:
      return Icons.merge_type;
    case AutoSummaryPhase.saving:
      return Icons.save_outlined;
    case AutoSummaryPhase.coolingDown:
      return Icons.self_improvement;
    case AutoSummaryPhase.pausing:
      return Icons.pause_circle_filled;
    case AutoSummaryPhase.paused:
      return Icons.pause_circle_outline;
    case AutoSummaryPhase.finishing:
      return Icons.stop_circle_outlined;
    case AutoSummaryPhase.completed:
      return Icons.check_circle_outline;
    case AutoSummaryPhase.completedWithErrors:
      return Icons.error_outline;
    case AutoSummaryPhase.error:
      return Icons.error;
  }
}

/// 現在のスナップショットから「1行の状況説明」を生成（§3-A/§1）。
/// 条件待ちは理由文を優先表示する。
String autoSummaryStatusLabel(AutoSummarySnapshot s) {
  if (s.phase == AutoSummaryPhase.waitingCondition &&
      s.waitReason != AutoSummaryWaitReason.none) {
    return s.waitReason.userMessage;
  }
  final label = autoSummaryPhaseLabel(s.phase);
  if (s.phase.isActive && s.workStage != AutoSummaryWorkStage.none) {
    final chunk = s.chunkTotal > 0 && s.chunkCurrent > 0
        ? ' ${s.chunkCurrent}/${s.chunkTotal}ブロック'
        : '';
    return '$label・${s.workStage.label}$chunk';
  }
  return label;
}

/// 生スナップショット購読を 250〜500ms にバッチングし、terminal では即時に
/// 反映する小型スロットル。§3-D（per-token 更新で UI を壊さない）。
class AutoSummarySnapshotBatcher {
  AutoSummarySnapshotBatcher({
    required ValueListenable<AutoSummarySnapshot> source,
    this.interval = const Duration(milliseconds: 300),
  }) : _source = source {
    _out.value = source.value;
    _source.addListener(_onChange);
  }

  final ValueListenable<AutoSummarySnapshot> _source;
  final Duration interval;
  final ValueNotifier<AutoSummarySnapshot> _out =
      ValueNotifier<AutoSummarySnapshot>(const AutoSummarySnapshot());

  Timer? _gap;
  AutoSummarySnapshot? _pending;

  ValueListenable<AutoSummarySnapshot> get listenable => _out;

  AutoSummarySnapshot get latest => _out.value;

  void _onChange() {
    final s = _source.value;
    // 終端状態（完了/失敗/エラー/無効）は待ち合わせず即時反映。
    if (s.phase.isTerminal) {
      _gap?.cancel();
      _gap = null;
      _pending = null;
      _out.value = s;
      return;
    }
    if (_gap == null) {
      // 直前の出力から interval 空いていれば即出す。
      _out.value = s;
      _gap = Timer(interval, _flush);
    } else {
      // 窓内に到着したものは最後の1つだけ残してまとめる。
      _pending = s;
    }
  }

  void _flush() {
    _gap = null;
    final p = _pending;
    if (p != null) {
      _pending = null;
      _out.value = p;
      _gap = Timer(interval, _flush);
    }
  }

  void dispose() {
    _gap?.cancel();
    _gap = null;
    _source.removeListener(_onChange);
    _out.dispose();
  }
}
