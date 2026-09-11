// B-2: 段落境界優先チャンク分割（LlmChunker）の純粋ロジックテスト。
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/llm_chunking.dart';

void main() {
  group('トークン<->文字 換算', () {
    test('approxTokens は 1.4字/tok で切り上げ', () {
      expect(LlmChunker.approxTokens(0), 0);
      expect(LlmChunker.approxTokens(14), 10);
      expect(LlmChunker.approxTokens(1), 1);
    });

    test('approxChars は 1.4倍 切り捨て / 往復で一致', () {
      expect(LlmChunker.approxChars(100), 140);
      expect(LlmChunker.approxTokens(LlmChunker.approxChars(100)), 100);
    });
  });

  group('split', () {
    test('空・空白のみは空リスト', () {
      expect(LlmChunker.split('', maxChars: 100, overlapChars: 10), isEmpty);
      expect(
        LlmChunker.split('   \n  ', maxChars: 100, overlapChars: 10),
        isEmpty,
      );
    });

    test('上限以内は 1 チャンク', () {
      final r = LlmChunker.split('短い本文。', maxChars: 100, overlapChars: 10);
      expect(r, hasLength(1));
      expect(r.first.index, 0);
      expect(r.first.text, '短い本文。');
    });

    test('段落境界で複数分割し index が 0 始まり連番', () {
      final para = List.generate(80, (i) => '文$iです。').join('\n');
      final r = LlmChunker.split(para, maxChars: 240, overlapChars: 10);
      expect(r.length, greaterThan(1));
      for (var i = 0; i < r.length; i++) {
        expect(r[i].index, i);
        expect(r[i].startChar, lessThanOrEqualTo(r[i].endChar));
        // 重複ぶんを含めても上限を大きく超えない
        expect(r[i].length, lessThanOrEqualTo(240 + 10 + 20));
      }
    });

    test('長い単一行は文末(。)で切れる', () {
      final long = '${'あ' * 150}。${'い' * 150}。';
      final r = LlmChunker.split(long, maxChars: 200, overlapChars: 0);
      expect(r.length, greaterThanOrEqualTo(2));
      expect(r.first.text.endsWith('。'), isTrue, reason: '文末で切る');
    });

    test('overlap>0 なら次チャンクが前末尾を含む', () {
      final para = List.generate(80, (i) => 'かきくけこの文$i。').join('\n');
      final noOv = LlmChunker.split(para, maxChars: 240, overlapChars: 0);
      final withOv = LlmChunker.split(para, maxChars: 240, overlapChars: 12);
      expect(withOv.length, greaterThanOrEqualTo(2));
      // 重複ありは先頭チャンク開始が 0 のまま、2チャンク目の開始が前に戻る
      expect(noOv[1].startChar, greaterThan(0));
      expect(
        withOv[1].startChar,
        lessThanOrEqualTo(noOv[1].startChar),
        reason: '重複ぶんだけ遡る',
      );
    });
  });
}
