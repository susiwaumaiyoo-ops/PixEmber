// モデルライブラリカード（M3 / M4 でダウンロード進捗表示を追加）。
//
// 純粋表示ウィジェット。データのマッピングは画面側（llm_model_library_screen）
// が行う。3 形態（推奨: 未ダウンロード / ダウンロード済み / カスタム: 取り込み）
// をサポートし、ダウンロード中は進捗バーとキャンセルボタン、
// 失敗・キャンセル後は再試行ボタンを表示する。

import 'package:flutter/material.dart';

class LlmModelCard extends StatelessWidget {
  const LlmModelCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.description,
    this.badge,
    this.npuBadge,
    this.warning,
    this.error,
    this.progress,
    this.progressLabel,
    this.isSelected = false,
    this.onDownload,
    this.onRetry,
    this.onCancel,
    this.onSelect,
    this.onDetails,
  });

  final String title;
  final String subtitle;
  final String? description;

  /// 状態バッジ（「推奨」「ダウンロード済み」「カスタム」等）。
  final String? badge;

  /// NPU 対応バッジ（C-3）。true=⚡NPU対応 / false=⚠️CPU実行 / null=不明で非表示。
  final bool? npuBadge;

  /// 警告テキスト（高 RAM 要件など）。
  final String? warning;

  /// エラーテキスト（ダウンロード失敗など）。
  final String? error;

  /// 進捗（0.0-1.0）。null の場合は進捗バーを表示しない。
  final double? progress;

  /// 進捗ラベル（例: 'ダウンロード中 42%（…）'）。
  final String? progressLabel;

  final bool isSelected;
  final VoidCallback? onDownload;

  /// 再試行（failed / cancelled 時）。
  final VoidCallback? onRetry;

  /// キャンセル（待機中・実行中）。
  final VoidCallback? onCancel;

  final VoidCallback? onSelect;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.surfaceContainerHigh
            : colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? colorScheme.primary.withValues(alpha: 0.8)
              : colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? colorScheme.primary.withValues(alpha: 0.2)
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
              if (npuBadge != null) ...[
                const SizedBox(width: 6),
                _NpuChip(npuCompatible: npuBadge!),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          ),
          if (warning != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: colorScheme.tertiary,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    warning!,
                    style: TextStyle(color: colorScheme.tertiary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
          if (description != null && description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              description!,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
          if (progress != null) ...[
            const SizedBox(height: 10),
            ClipRect(
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
            if (progressLabel != null) ...[
              const SizedBox(height: 4),
              Text(
                progressLabel!,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 11.5,
                ),
              ),
            ],
          ],
          if (error != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.error_outline, size: 14, color: colorScheme.error),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    error!,
                    style: TextStyle(color: colorScheme.error, fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onDownload != null)
                FilledButton.icon(
                  onPressed: onDownload,
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('ダウンロード', style: TextStyle(fontSize: 13)),
                ),
              if (onRetry != null)
                FilledButton.icon(
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('再試行', style: TextStyle(fontSize: 13)),
                ),
              if (onSelect != null)
                OutlinedButton(
                  onPressed: isSelected ? null : onSelect,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isSelected
                        ? Colors.pinkAccent
                        : Colors.white70,
                    side: BorderSide(
                      color: isSelected ? Colors.pinkAccent : Colors.white30,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                  child: Text(
                    isSelected ? '現在のモデル' : 'モデルとして選択',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              if (onCancel != null)
                OutlinedButton(
                  onPressed: onCancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orangeAccent,
                    side: const BorderSide(color: Colors.orangeAccent),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                  child: const Text('キャンセル', style: TextStyle(fontSize: 13)),
                ),
              if (onDetails != null)
                TextButton(
                  onPressed: onDetails,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                  child: const Text('詳細', style: TextStyle(fontSize: 13)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// NPU 対応/非対応の小さなバッジチップ（C-3）。
class _NpuChip extends StatelessWidget {
  const _NpuChip({required this.npuCompatible});

  final bool npuCompatible;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = npuCompatible ? colorScheme.secondary : colorScheme.tertiary;
    final label = npuCompatible ? '⚡ NPU対応' : '⚠️ CPU実行';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 10.5)),
    );
  }
}
