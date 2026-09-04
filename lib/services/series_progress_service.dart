// 小説シリーズ追跡サービス（非AI機能パック Phase N3）。
//
// series_id / series_order / read_later / 読書進捗（しおり）から
// 「次の未読話」「読了数 / 全体数」「残り読了目安」を算出する。
//
// 設計:
// - 判定・集計はすべて純粋関数として分離し、DB/UI 無しでテスト可能。
// - エピソード一覧は PixivApiService.getNovelSeries を再利用（既存のシリーズ自動遷移と同一ソース）。
// - サーバー送信なし。端末ローカルデータ（read_later / prefs）の読み取りのみ。

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../novel_model.dart';
import 'database_service.dart';
import 'pixiv_api_service.dart';
import 'reading_speed_service.dart';

/// シリーズ内の1作品（エピソード）。
class SeriesWorkRef {
  final int id;
  final String title;
  final int? order; // series_order（欠落時は null。順序判定に使用）
  final int textLength;

  const SeriesWorkRef({
    required this.id,
    required this.title,
    this.order,
    this.textLength = 0,
  });
}

/// シリーズ進捗の算出結果。
class SeriesProgress {
  final int totalCount; // エピソード総数
  final int readCount; // 読了判定数（status=2 か しおり進捗>=99.5%）
  final SeriesWorkRef? nextUnreadWork; // 次の未読話（null = 全話読了 / 未読なし）
  final int? remainingEstimateMinutes; // 残り読了目安（算出不可で null）

  const SeriesProgress({
    required this.totalCount,
    required this.readCount,
    this.nextUnreadWork,
    this.remainingEstimateMinutes,
  });

  double get progressRatio => totalCount <= 0 ? 0.0 : readCount / totalCount;

  /// 表示ラベル例: 「シリーズ 3/12 ・ 次は第4話」
  String summaryLabel() {
    final base = 'シリーズ $readCount/$totalCount';
    final next = nextUnreadWork;
    if (next == null) return '$base ・ 全話読了';
    final num = next.order != null ? next.order! : (readCount + 1);
    return '$base ・ 次は第${_trimEpisodeNum(num)}話';
  }

  static String _trimEpisodeNum(int n) => n <= 0 ? '1' : '$n';
}

/// エピソードを series_order 優先で昇順ソート（null は末尾）。
List<SeriesWorkRef> sortSeriesWorks(List<SeriesWorkRef> works) {
  final sorted = List<SeriesWorkRef>.of(works);
  sorted.sort((a, b) {
    final ao = a.order;
    final bo = b.order;
    if (ao != null && bo != null && ao != bo) return ao.compareTo(bo);
    if (ao != null) return -1;
    if (bo != null) return 1;
    return 0; // 順序不明は API 順を維持（insertion sort ではなく stable）
  });
  return sorted;
}

/// 読了判定: read_later の status が 2 か、しおりの進捗（0.0〜1.0）がほぼ完走。
bool isWorkRead({
  required int workId,
  required Map<int, int> readLaterStatusByWork,
  required Map<int, double> progressByWork,
  double readThreshold = 0.995,
}) {
  if ((readLaterStatusByWork[workId] ?? 0) == 2) return true;
  return (progressByWork[workId] ?? 0.0) >= readThreshold;
}

/// シリーズ進捗を算出（純粋関数）。
SeriesProgress computeSeriesProgress({
  required List<SeriesWorkRef> works,
  required Map<int, int> readLaterStatusByWork,
  required Map<int, double> progressByWork,
  int? currentWorkId,
  double? charsPerMinute,
}) {
  final sorted = sortSeriesWorks(works);
  var readCount = 0;
  SeriesWorkRef? next;
  var remainingChars = 0;
  for (final w in sorted) {
    final read = isWorkRead(
      workId: w.id,
      readLaterStatusByWork: readLaterStatusByWork,
      progressByWork: progressByWork,
    );
    if (read) {
      readCount++;
      continue;
    }
    next ??= w;
    remainingChars += w.textLength;
  }
  int? estimate;
  final cpm = charsPerMinute;
  if (next == null) {
    estimate = 0;
  } else if (cpm != null && cpm > 0 && remainingChars > 0) {
    estimate = estimateRemainingMinutes(remainingChars, cpm);
  }
  return SeriesProgress(
    totalCount: sorted.length,
    readCount: readCount,
    nextUnreadWork: next,
    remainingEstimateMinutes: estimate,
  );
}

/// シリーズ進捗サービス（シングルトン）。
class SeriesProgressService {
  static final SeriesProgressService _instance =
      SeriesProgressService._internal();
  factory SeriesProgressService() => _instance;
  SeriesProgressService._internal();

  /// エピソード一覧 + ローカル読了状態を読み込み進捗を算出する。
  /// API 取得に失敗したら null を返す（呼び出し側は非表示にする）。
  Future<SeriesProgress?> fetch(int seriesId, {int? currentWorkId}) async {
    if (seriesId <= 0) return null;
    try {
      final episodes = await PixivApiService().getNovelSeries(seriesId);
      if (episodes.isEmpty) return null;
      final works = <SeriesWorkRef>[
        for (final n in episodes)
          SeriesWorkRef(
            id: n.id,
            title: n.title,
            order: n.seriesOrder,
            textLength: n.textLength,
          ),
      ];
      final (statusByWork, progressByWork) = await localReadingState();
      double? cpm;
      try {
        cpm = (await ReadingSpeedService().getPersonalSpeed()).charsPerMinute;
      } catch (_) {
        cpm = null;
      }
      return computeSeriesProgress(
        works: works,
        readLaterStatusByWork: statusByWork,
        progressByWork: progressByWork,
        currentWorkId: currentWorkId,
        charsPerMinute: cpm,
      );
    } catch (e) {
      debugPrint('シリーズ進捗の取得に失敗（無視）: $e');
      return null;
    }
  }

  /// 1作品（Novel）に対する進捗。series が無い・取得失敗時は null。
  Future<SeriesProgress?> fetchForWork(Novel novel) {
    final seriesId = novel.series?.id ?? 0;
    if (seriesId <= 0) return Future.value(null);
    return fetch(seriesId, currentWorkId: novel.id);
  }

  /// read_later の status と prefs のしおり進捗をまとめて読む。
  /// リーダーなど「エピソード一覧を既に持っている」呼び出し側向け。
  Future<(Map<int, int>, Map<int, double>)> localReadingState() async {
    final statusByWork = <int, int>{};
    try {
      final rows = await DatabaseService().getReadLaterList();
      for (final r in rows) {
        final id = (r['work_id'] as num?)?.toInt() ?? 0;
        final status = (r['status'] as num?)?.toInt() ?? 0;
        if (id > 0) statusByWork[id] = status;
      }
    } catch (_) {
      // read_later 取得失敗は空として継続
    }
    final progressByWork = <int, double>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith('novel_progress_')) continue;
        final id = int.tryParse(key.substring('novel_progress_'.length));
        if (id == null) continue;
        progressByWork[id] = (prefs.getDouble(key) ?? 0.0) / 100.0;
      }
    } catch (_) {
      // prefs 取得失敗は空として継続
    }
    return (statusByWork, progressByWork);
  }
}
