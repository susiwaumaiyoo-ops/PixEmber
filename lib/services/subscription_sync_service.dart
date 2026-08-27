import 'package:flutter/foundation.dart';

import 'database_service.dart';
import 'pixiv_api_service.dart';

/// 購読タグごとの新着チェック結果。
class SubscriptionSyncOneResult {
  final int id;
  final bool success;
  final int newCount;
  final String? lastCheckedAt;
  final String? lastNewestDate;
  final String? errorMessage;

  SubscriptionSyncOneResult._({
    required this.id,
    required this.success,
    this.newCount = 0,
    this.lastCheckedAt,
    this.lastNewestDate,
    this.errorMessage,
  });

  factory SubscriptionSyncOneResult.ok(
    int id,
    int newCount,
    String lastCheckedAt,
    String? lastNewestDate,
  ) => SubscriptionSyncOneResult._(
    id: id,
    success: true,
    newCount: newCount,
    lastCheckedAt: lastCheckedAt,
    lastNewestDate: lastNewestDate,
  );

  factory SubscriptionSyncOneResult.error(int id, String message) =>
      SubscriptionSyncOneResult._(
        id: id,
        success: false,
        errorMessage: message,
      );
}

/// 全タグ一括チェックの集計。
class SubscriptionSyncSummary {
  final int ok;
  final int error;
  final int totalNew;
  SubscriptionSyncSummary({
    required this.ok,
    required this.error,
    required this.totalNew,
  });
}

/// 購読タグの新着チェック（ローカル SQLite + Pixiv 検索）を担うサービス。
///
/// - 各タグを 1 件ずつ検索（逐次）、リクエスト間に短いディレイでレートリミット配慮。
/// - タグ単位で try-catch し、1 タグ失敗でも全体は止めない。
/// - 新着判定: 前回保存の last_newest_date より新しい create_date の件数。
///   初回（last_newest_date が未設定）は最新日時を保存し、新着は 0 扱い。
class SubscriptionSyncService {
  // 各タグの検索は API デフォルト（先頭最大30件程度）を新着順で取得する。
  static const Duration _interTagDelay = Duration(milliseconds: 400);

  static final SubscriptionSyncService _instance = SubscriptionSyncService._();
  factory SubscriptionSyncService() => _instance;
  SubscriptionSyncService._();

  /// 1 タグをチェックして subscribed_tags を更新する。
  Future<SubscriptionSyncOneResult> checkTag(Map<String, dynamic> tag) async {
    final int? id = tag['id'] as int?;
    final String name = (tag['tag'] as String? ?? '').toString();
    final String type = (tag['type'] as String? ?? 'illust').toString();
    final String? lastNewestDate = tag['last_newest_date'] as String?;

    if (id == null || name.isEmpty) {
      return SubscriptionSyncOneResult.error(
        id ?? -1,
        'タグ情報が不正です（id=$id, name=$name）',
      );
    }

    try {
      final api = PixivApiService();
      List<String> createDates;
      // 新着キャッシュ保存用の軽量スナップショット
      final snapshots = <Map<String, dynamic>>[];
      if (type == 'novel') {
        final res = await api.searchNovel(
          name,
          'partial_match_for_tags',
          'date_desc',
          0,
          'all',
          null,
          null,
        );
        createDates = res.items
            .map((n) => n.createDate)
            .where((d) => d.isNotEmpty)
            .toList();
        for (final n in res.items) {
          snapshots.add({
            'work_id': n.id,
            'type': 'novel',
            'title': n.title,
            'author_name': n.author.name,
            // 一覧表示用サムズネイル（medium/square_medium 相当）
            'preview_url': n.coverUrl,
            'create_date': n.createDate,
            'x_restrict': n.xRestrict,
          });
        }
      } else {
        final res = await api.searchIllust(
          name,
          'partial_match_for_tags',
          'date_desc',
          0,
          'all',
        );
        createDates = res.items
            .map((i) => i.createDate)
            .where((d) => d.isNotEmpty)
            .toList();
        for (final i in res.items) {
          snapshots.add({
            'work_id': i.id,
            'type': 'illust',
            'title': i.title,
            'author_name': i.author.name,
            'preview_url': i.urls.preview ?? '',
            'create_date': i.createDate,
            'x_restrict': i.xRestrict,
          });
        }
      }

      final String now = DateTime.now().toUtc().toIso8601String();

      // 有効な日付のみ抽出して新着判定
      final dates = createDates
          .map(_parseDate)
          .where((d) => d != null)
          .cast<DateTime>()
          .toList();

      if (dates.isEmpty) {
        // 作品が見つからない場合: チェック時刻のみ更新、新着 0
        await DatabaseService().updateSubscribedTagCheck(
          id,
          lastCheckedAt: now,
          lastNewestDate: lastNewestDate,
          lastNewCount: 0,
        );
        return SubscriptionSyncOneResult.ok(id, 0, now, lastNewestDate);
      }

      // 最新作品の create_date（UTC で統一保存）
      final DateTime newest = dates.reduce((a, b) => a.isAfter(b) ? a : b);
      final String newestIso = newest.toUtc().toIso8601String();

      int newCount;
      if (lastNewestDate == null || lastNewestDate.isEmpty) {
        // 初回: 新着 0 扱い
        newCount = 0;
      } else {
        final DateTime? base = _parseDate(lastNewestDate);
        newCount = base == null
            ? dates.length
            : dates.where((d) => d.isAfter(base)).length;
      }

      // 新着と判定した作品をキャッシュに保存する。
      // 保存の失敗はチェック全体を落とさない。
      if (newCount > 0) {
        try {
          final DateTime? base = _parseDate(lastNewestDate);
          final newItems = snapshots.where((s) {
            final d = _parseDate(s['create_date'] as String?);
            if (d == null) return false;
            return base == null || d.isAfter(base);
          }).toList();
          await DatabaseService().insertSubscriptionNewItems(id, newItems);
        } catch (e) {
          debugPrint('[SubscriptionSync] 新着キャッシュ保存に失敗: $e');
        }
      }

      await DatabaseService().updateSubscribedTagCheck(
        id,
        lastCheckedAt: now,
        lastNewestDate: newestIso,
        lastNewCount: newCount,
      );
      return SubscriptionSyncOneResult.ok(id, newCount, now, newestIso);
    } catch (e) {
      return SubscriptionSyncOneResult.error(id, e.toString());
    }
  }

  /// 全タグを逐次チェックする。onResult で進捗ごとに通知。
  Future<SubscriptionSyncSummary> syncAll(
    List<Map<String, dynamic>> tags, {
    void Function(SubscriptionSyncOneResult)? onResult,
  }) async {
    int ok = 0;
    int error = 0;
    int totalNew = 0;
    for (int i = 0; i < tags.length; i++) {
      final r = await checkTag(tags[i]);
      if (r.success) {
        ok++;
        totalNew += r.newCount;
      } else {
        error++;
      }
      onResult?.call(r);
      if (i < tags.length - 1) {
        await Future.delayed(_interTagDelay);
      }
    }
    return SubscriptionSyncSummary(ok: ok, error: error, totalNew: totalNew);
  }

  DateTime? _parseDate(String? d) {
    if (d == null || d.isEmpty) return null;
    try {
      return DateTime.parse(d);
    } catch (_) {
      return null;
    }
  }
}
