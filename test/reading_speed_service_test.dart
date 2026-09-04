// 読書速度サービス（Phase A）の純粋関数テスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/reading_speed_service.dart';

Map<String, dynamic> novelSession({
  required int workId,
  required int seconds,
  String startedAt = '2026-09-01T12:00:00',
  String workType = 'novel',
}) {
  return <String, dynamic>{
    'work_type': workType,
    'work_id': workId,
    'duration_seconds': seconds,
    'started_at': startedAt,
  };
}

void main() {
  group('medianOf', () {
    test('空リストは null', () {
      expect(medianOf(const <double>[]), isNull);
    });

    test('奇数個は中央の値', () {
      expect(medianOf(const [3, 1, 2]), 2.0);
    });

    test('偶数個は中央2つの平均', () {
      expect(medianOf(const [1, 2, 3, 4]), 2.5);
    });
  });

  group('removeSpeedOutliers', () {
    test('中央値から大きく外れた値を除去', () {
      // 中央値490、許容帯 [122.5, 1960] → 60（つけっぱなし）を除外
      expect(removeSpeedOutliers(const [500, 520, 480, 60]), [500, 520, 480]);
    });

    test('正常値のみの場合はそのまま', () {
      expect(removeSpeedOutliers(const [400, 500, 600]), [400, 500, 600]);
    });

    test('中央値が0以下は空になる', () {
      expect(removeSpeedOutliers(const [0, 0]), isEmpty);
      expect(removeSpeedOutliers(const [-5]), isEmpty);
    });
  });

  group('computeCharsPerMinute（速度算出）', () {
    test('正常: 複数作品の平均', () {
      final cpm = computeCharsPerMinute(const [
        WorkReadingStat(
          workId: 1,
          textLength: 1000,
          totalSeconds: 120,
        ), // 500字/分
        WorkReadingStat(
          workId: 2,
          textLength: 2000,
          totalSeconds: 120,
        ), // 1000字/分
      ]);
      expect(cpm, 750.0);
    });

    test('外れ値: 長時間つけっぱなしの作品を除外', () {
      final cpm = computeCharsPerMinute(const [
        WorkReadingStat(workId: 1, textLength: 1000, totalSeconds: 120), // 500
        WorkReadingStat(workId: 2, textLength: 1040, totalSeconds: 120), // 520
        WorkReadingStat(workId: 3, textLength: 960, totalSeconds: 120), // 480
        WorkReadingStat(workId: 4, textLength: 3600, totalSeconds: 3600), // 60
      ]);
      expect(cpm, 500.0);
    });

    test('データ0件は null', () {
      expect(computeCharsPerMinute(const []), isNull);
    });

    test('データ1件でも算出可能', () {
      final cpm = computeCharsPerMinute(const [
        WorkReadingStat(workId: 1, textLength: 600, totalSeconds: 60),
      ]);
      expect(cpm, 600.0);
    });

    test('30秒未満はノイズとして除外', () {
      expect(
        computeCharsPerMinute(const [
          WorkReadingStat(workId: 1, textLength: 600, totalSeconds: 29),
        ]),
        isNull,
      );
    });

    test('文字数0は除外', () {
      expect(
        computeCharsPerMinute(const [
          WorkReadingStat(workId: 1, textLength: 0, totalSeconds: 120),
        ]),
        isNull,
      );
    });

    test('上限 5000字/分 にクランプ', () {
      final cpm = computeCharsPerMinute(const [
        WorkReadingStat(workId: 1, textLength: 100000, totalSeconds: 30),
      ]);
      expect(cpm, 5000.0);
    });
  });

  group('aggregateWorkStats', () {
    test('novelのみ・正の秒数・文字数既知の作品だけ集計し、同一作品は合算', () {
      final stats = aggregateWorkStats(
        [
          novelSession(workId: 1, seconds: 60),
          novelSession(workId: 2, seconds: 0), // 0秒は除外
          novelSession(workId: 3, seconds: 60, workType: 'illust'), // novel以外
          novelSession(workId: 0, seconds: 60), // 不正id
          novelSession(workId: 9, seconds: 60), // 文字数不明
          novelSession(workId: 1, seconds: 30), // 同一作品は合算
        ],
        const {1: 900, 2: 500, 3: 500},
      );
      expect(stats.length, 1);
      expect(stats.first.workId, 1);
      expect(stats.first.totalSeconds, 90);
      expect(stats.first.textLength, 900);
    });

    test('workLimit は新しい順に打ち切り', () {
      final stats = aggregateWorkStats(
        [
          novelSession(workId: 1, seconds: 60),
          novelSession(workId: 2, seconds: 60),
          novelSession(workId: 3, seconds: 60),
        ],
        const {1: 100, 2: 100, 3: 100},
        workLimit: 2,
      );
      expect(stats.map((s) => s.workId), [1, 2]);
    });
  });

  group('estimateRemainingMinutes（残り時間計算）', () {
    test('残り0字以下は0分', () {
      expect(estimateRemainingMinutes(0, 500), 0);
      expect(estimateRemainingMinutes(-10, 500), 0);
    });

    test('単純な割り算', () {
      expect(estimateRemainingMinutes(1000, 500), 2);
    });

    test('端数は切り上げ', () {
      expect(estimateRemainingMinutes(1001, 500), 3);
    });

    test('速度<=0なら既定値 550字/分 で計算', () {
      expect(estimateRemainingMinutes(1100, 0), 2);
      expect(estimateRemainingMinutes(1100, -1), 2);
    });

    test('最低1分', () {
      expect(estimateRemainingMinutes(1, 5000), 1);
    });
  });

  group('formatReadingTime（表示フォーマット 分→時間分変換）', () {
    test('0以下は 1分以内', () {
      expect(formatReadingTime(0), '1分以内');
      expect(formatReadingTime(-3), '1分以内');
    });

    test('60分未満は 約X分', () {
      expect(formatReadingTime(1), '約1分');
      expect(formatReadingTime(45), '約45分');
      expect(formatReadingTime(59), '約59分');
    });

    test('ちょうど1時間単位', () {
      expect(formatReadingTime(60), '約1時間');
      expect(formatReadingTime(120), '約2時間');
    });

    test('時間+分', () {
      expect(formatReadingTime(61), '約1時間1分');
      expect(formatReadingTime(90), '約1時間30分');
      expect(formatReadingTime(125), '約2時間5分');
    });
  });

  group('computeWeeklySpeedPoints', () {
    test('空データは空', () {
      expect(computeWeeklySpeedPoints(const [], const {}), isEmpty);
    });

    test('週次（月曜始まり）の速度を算出', () {
      final points = computeWeeklySpeedPoints(
        [
          novelSession(
            workId: 1,
            seconds: 120,
            startedAt: '2026-09-01T12:00:00',
          ), // 火曜
        ],
        const {1: 1200},
      );
      expect(points.length, 1);
      expect(points.first.charsPerMinute, 600.0);
      expect(points.first.weekStart, DateTime(2026, 8, 31));
      expect(points.first.weekStart.weekday, DateTime.monday);
    });

    test('日曜と月曜は別週（日付境界）', () {
      final points = computeWeeklySpeedPoints(
        [
          novelSession(
            workId: 1,
            seconds: 60,
            startedAt: '2026-09-06T23:00:00',
          ),
          novelSession(
            workId: 2,
            seconds: 60,
            startedAt: '2026-09-07T00:30:00',
          ),
        ],
        const {1: 600, 2: 600},
      );
      expect(points.length, 2);
      expect(points[0].weekStart, DateTime(2026, 8, 31));
      expect(points[1].weekStart, DateTime(2026, 9, 7));
    });

    test('30秒未満の週はスキップ', () {
      final points = computeWeeklySpeedPoints(
        [novelSession(workId: 1, seconds: 29)],
        const {1: 1200},
      );
      expect(points, isEmpty);
    });

    test('文字数不明の作品だけなら点にならない', () {
      final points = computeWeeklySpeedPoints([
        novelSession(workId: 7, seconds: 120),
      ], const {});
      expect(points, isEmpty);
    });

    test('novel以外・不正な日付は無視', () {
      final points = computeWeeklySpeedPoints(
        [
          novelSession(workId: 1, seconds: 60, workType: 'illust'),
          <String, dynamic>{
            'work_type': 'novel',
            'work_id': 2,
            'duration_seconds': 60,
            'started_at': 'not-a-date',
          },
        ],
        const {1: 600, 2: 600},
      );
      expect(points, isEmpty);
    });

    test('週順にソートされて返る', () {
      final points = computeWeeklySpeedPoints(
        [
          novelSession(
            workId: 2,
            seconds: 60,
            startedAt: '2026-09-08T12:00:00',
          ),
          novelSession(
            workId: 1,
            seconds: 60,
            startedAt: '2026-09-01T12:00:00',
          ),
        ],
        const {1: 600, 2: 600},
      );
      expect(points.length, 2);
      expect(points[0].weekStart.isBefore(points[1].weekStart), isTrue);
    });
  });
}
