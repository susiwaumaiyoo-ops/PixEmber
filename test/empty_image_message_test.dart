// ダウンロード済み画像が少ない場合の案内メッセージ決定ロジックの単体テスト。
//
// buildEmptyImageMessage は純粋関数で、視覚類似検索・重複検出の両画面で
// 共有される。画像数 0/1/2 以上で期待文言が返るか、2 件以上は null（通常処理）
// になるかを検証する。

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/utils/empty_image_message.dart';

void main() {
  group('buildEmptyImageMessage', () {
    test('0件: 画像がありません', () {
      expect(buildEmptyImageMessage(0, '視覚類似検索'), 'ダウンロード済み画像がありません');
      expect(buildEmptyImageMessage(0, '重複検出'), 'ダウンロード済み画像がありません');
    });

    test('1件: 1件のみ・機能名を含む案内', () {
      expect(
        buildEmptyImageMessage(1, '視覚類似検索'),
        '画像は1件あります。視覚類似検索には2件以上必要です。',
      );
      expect(buildEmptyImageMessage(1, '重複検出'), '画像は1件あります。重複検出には2件以上必要です。');
    });

    test('2件以上: null（通常処理へ）', () {
      expect(buildEmptyImageMessage(2, '視覚類似検索'), isNull);
      expect(buildEmptyImageMessage(5, '重複検出'), isNull);
    });

    test('負の値は0件と同じ扱い', () {
      expect(buildEmptyImageMessage(-1, '視覚類似検索'), 'ダウンロード済み画像がありません');
    });
  });
}
