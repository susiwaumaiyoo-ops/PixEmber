// 感動機能パック Phase E のユニットテスト（純粋関数中心）。
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/services/emotion_curve_service.dart';
import 'package:pixiv_viewer/services/dormant_tags_service.dart';
import 'package:pixiv_viewer/services/ugoira_frame_service.dart';

void main() {
  group('pickEmotionHighlights (E1)', () {
    test('null なら空', () {
      expect(pickEmotionHighlights(null), isEmpty);
    });

    test('z>=minZ のチャンク上位をページ位置付きで返す', () {
      final chunks = [
        EmotionChunk(index: 0, text: 'a', pageStart: 0, pageEnd: 0),
        EmotionChunk(index: 1, text: 'b', pageStart: 3, pageEnd: 3),
        EmotionChunk(index: 2, text: 'c', pageStart: 7, pageEnd: 7),
      ];
      // 軸0(喜): [0.2, 1.5, 0.0]、軸1(悲): [0.1, 0.0, 1.2]
      final zScores = [
        [0.2, 1.5, 0.0],
        [0.1, 0.0, 1.2],
      ];
      final curve = EmotionCurveResult(
        chunks: chunks,
        zScores: zScores,
        storyColor: '',
        isSimpleMode: false,
        modelId: 'test',
      );
      final hi = pickEmotionHighlights(curve, maxItems: 5, minZ: 1.0);
      expect(hi.length, 2);
      // 1.5(喜,p.4) > 1.2(悲,p.8)
      expect(hi[0].label, '喜');
      expect(hi[0].pageIndex, 3);
      expect(hi[1].label, '悲');
      expect(hi[1].pageIndex, 7);
    });

    test('minZ 未満は除外', () {
      final chunks = [
        EmotionChunk(index: 0, text: 'a', pageStart: 0, pageEnd: 0),
      ];
      final zScores = [
        [0.5],
      ];
      final curve = EmotionCurveResult(
        chunks: chunks,
        zScores: zScores,
        storyColor: '',
        isSimpleMode: false,
        modelId: 'test',
      );
      expect(pickEmotionHighlights(curve, minZ: 1.0), isEmpty);
    });
  });

  group('pickDormantTags (E2)', () {
    test('過去多・最近少を上位に抽出', () {
      final now = DateTime(2026, 8, 1);
      final stats = {
        'A': TagReadStat(
          pastCount: 10,
          recentCount: 0,
          lastSeen: now.subtract(const Duration(days: 60)),
        ),
        'B': TagReadStat(
          pastCount: 5,
          recentCount: 0,
          lastSeen: now.subtract(const Duration(days: 10)),
        ),
        'C': TagReadStat(
          pastCount: 2,
          recentCount: 0,
          lastSeen: now.subtract(const Duration(days: 5)),
        ),
        'D': TagReadStat(
          pastCount: 8,
          recentCount: 3,
          lastSeen: now.subtract(const Duration(days: 1)),
        ),
      };
      final res = pickDormantTags(stats, minPast: 3, maxRecent: 1, now: now);
      expect(res.map((e) => e.tag).toList(), ['A', 'B']);
      expect(res.first.score > res.last.score, isTrue);
    });

    test('maxItems で上限', () {
      final now = DateTime(2026, 8, 1);
      final stats = <String, TagReadStat>{};
      for (var i = 0; i < 20; i++) {
        stats['T$i'] = TagReadStat(
          pastCount: 10 + i,
          recentCount: 0,
          lastSeen: now.subtract(const Duration(days: 100)),
        );
      }
      final res = pickDormantTags(stats, maxItems: 5, now: now);
      expect(res.length, 5);
    });
  });

  group('pickRepresentativeFrameFile (E3)', () {
    test('frames の最初のファイルを選ぶ', () {
      final frames = [
        {'file': '000000.jpg', 'delay': 100},
        {'file': '000001.jpg', 'delay': 100},
      ];
      final names = ['000000.jpg', '000001.jpg'];
      expect(pickRepresentativeFrameFile(frames, names), '000000.jpg');
    });

    test('空なら null', () {
      expect(pickRepresentativeFrameFile([], []), isNull);
      expect(pickRepresentativeFrameFile([], ['a.jpg']), isNull);
    });

    test('frames に file 名がない場合は fileNames 先頭', () {
      final frames = [
        {'name': 'x.png', 'delay': 100},
      ];
      final names = ['y.png', 'z.png'];
      expect(pickRepresentativeFrameFile(frames, names), 'y.png');
    });
  });
}
