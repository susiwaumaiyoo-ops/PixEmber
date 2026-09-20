// Phase 10-A / A-0(b): クロス言語 fixture 生成（Dart 実測を正）。
//
// 端末の normalizeNovelBody / computeSourceFingerprint / buildPrompt /
// LlmChunker の実出力を JSON にダンプし、サーバー側 Python 移植
// （server/lib/normalize.py ほか）が同一出力を再現できるかを
// server/tools/test_fixtures.py で検証する。
//
// 実行（pixiv_viewer/ で）:
//   dart test test/phase10_gen_fixtures_test.dart
//   ※ 環境変数 PIXEMBER_FIXTURE_OUT で出力先を変更可。
//     既定: ../server/fixtures/phase10_dart.json（この repo 構成向け）
//
// 注意: この生成だけなら実機不要。正規化の「正」は Dart 実装そのもの。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/llm_summary_service.dart';
import 'package:pixiv_viewer/services/llm_summary_cache_service.dart';
import 'package:pixiv_viewer/services/llm_chunking.dart';

class _Case {
  const _Case(this.name, this.title, this.tags, this.rawBody);
  final String name;
  final String title;
  final List<String> tags;
  final String rawBody;
}

String _rep(String s, int n) => List.filled(n, s).join();

final _cases = <_Case>[
  const _Case('normal', 'テストタイトル', ['a', 'b', 'c'], 'これは本文です。\n改行も含みます。\n終わり。'),
  const _Case('ruby', 'ルビあり', [
    'ルビ',
  ], '漢字[[rb:かんじ]]とひらがな。[[rb:日本語 > にほんご]]のテスト。'),
  const _Case('uploadedimage', '画像タグ', [
    'img',
  ], '前\n[uploadedimage:12345]\n中\n[uploadedimage:999]\n後'),
  const _Case('pixivimage', 'pixiv画像', [
    'p',
  ], 'A\n[pixivimage:111]\nB\n[pixivimage:222-3]\nC'),
  const _Case('newpage', '改頁', [
    'np',
  ], '1ページ目\n[newpage]\n2ページ目\n[newpage]\n3ページ目'),
  const _Case('crlf', 'CRLF', ['x'], '行1\r\n行2\r\n\r\n行3'),
  const _Case('consecutive_blank', '連続空行', ['y'], 'A\n\n\n\n\nB'),
  const _Case('empty_tags', '空タグ', ['', '  ', '実'], 'トリム前空白込み'),
  const _Case('jp_symbols', '日本語記号', [
    '！',
    '？',
    '「」',
  ], '！全角、．中点「引用」——ダッシュ…省略記号'),
  _Case('long_para', '長文', ['long'], '${_rep('あ', 300)}\n\n${_rep('い', 300)}'),
  // 境界近傍（chunk 境界を跨ぐ長さ）
  _Case('near_chunk_boundary', '境界', [
    'edge',
  ], '${_rep('文', 2050)}\n\n${_rep('字', 2050)}\n\n${_rep('句', 2050)}'),
];

String _outPath() {
  final env = Platform.environment['PIXEMBER_FIXTURE_OUT'];
  if (env != null && env.isNotEmpty) return env;
  return '../server/fixtures/phase10_dart.json';
}

void main() {
  test('generate cross-language fixtures', () {
    const maxChars = 6000; // 端末 maxBodyChars 相当
    const overlapChars = 280; // 200 tokens * ~1.4（近似境界）
    final casesJson = <Map<String, dynamic>>[];

    for (final c in _cases) {
      final normalized = LlmSummaryService.normalizeNovelBody(c.rawBody);
      final fp = LlmSummaryService.computeSourceFingerprint(
        title: c.title,
        tags: c.tags,
        body: c.rawBody,
      );
      final messages = LlmSummaryService.buildPromptFromText(
        title: c.title,
        tags: c.tags,
        text: normalized.isEmpty ? '(empty)' : normalized,
      );
      List<Map<String, dynamic>> chunks = const [];
      if (normalized.isNotEmpty) {
        final split = LlmChunker.split(
          normalized,
          maxChars: maxChars,
          overlapChars: overlapChars,
        );
        chunks = split
            .map(
              (ch) => {
                'index': ch.index,
                'start_char': ch.startChar,
                'end_char': ch.endChar,
                'char_len': ch.text.length,
                'head': ch.text.length > 8 ? ch.text.substring(0, 8) : ch.text,
                'tail': ch.text.length > 8
                    ? ch.text.substring(ch.text.length - 8)
                    : ch.text,
              },
            )
            .toList();
      }

      casesJson.add({
        'name': c.name,
        'title': c.title,
        'tags': c.tags,
        'raw_body': c.rawBody,
        'expected_normalized_body': normalized,
        'expected_source_fingerprint': fp,
        'prompt_version': LlmSummaryCacheService.promptVersion,
        'system_prompt': messages.first.content,
        'user_prompt': messages.last.content,
        'chunks': chunks,
      });
    }

    final payload = {
      'generator': 'pixiv_viewer dart (source of truth)',
      'prompt_version': LlmSummaryCacheService.promptVersion,
      'fingerprint_scheme': 'v3',
      'cases': casesJson,
    };

    final path = _outPath();
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
    // ignore: avoid_print
    print(
      '[gen_fixtures] wrote ${casesJson.length} cases -> ${file.absolute.path}',
    );
  });
}
