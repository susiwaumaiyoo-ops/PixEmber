// モデルライブラリカード（M3）。
//
// 純粋表示ウィジェット。データのマッピングは画面側（llm_model_library_screen）
// が行う。3 形態（推奨: 未ダウンロード / ダウンロード済み / カスタム: 取り込み）
// をサポートする。

import 'package:flutter/material.dart';

class LlmModelCard extends StatelessWidget {
  const LlmModelCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.description,
    this.badge,
    this.warning,
    this.isSelected = false,
    this.onDownload,
    this.onSelect,
    this.onDetails,
  });

  final String title;
  final String subtitle;
  final String? description;

  /// 状態バッジ（「推奨」「ダウンロード済み」「カスタム」等）。
  final String? badge;

  /// 警告テキスト（高 RAM 要件など）。
  final String? warning;

  final bool isSelected;
  final VoidCallback? onDownload;
  final VoidCallback? onSelect;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF2B222B) : const Color(0xFF242424),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? Colors.pinkAccent.withValues(alpha: 0.8)
              : Colors.white12,
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
                  style: const TextStyle(
                    color: Colors.white,
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
                        ? Colors.pinkAccent.withValues(alpha: 0.2)
                        : const Color(0xFF333333),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      color: isSelected ? Colors.pinkAccent : Colors.white70,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (warning != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    warning!,
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (description != null && description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              description!,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                height: 1.4,
              ),
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
                    backgroundColor: Colors.pinkAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('ダウンロード', style: TextStyle(fontSize: 13)),
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
