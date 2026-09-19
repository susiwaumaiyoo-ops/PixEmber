// Phase 9-B2: 自動要約の進捗ダッシュボード（詳細画面・§3-B/§3-C）。
//
// - この画面は AutoSummaryController.state（バッチング済み）を購読して「表示するだけ」。
//   件数は正本スナップショットの items から毎回導出し、画面側にカウンタを持たない。
// - 全体状態＋件数 / 現作品＋段階（チャンク x/y・トークン不定進捗の区別）/
//   タグ別内訳（§2-B、総数未取得を正直表示 §2-C）/ 今回の処理リスト / 診断。
// - アクション（今すぐ実行・一時停止/再開・終了）は controller の共通メソッドを
//   呼ぶだけ。二重押下は controller 側で idempotent に抑止される。
// - 色に依存せずアイコン＋テキストで状態を判別（§3-D）。
import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../widgets/design_system/app_panel.dart';
import '../widgets/design_system/app_section_header.dart';
import '../services/auto_summary_controller.dart';
import '../services/auto_summary_snapshot.dart';

/// 自動要約の進捗詳細画面。
class AutoSummaryStatusScreen extends StatelessWidget {
  const AutoSummaryStatusScreen({
    super.key,
    required this.controller,
    this.onOpenSavedWork,
  });

  final AutoSummaryController controller;

