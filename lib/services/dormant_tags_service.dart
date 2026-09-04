// 最近読んでいないタグ（感動機能パック Phase E2）。
//
// 設計:
// - history テーブルから「いつ・どの作品を読んだか」を取得。
// - タグは history に保存されていないため、novels/illusts の tags_json を
//   UNION ALL で取得し work_id と紐付ける（reading_trends_service と同手法）。
// - 純粋関数 pickDormantTags で「過去よく読んだのに最近読んでいない」タグを抽出。
// - ネットワーク通信は行わない。DB 空/失敗時は空リスト（UI は空状態を表示）。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// 最近読んでいないタグの情報（Phase E2）。
class DormantTagInfo {
  final String tag;
  final int pastCount;
  final int recentCount;
  final int daysSinceLast;
  final double score;

  const DormantTagInfo({
    required this.tag,
    required this.pastCount,
    required this.recentCount,
    required this.daysSinceLast,
    required this.score,
  });
}

/// タグごとの集計（pickDormantTags の入力）。
class TagReadStat {
  final int pastCount;
  final int recentCount;
  final DateTime lastSeen;

  const TagReadStat({
    required this.pastCount,
    required this.recentCount,
    required this.lastSeen,
  });
}

/// 最近読んでいないタグを抽出する純粋関数。
///
/// [stats]: タグごとの過去/最近出現回数と最終閲覧日。
/// 条件: 過去出現 >= [minPast] かつ 最近出現 <= [maxRecent]。
/// スコア = (past - recent)*1000 + 経過日数（大きい順、上位 [maxItems]）。
List<DormantTagInfo> pickDormantTags(
  Map<String, TagReadStat> stats, {
  int minPast = 3,
  int maxRecent = 1,
  int maxItems = 12,
  DateTime? now,
}) {
  final n = now ?? DateTime.now();
  final result = <DormantTagInfo>[];
  for (final e in stats.entries) {
    final past = e.value.pastCount;
    final recent = e.value.recentCount;
    if (past < minPast) continue;
    if (recent > maxRecent) continue;
    final days = n.difference(e.value.lastSeen).inDays;
    final score = (past - recent) * 1000.0 + days.toDouble();
    result.add(
      DormantTagInfo(
        tag: e.key,
        pastCount: past,
        recentCount: recent,
        daysSinceLast: days,
        score: score,
      ),
    );
  }
  result.sort((a, b) => b.score.compareTo(a.score));
  if (result.length > maxItems) return result.sublist(0, maxItems);
  return result;
}

/// 最近読んでいないタグ取得サービス（シングルトン）。
class DormantTagsService {
  DormantTagsService._internal();
  static final DormantTagsService _instance = DormantTagsService._internal();
  factory DormantTagsService() => _instance;

  Future<List<DormantTagInfo>> fetch({DateTime? now}) async {
    try {
      final db = DatabaseService();
      final history = await db.getHistoryList();
      final rawDb = await db.database;
      final tagRows = await rawDb.rawQuery(
        'SELECT id, tags_json FROM novels '
        'UNION ALL SELECT id, tags_json FROM illusts',
      );
      final tagsByWork = <int, List<String>>{};
      for (final r in tagRows) {
        final id = (r['id'] as int?) ?? 0;
        if (id <= 0) continue;
        final tags = _parseTags(r['tags_json'] as String?);
        if (tags.isNotEmpty) tagsByWork[id] = tags;
      }

      final countByWork = <int, int>{};
      final lastSeenByWork = <int, DateTime>{};
      for (final h in history) {
        final workId = (h['work_id'] as int?) ?? 0;
        if (workId <= 0) continue;
        final dt = _parseLocal(h['created_at'] as String?);
        if (dt == null) continue;
        countByWork[workId] = (countByWork[workId] ?? 0) + 1;
        final prev = lastSeenByWork[workId];
        if (prev == null || dt.isAfter(prev)) lastSeenByWork[workId] = dt;
      }

      final now0 = now ?? DateTime.now();
      final recentCutoff = now0.subtract(const Duration(days: 30));
      final agg = <String, _TagAgg>{};
      for (final e in countByWork.entries) {
        final tags = tagsByWork[e.key];
        if (tags == null || tags.isEmpty) continue;
        final lastSeen = lastSeenByWork[e.key] ?? now0;
        final isRecent = !lastSeen.isBefore(recentCutoff);
        for (final tag in tags) {
          final a = agg.putIfAbsent(tag, _TagAgg.new);
          if (isRecent) {
            a.recent += e.value;
          } else {
            a.past += e.value;
          }
          if (a.lastSeen == null || lastSeen.isAfter(a.lastSeen!)) {
            a.lastSeen = lastSeen;
          }
        }
      }

      final statMap = <String, TagReadStat>{};
      for (final e in agg.entries) {
        if (e.value.lastSeen == null) continue;
        statMap[e.key] = TagReadStat(
          pastCount: e.value.past,
          recentCount: e.value.recent,
          lastSeen: e.value.lastSeen!,
        );
      }
      return pickDormantTags(statMap, now: now0);
    } catch (e) {
      debugPrint('最近読んでいないタグの取得に失敗（空状態）: $e');
      return const [];
    }
  }

  static List<String> _parseTags(String? json) {
    if (json == null || json.trim().isEmpty) return const [];
    try {
      final v = jsonDecode(json);
      if (v is List) return v.whereType<String>().toList();
    } catch (_) {}
    return json
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static DateTime? _parseLocal(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }
}

class _TagAgg {
  int past = 0;
  int recent = 0;
  DateTime? lastSeen;
}
