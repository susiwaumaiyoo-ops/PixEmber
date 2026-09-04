// 小説シリーズ追跡サービス（非AI機能パック Phase N3）のユニットテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/series_progress_service.dart';

SeriesWorkRef _w(int id, [int? order, int chars = 1000, String? title]) =>
    SeriesWorkRef(
      id: id,
      title: title ?? 'E$id',
      order: order,
      textLength: chars,
    );

void main() {
  group('sortSeriesWorks', () {
    test('series_order 昇順でソート（乱順入力）', () {
      final sorted = sortSeriesWorks([_w(3, 3), _w(1, 1), _w(2, 2)]);
      expect(sorted.map((e) => e.id).toList(), [1, 2, 3]);
    });

    test('order 欠落（null）のエピソードは末尾に退避', () {
      final sorted = sortSeriesWorks([_w(9, null), _w(1, 1), _w(2, 2)]);
      expect(sorted.map((e) => e.id).toList(), [1, 2, 9]);
    });

    test('全件 order 欠落でも件数は維持', () {
      final sorted = sortSeriesWorks([_w(1), _w(2)]);
      expect(sorted.length, 2);
    });
  });

  group('isWorkRead', () {
    test('read_later status=2 は読了', () {
      expect(
        isWorkRead(
          workId: 1,
          readLaterStatusByWork: {1: 2},
          progressByWork: {},
        ),
        isTrue,
      );
    });

    test('しおり進捗 0.995 以上は読了', () {
      expect(
        isWorkRead(
          workId: 2,
          readLaterStatusByWork: {},
          progressByWork: {2: 0.999},
        ),
        isTrue,
      );
    });

    test('途中進捗（0.4）は未読', () {
      expect(
        isWorkRead(
          workId: 3,
          readLaterStatusByWork: {},
          progressByWork: {3: 0.4},
        ),
        isFalse,
      );
    });

    test('データなしは未読', () {
      expect(
        isWorkRead(workId: 4, readLaterStatusByWork: {}, progressByWork: {}),
        isFalse,
      );
    });
  });

  group('computeSeriesProgress', () {
    test('次の未読話・進捗率・残り目安', () {
      final p = computeSeriesProgress(
        works: [_w(1, 1), _w(2, 2), _w(3, 3)],
        readLaterStatusByWork: {1: 2, 2: 2},
        progressByWork: {},
        charsPerMinute: 500,
      );
      expect(p.totalCount, 3);
      expect(p.readCount, 2);
      expect(p.progressRatio, closeTo(2 / 3, 1e-9));
      expect(p.nextUnreadWork?.id, 3);
      expect(p.summaryLabel(), 'シリーズ 2/3 ・ 次は第3話');
      // 残り 1000 文字 ÷ 500 字/分 = 2分
      expect(p.remainingEstimateMinutes, 2);
    });

    test('しおり進捗による読了判定（status なし）', () {
      final p = computeSeriesProgress(
        works: [_w(1, 1), _w(2, 2)],
        readLaterStatusByWork: {},
        progressByWork: {1: 1.0},
      );
      expect(p.readCount, 1);
      expect(p.nextUnreadWork?.id, 2);
    });

    test('未読0（全話読了）: 次は null + 残り0分', () {
      final p = computeSeriesProgress(
        works: [_w(1, 1), _w(2, 2)],
        readLaterStatusByWork: {1: 2, 2: 2},
        progressByWork: {},
        charsPerMinute: 500,
      );
      expect(p.readCount, 2);
      expect(p.nextUnreadWork, isNull);
      expect(p.remainingEstimateMinutes, 0);
      expect(p.summaryLabel(), 'シリーズ 2/2 ・ 全話読了');
    });

    test('順序欠落（null order）でも末尾のエピソードを次候補にできる', () {
      final p = computeSeriesProgress(
        works: [_w(1, 1), _w(9, null)],
        readLaterStatusByWork: {1: 2},
        progressByWork: {},
      );
      expect(p.nextUnreadWork?.id, 9);
    });

    test('文字数不明・速度なしでは残り目安は null', () {
      final p = computeSeriesProgress(
        works: [SeriesWorkRef(id: 1, title: 'E1', order: 1)],
        readLaterStatusByWork: {},
        progressByWork: {},
      );
      expect(p.nextUnreadWork?.id, 1);
      expect(p.remainingEstimateMinutes, isNull);
    });

    test('空のエピソード一覧は 0/0（UI 側で非表示にすることを想定）', () {
      final p = computeSeriesProgress(
        works: const [],
        readLaterStatusByWork: {},
        progressByWork: {},
      );
      expect(p.totalCount, 0);
      expect(p.readCount, 0);
      expect(p.progressRatio, 0.0);
    });
  });
}