  /// 完了作品をタップしたときの導線（保存済み要約/詳細）。null ならタップ不可。
  final void Function(int workId)? onOpenSavedWork;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        foregroundColor: colorScheme.onSurface,
        title: const Text('自動要約の状況'),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<AutoSummarySnapshot>(
          valueListenable: controller.state,
          builder: (context, s, _) {
            return RefreshIndicator(
              onRefresh: () async {},
              color: colorScheme.primary,
              backgroundColor: colorScheme.surfaceContainer,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                children: [
                  _HeaderCard(controller: controller, snapshot: s),
                  _CountsCard(snapshot: s),
                  _CurrentWorkCard(snapshot: s),
                  _TagStatsSection(snapshot: s),
                  _ItemListSection(snapshot: s, onOpen: onOpenSavedWork),
                  _DiagnosticsSection(snapshot: s),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ヘッダー：全体状態＋アクション（§3-B）
// ---------------------------------------------------------------------------
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.controller, required this.snapshot});

  final AutoSummaryController controller;
  final AutoSummarySnapshot snapshot;

  bool get _canPause =>
      snapshot.isRunning && snapshot.phase != AutoSummaryPhase.paused;
  bool get _canResume => snapshot.phase == AutoSummaryPhase.paused;
  bool get _canRun => !snapshot.isRunning;
  bool get _canStop => snapshot.isRunning;

  /// 「今すぐ実行」: controller.runNow()（内部で ensureServiceReady）を呼び、
  /// 失敗時はユーザーに見えるフィードバックを出す（無反応を禁止）。
  Future<void> _onRun(BuildContext context) async {
    final ok = await controller.runNow();
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('自動要約サービスの起動に失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(autoSummaryPhaseIcon(s.phase), color: colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  autoSummaryRunStateLabel(s),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm - 2),
          Text(
            autoSummaryStatusLabel(s),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (s.stopReason != null && s.stopReason!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              s.stopReason!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.tertiary,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md + 2),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  disabledBackgroundColor: colorScheme.surfaceContainerHighest,
                ),
                onPressed: _canRun ? () => _onRun(context) : null,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('今すぐ実行'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.onSurfaceVariant,
                  side: BorderSide(color: colorScheme.outlineVariant),
                ),
                onPressed: _canPause
                    ? controller.pause
                    : (_canResume ? controller.resume : null),
                icon: Icon(
                  _canResume
                      ? Icons.play_circle_outline
                      : Icons.pause_circle_outline,
                  size: 18,
                ),
                label: Text(_canResume ? '再開' : '一時停止'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.error,
                  side: BorderSide(color: colorScheme.error),
                ),
                onPressed: _canStop ? controller.stop : null,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('今回の処理を終了'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 件数カード：全体（§2-A invariant をそのまま表示）
// ---------------------------------------------------------------------------
class _CountsCard extends StatelessWidget {
  const _CountsCard({required this.snapshot});

  final AutoSummarySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '対象 ${s.targetCount}件 ＝ 保存 ${s.savedCount} ＋ 処理中 ${s.processingCount} ＋ 待ち ${s.waitingCount} ＋ 失敗 ${s.failedCount} ＋ スキップ ${s.skippedCount}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _CountChip(
                label: '保存済',
                value: s.savedCount,
                icon: Icons.check_circle_outline,
                color: colorScheme.primaryContainer,
              ),
              _CountChip(
                label: '処理中',
                value: s.processingCount,
                icon: Icons.autorenew,
                color: colorScheme.tertiary,
              ),
              _CountChip(
                label: '待ち',
                value: s.waitingCount,
                icon: Icons.hourglass_empty,
                color: colorScheme.onSurfaceVariant,
              ),
              _CountChip(
                label: '失敗',
                value: s.failedCount,
                icon: Icons.error_outline,
                color: colorScheme.error,
              ),
              _CountChip(
                label: 'スキップ',
                value: s.skippedCount,
                icon: Icons.skip_next,
                color: colorScheme.outlineVariant,
              ),
            ],
          ),
          if (s.targetCount > 0) ...[
            const SizedBox(height: AppSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: s.savedCount / s.targetCount,
                minHeight: 8,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final int value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 2),
          Text(
            '$value',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 現作品＋段階（§3-C）: 実段階に基づく micro 進捗。統合・保存を残して 100% にならない。
// ---------------------------------------------------------------------------
class _CurrentWorkCard extends StatelessWidget {
  const _CurrentWorkCard({required this.snapshot});

  final AutoSummarySnapshot snapshot;

  /// micro 進捗の分子（0..steps）。統合・保存を進行に含めるが
  /// 完了判定は items の saved のみ（ここは「現作品」の見た目進捗）。
  double? get _workProgress {
    final s = snapshot;
    if (s.currentWorkId == null || s.workStage == AutoSummaryWorkStage.none) {
      return null;
    }
    // 段階を 5 ステップ（取得/準備/解析/統合/保存）で見る。
    final order = const [
      AutoSummaryWorkStage.bodyFetch,
      AutoSummaryWorkStage.modelPrepare,
      AutoSummaryWorkStage.bodyParse,
      AutoSummaryWorkStage.pointMerge,
      AutoSummaryWorkStage.save,
    ];
    final stageIdx = order.indexOf(s.workStage);
    if (stageIdx < 0) return null;
    final steps = order.length;
    // 解析段階のみチャンク細分（map完了＝解析満了でも統合・保存が残るので1未満）。
    final chunkFrac =
        (s.workStage == AutoSummaryWorkStage.bodyParse && s.chunkTotal > 0)
        ? (s.chunkCurrent / s.chunkTotal).clamp(0.0, 1.0) * 0.99
        : 0.0;
    return ((stageIdx + chunkFrac) / steps).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    if (s.currentWorkId == null && !s.phase.isActive) {
      return const SizedBox.shrink();
    }
    final title = s.currentWorkTitle ?? '（作品名は非表示）';
    final progress = _workProgress;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '現在の処理',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            title,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.sm - 2),
          Row(
            children: [
              Icon(
                autoSummaryPhaseIcon(s.phase),
                size: 16,
                color: colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm - 2),
              Expanded(
                child: Text(
                  s.workStage == AutoSummaryWorkStage.none
                      ? autoSummaryPhaseLabel(s.phase)
                      : s.workStage.label +
                            (s.chunkTotal > 0 && s.chunkCurrent > 0
                                ? ' ${s.chunkCurrent}/${s.chunkTotal}ブロック'
                                : ''),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md - 2),
          if (progress != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            )
          else
            SizedBox(
              height: 6,
              child: LinearProgressIndicator(
                minHeight: 6,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
          const SizedBox(height: AppSpacing.sm - 2),
          Text(
            progress == null
                ? '進捗は取得できません（推定なし）'
                : '（統合・保存が完了するまで 100% にはなりません）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (s.modelLabel != null || s.backendName != null) ...[
            const SizedBox(height: AppSpacing.sm - 2),
            Text(
              'モデル: ${s.modelLabel ?? '—'} / バックエンド: ${s.backendName ?? '—'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// タグ別内訳（§2-B / §2-C）
// ---------------------------------------------------------------------------
class _TagStatsSection extends StatelessWidget {
  const _TagStatsSection({required this.snapshot});

  final AutoSummarySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final stats = snapshot.tagStats;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (stats.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: 'タグ別内訳',
      child: Column(
        children: [
          for (final t in stats)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm - 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '#${t.tag}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs - 1),
                  Text(
                    '確認 ${t.candidatesChecked}件 / 既存 ${t.existingValid}件 / 生成 ${t.generatedSaved}件 / 失敗 ${t.failed}件',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    _candidateNote(t),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: t.hasMoreCandidates
                          ? colorScheme.tertiary
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// §2-C: タグ総数は API が返さないため断定しない。既知のみ表示。
  String _candidateNote(AutoSummaryTagStat t) {
    final parts = <String>[];
    if (t.hasMoreCandidates) {
      parts.add('追加候補あり');
    } else {
      parts.add('追加候補なし');
    }
    if (t.reachedSessionLimit) parts.add('今回上限に到達');
    parts.add('タグ総数: 未取得');
    return parts.join(' / ');
  }
}

// ---------------------------------------------------------------------------
// 今回の処理リスト
// ---------------------------------------------------------------------------
class _ItemListSection extends StatelessWidget {
  const _ItemListSection({required this.snapshot, this.onOpen});

  final AutoSummarySnapshot snapshot;
  final void Function(int workId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final items = snapshot.items;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (items.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: '今回の処理対象（${items.length}件）',
      child: Column(
        children: [
          for (final it in items)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
              ),
              leading: _statusIcon(it.status, colorScheme),
              title: Text(
                it.title.isEmpty ? '作品 ${it.workId}' : it.title,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: it.errorReason != null
                  ? Text(
                      it.errorReason!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                      ),
                    )
                  : Text(
                      it.tags.map((e) => '#$e').join(' '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
              onTap: it.status == AutoSummaryItemStatus.saved && onOpen != null
                  ? () => onOpen!(it.workId)
                  : null,
              trailing: Text(
                _statusLabel(it.status),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _statusColor(it.status, colorScheme),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusIcon(AutoSummaryItemStatus st, ColorScheme colorScheme) {
    return Icon(
      _statusIconData(st),
      color: _statusColor(st, colorScheme),
      size: 20,
    );
  }

  IconData _statusIconData(AutoSummaryItemStatus st) {
    switch (st) {
      case AutoSummaryItemStatus.waiting:
        return Icons.hourglass_empty;
      case AutoSummaryItemStatus.processing:
        return Icons.autorenew;
      case AutoSummaryItemStatus.saved:
        return Icons.check_circle_outline;
      case AutoSummaryItemStatus.failed:
        return Icons.error_outline;
      case AutoSummaryItemStatus.skipped:
        return Icons.skip_next;
    }
  }

  String _statusLabel(AutoSummaryItemStatus st) {
    switch (st) {
      case AutoSummaryItemStatus.waiting:
        return '待ち';
      case AutoSummaryItemStatus.processing:
        return '処理中';
      case AutoSummaryItemStatus.saved:
        return '保存済';
      case AutoSummaryItemStatus.failed:
        return '失敗';
      case AutoSummaryItemStatus.skipped:
        return 'スキップ';
    }
  }

  Color _statusColor(AutoSummaryItemStatus st, ColorScheme colorScheme) {
    switch (st) {
      case AutoSummaryItemStatus.waiting:
        return colorScheme.onSurfaceVariant;
      case AutoSummaryItemStatus.processing:
        return colorScheme.tertiary;
      case AutoSummaryItemStatus.saved:
        return colorScheme.primaryContainer;
      case AutoSummaryItemStatus.failed:
        return colorScheme.error;
      case AutoSummaryItemStatus.skipped:
        return colorScheme.outlineVariant;
    }
  }
}

// ---------------------------------------------------------------------------
// 診断（折りたたみ）— 本文/トークン/認証は含めない。
// ---------------------------------------------------------------------------
class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection({required this.snapshot});

  final AutoSummarySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return _Section(
      title: '診断（タップで展開）',
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
        iconColor: colorScheme.onSurfaceVariant,
        collapsedIconColor: colorScheme.onSurfaceVariant,
        textColor: colorScheme.onSurfaceVariant,
        title: Text('実行詳細', style: theme.textTheme.bodySmall),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: SelectableText(
                [
                  'runId: ${s.runId}',
                  '段階: ${autoSummaryPhaseLabel(s.phase)}',
                  if (s.waitReason != AutoSummaryWaitReason.none)
                    '待機理由: ${s.waitReason.userMessage}',
                  '開始: ${_fmt(s.startedAtMillis)}',
                  '最終更新: ${_fmt(s.updatedAtMillis)}',
                  if (s.currentTag != null) '現タグ: #${s.currentTag}',
                  '取得済み候補: ${s.candidatesFetched}件',
                  '追加候補: ${s.hasMoreCandidates ? 'あり' : 'なし'}',
                  if (s.cooldownUntilMillis > 0)
                    'クールダウン終了予定: ${_fmt(s.cooldownUntilMillis)}',
                ].join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(int millis) {
    if (millis == 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}/${two(dt.month)}/${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: AppPanel(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSectionHeader(title),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}
