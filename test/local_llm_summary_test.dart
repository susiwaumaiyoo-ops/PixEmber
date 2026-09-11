// ローカルLLM小説要約（PoC）のテスト。
//
// 対象:
// - LocalLlmService の状態遷移（idle/loading/generating/done/error）
// - 2000文字截断
// - プロンプト構築（日本語・セクション形式）
// - 出力解析・拒否検知・拒否時の自然なエラーメッセージ
// - GGUF 発見
// - 非 Android 分岐
// - UI: モデル未配置時はボタン非表示
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/novel_model.dart';
import 'package:pixiv_viewer/screens/novel_detail_screen.dart';
import 'package:pixiv_viewer/services/llm_summary_service.dart';
import 'package:pixiv_viewer/services/local_llm_service.dart';
import 'package:pixiv_viewer/widgets/llm_summary_sheet.dart';

/// スクリプト済みのストリームを返す fake エンジン（ネイティブ非依存）。
class _FakeEngine implements LlmInferenceEngine {
  _FakeEngine(
    this.chunks, {
    this.error,
    this.chunkDelay = const Duration(milliseconds: 1),
  });

  final List<String> chunks;
  final Object? error;
  final Duration chunkDelay;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Stream<String> generate({
    required List<LlmChatMessage> messages,
    required LlmGenerationOptions options,
  }) {
    // async* ジェネレータは購読開始まで本体を実行しない。ここでストリーム
    // オブジェクトを同期的に返すことで、キャンセル直後に次の generate を
    // 呼んでも busy 判定に干渉しない(状態リセット回帰テストの前提)。
    Stream<String> body() async* {
      for (final c in chunks) {
        await Future<void>.delayed(chunkDelay);
        yield c;
      }
      if (error != null) throw error!;
    }

    return body();
  }

  @override
  void dispose() {}
}

/// 呼び出しごとに異なるストリームを返す fake エンジン（再生成テスト用・M1）。
class _MultiEngine implements LlmInferenceEngine {
  _MultiEngine(this.responses);

  final List<List<String>> responses;
  int callCount = 0;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Stream<String> generate({
    required List<LlmChatMessage> messages,
    required LlmGenerationOptions options,
  }) async* {
    final i = callCount < responses.length ? callCount : responses.length - 1;
    callCount++;
    for (final c in responses[i]) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      yield c;
    }
  }

  @override
  void dispose() {}
}

/// generate / loadModel の呼び出し回数を数えるエンジン(状態リセット回帰用)。
class _ResetTrackingEngine implements LlmInferenceEngine {
  _ResetTrackingEngine({this.chunks = const ['ok']});

  final List<String> chunks;
  int loadCalls = 0;
  int generateCalls = 0;

  @override
  Future<void> loadModel(String modelPath) async {
    loadCalls++;
  }

  @override
  Stream<String> generate({
    required List<LlmChatMessage> messages,
    required LlmGenerationOptions options,
  }) {
    generateCalls++;
    Stream<String> body() async* {
      for (final c in chunks) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        yield c;
      }
    }

    return body();
  }

  @override
  void dispose() {}
}

/// 初回 generate のみ decode エラーを模すエンジン。
class _FailOnceEngine implements LlmInferenceEngine {
  int calls = 0;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Stream<String> generate({
    required List<LlmChatMessage> messages,
    required LlmGenerationOptions options,
  }) {
    calls++;
    final fail = calls == 1;
    Stream<String> body() async* {
      if (fail) {
        throw StateError('decode(prompt) rc=1 at 1536/2017');
      }
      yield 'recovered';
    }

    return body();
  }

  @override
  void dispose() {}
}

final _userMsg = [
  LlmChatMessage.fromText(role: LlmChatRole.user, text: 'hello'),
];

void main() {
  group('LocalLlmService 状態遷移', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('llm_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String writeModel() {
      final f = File('${tmp.path}/model.gguf')..writeAsStringSync('gguf');
      return f.path;
    }

    test('初期状態は idle', () {
      final service = LocalLlmService(engineFactory: (p) => _FakeEngine([]));
      expect(service.state, LlmState.idle);
      expect(service.isDisposed, isFalse);
    });

    test('loadModel: モデルファイル不在 -> error', () async {
      final service = LocalLlmService(engineFactory: (p) => _FakeEngine([]));
      final ok = await service.loadModel('${tmp.path}/missing.gguf');
      expect(ok, isFalse);
      expect(service.state, LlmState.error);
      expect(service.errorMessage, contains('見つかりません'));
    });

    test('loadModel: ファイルあり -> idle', () async {
      final service = LocalLlmService(engineFactory: (p) => _FakeEngine([]));
      final ok = await service.loadModel(writeModel());
      expect(ok, isTrue);
      expect(service.state, LlmState.idle);
      expect(service.modelPath, isNotNull);
    });

    test('generate: 正常 -> generating -> done、完全テキストを返す', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine(['ああ', 'いい']),
      );
      await service.loadModel(writeModel());
      final states = <LlmState>[];
      service.onStateChange = (s, e) => states.add(s);
      final text = await service.generate(_userMsg);
      expect(text, 'ああいい');
      expect(service.state, LlmState.done);
      expect(states, containsAllInOrder([LlmState.generating, LlmState.done]));
    });

    test('generate: ストリームエラー -> error、例外を送出', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine(['x'], error: StateError('boom')),
      );
      await service.loadModel(writeModel());
      await expectLater(service.generate(_userMsg), throwsStateError);
      expect(service.state, LlmState.error);
      expect(service.errorMessage, isNotNull);
    });

    test('cancel: LlmCancelledException + idle', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine([
          'a',
          'b',
          'c',
        ], chunkDelay: const Duration(milliseconds: 10)),
      );
      await service.loadModel(writeModel());
      var tokens = 0;
      await expectLater(
        service.generate(
          _userMsg,
          onToken: (_) {
            tokens++;
            if (tokens == 1) service.cancel();
          },
        ),
        throwsA(isA<LlmCancelledException>()),
      );
      expect(service.state, LlmState.idle);
      expect(service.isBusy, isFalse);
    });

    test('同一セッションで generate を3回連続してもロードは1回だけ', () async {
      final engine = _ResetTrackingEngine(chunks: const ['あ']);
      final service = LocalLlmService(engineFactory: (p) => engine);
      await service.loadModel(writeModel());
      final a = await service.generate(_userMsg);
      final b = await service.generate(_userMsg);
      final c = await service.generate(_userMsg);
      expect([a, b, c], ['あ', 'あ', 'あ']);
      expect(engine.loadCalls, 1);
      expect(engine.generateCalls, 3);
      expect(service.state, LlmState.done);
      expect(service.isBusy, isFalse);
    });

    test('キャンセル後の次回 generate も成功する', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine([
          'a',
          'b',
          'c',
        ], chunkDelay: const Duration(milliseconds: 10)),
      );
      await service.loadModel(writeModel());
      var tokens = 0;
      await expectLater(
        service.generate(
          _userMsg,
          onToken: (_) {
            tokens++;
            if (tokens == 1) service.cancel();
          },
        ),
        throwsA(isA<LlmCancelledException>()),
      );
      // 次回 generate が前回の状態を持ち越さず成功すること(リセットの回帰)。
      final text = await service.generate(_userMsg);
      expect(text, 'abc');
      expect(service.state, LlmState.done);
    });

    test('decode エラー後の次回 generate は状態が初期化され成功する', () async {
      final engine = _FailOnceEngine();
      final service = LocalLlmService(engineFactory: (p) => engine);
      await service.loadModel(writeModel());
      await expectLater(service.generate(_userMsg), throwsStateError);
      expect(service.state, LlmState.error);
      final text = await service.generate(_userMsg);
      expect(text, 'recovered');
      expect(service.state, LlmState.done);
      expect(engine.calls, 2);
    });

    test('dispose 後の generate は安全に StateError(エンジン未呼び出し)', () async {
      final engine = _ResetTrackingEngine();
      final service = LocalLlmService(engineFactory: (p) => engine);
      await service.loadModel(writeModel());
      await service.dispose();
      await expectLater(service.generate(_userMsg), throwsStateError);
      expect(engine.generateCalls, 0);
    });

    test('dispose 以降は状態遷移通知されない', () async {
      final service = LocalLlmService(engineFactory: (p) => _FakeEngine([]));
      var notified = false;
      service.onStateChange = (s, e) => notified = true;
      await service.dispose();
      expect(service.isDisposed, isTrue);
      final ok = await service.loadModel(writeModel());
      expect(ok, isFalse);
      expect(notified, isFalse, reason: 'dispose 後の setState 通知禁止');
    });

    test('dispose 後の generate は StateError', () async {
      final service = LocalLlmService(engineFactory: (p) => _FakeEngine([]));
      await service.dispose();
      await expectLater(service.generate(_userMsg), throwsStateError);
    });

    test('未ロードの generate は StateError', () async {
      final service = LocalLlmService(engineFactory: (p) => _FakeEngine([]));
      await expectLater(service.generate(_userMsg), throwsStateError);
    });
  });

  group('均衡本文抽出（M1）', () {
    test('予算以内: 変更なし', () {
      expect(LlmSummaryService.extractBalancedBody('本文'), '本文');
      final s = 'a' * LlmSummaryService.maxBodyChars;
      expect(LlmSummaryService.extractBalancedBody(s), s);
    });

    test('長い本文: 冒頭/中盤/終盤を予算内で抽出', () {
      final body = 'A' * 1000 + 'M' * 5000 + 'Z' * 1000; // 7000文字
      final out = LlmSummaryService.extractBalancedBody(body);
      expect(out, startsWith('A' * 100), reason: '冒頭');
      expect(out.contains('M' * 100), isTrue, reason: '中盤');
      expect(out, endsWith('Z' * 100), reason: '終盤');
      expect(
        out.length,
        lessThanOrEqualTo(LlmSummaryService.maxBodyChars + 30),
      );
      expect(out.contains('…（中略）…'), isTrue, reason: '中略マーカーで区切られる');
    });

    test('clampBody は引き続き動作（後方互換）', () {
      expect(LlmSummaryService.clampBody('  本文  '), '本文');
      expect(
        LlmSummaryService.clampBody('a' * 6500).length,
        LlmSummaryService.maxBodyChars,
      );
      expect(LlmSummaryService.clampBody('a' * 3500).length, 3500,
          reason: '上限(6000)未満は非截断');
      expect(LlmSummaryService.clampBody(''), '');
    });
  });

  group('プロンプト構築（M1: 作者説明なし）', () {
    test('タイトル・タグ・本文を含み、作者説明は含めない', () {
      const authorDesc = '作者が書いた独自のあらすじ。プロンプトには出てこない。';
      final messages = LlmSummaryService.buildPrompt(
        title: 'テスト小説',
        tags: ['魔法', '青春'],
        body: '本文の冒頭。',
      );
      expect(messages, hasLength(2));
      final user = messages[1].content;
      expect(user, contains('テスト小説'));
      expect(user, contains('魔法'));
      expect(user, contains('青春'));
      expect(user, contains('本文の冒頭。'));
      expect(user, isNot(contains(authorDesc)), reason: 'M1: 作者説明を含まない');
      expect(user, isNot(contains('あらすじ（作者書き）')));
    });

    test('system が先頭メッセージ・作者説明に言及しない', () {
      final messages = LlmSummaryService.buildPrompt(title: 'T', body: 'B');
      expect(messages.first.role, LlmChatRole.system);
      expect(messages.last.role, LlmChatRole.user);
      // 日本語の形式指示が含まれる
      expect(messages.first.content, contains('あらすじ'));
      expect(messages.first.content, contains('紹介'));
      expect(messages.first.content, contains('タグ'));
      expect(messages.first.content, isNot(contains('あらすじ（作者書き）')));
    });

    test('長い本文は均衡抽出で予算内に収まる', () {
      final body = 'A' * 1000 + 'M' * 5000 + 'Z' * 1000;
      final messages = LlmSummaryService.buildPrompt(title: 'T', body: body);
      final user = messages[1].content;
      expect(user.contains('A' * 100), isTrue);
      expect(user.contains('M' * 100), isTrue);
      expect(user.contains('Z' * 100), isTrue);
      expect(user.contains('…（中略）…'), isTrue);
    });

    test('emphasizeRephrase で言い換え指示が追加される', () {
      final normal = LlmSummaryService.buildPrompt(
        title: 'T',
        body: 'B',
      ).last.content;
      final emph = LlmSummaryService.buildPrompt(
        title: 'T',
        body: 'B',
        emphasizeRephrase: true,
      ).last.content;
      expect(emph, contains('自分の言葉で要約し直してください'));
      expect(normal, isNot(contains('自分の言葉で要約し直してください')));
    });
  });

  const goodOutput =
      '【あらすじ】\n一行目の要約。\n二行目の要約。\n三行目の要約。\n'
      '【紹介】\n読み応えのある導入文です。\n'
      '【タグ】\n魔法, 冒険, 青春, 恋愛, ファンタジー';

  group('出力解析', () {
    test('3セクション正常解析', () {
      final r = LlmSummaryService.parseOutput(goodOutput);
      expect(r, isNotNull);
      expect(r!.synopsis, contains('一行目の要約。'));
      expect(r.synopsis, contains('三行目の要約。'));
      expect(r.intro, '読み応えのある導入文です。');
      expect(r.tagSuggestions, ['魔法', '冒険', '青春', '恋愛', 'ファンタジー']);
    });

    test('タグは読点・空白でも分解される', () {
      final r = LlmSummaryService.parseOutput(
        '【あらすじ】a\n【紹介】b\n【タグ】\n剣と魔法、 異世界 転生 ヒーロー 日常',
      );
      expect(r, isNotNull);
      expect(r!.tagSuggestions, ['剣と魔法', '異世界', '転生', 'ヒーロー', '日常']);
    });

    test('タグは最大5件に制限される', () {
      final r = LlmSummaryService.parseOutput(
        '【あらすじ】a\n【紹介】b\n【タグ】\n1, 2, 3, 4, 5, 6, 7',
      );
      expect(r, isNotNull);
      expect(r!.tagSuggestions, hasLength(5));
      expect(r.tagSuggestions.last, '5');
    });

    test('セクション欠如: null', () {
      expect(LlmSummaryService.parseOutput('【あらすじ】a\n【紹介】b'), isNull);
      expect(LlmSummaryService.parseOutput('自由形式の出力です'), isNull);
    });

    test('空出力: null', () {
      expect(LlmSummaryService.parseOutput(''), isNull);
      expect(LlmSummaryService.parseOutput('   '), isNull);
    });

    test('思考タグ付き出力から正しく解析できる', () {
      final r = LlmSummaryService.parseOutput(
        '<think>\nまずは登場人物を整理しよう。\n主語を確認。\n</think>\n'
        '【あらすじ】a\n【紹介】b\n【タグ】剣と魔法, 異世界',
      );
      expect(r, isNotNull);
      expect(r!.synopsis, 'a');
      expect(r.intro, 'b');
      expect(r.tagSuggestions, ['剣と魔法', '異世界']);
    });

    test('閉じ損ねた思考ブロック（本文マーカー以降が残れば解析）', () {
      final r = LlmSummaryService.parseOutput(
        '<thinking>止まらない推論テキスト\n\n'
        '【あらすじ】要約\n【紹介】導入\n【タグ】タグ1',
      );
      expect(r, isNotNull);
      expect(r!.synopsis, '要約');
    });

    test('stripThinkTags: 閉じたタグを除去', () {
      expect(
        LlmSummaryService.stripThinkTags('<THINK>考え事</THINK>本文ここ'),
        '本文ここ',
      );
    });

    test('拒否検知', () {
      expect(
        LlmSummaryService.looksRefused('申し訳ありませんが、その依頼にはお答えできません。'),
        isTrue,
      );
      expect(
        LlmSummaryService.looksRefused('I cannot help with that.'),
        isTrue,
      );
      expect(LlmSummaryService.looksRefused(goodOutput), isFalse);
    });
  });

  group('要約生成オーケストレーション', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('llm_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String writeModel() {
      final f = File('${tmp.path}/model.gguf')..writeAsStringSync('gguf');
      return f.path;
    }

    test('正常出力 -> LlmSummaryResult', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine([goodOutput]),
      );
      await service.loadModel(writeModel());
      final result = await LlmSummaryService.generate(
        service: service,
        title: 'T',
        description: 'D',
        body: 'B',
      );
      expect(result.tagSuggestions, hasLength(5));
    });

    test('拒否 -> 自然なエラーメッセージ', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine(['申し訳ありませんが、お答えできません。']),
      );
      await service.loadModel(writeModel());
      await expectLater(
        LlmSummaryService.generate(
          service: service,
          title: 'T',
          description: 'D',
          body: 'B',
        ),
        throwsA(
          isA<LlmSummaryException>().having(
            (e) => e.message,
            'message',
            contains('拒否'),
          ),
        ),
      );
    });

    test('解析不能 -> 再試行を促すメッセージ', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine(['まったく違う形式の出力']),
      );
      await service.loadModel(writeModel());
      await expectLater(
        LlmSummaryService.generate(
          service: service,
          title: 'T',
          description: 'D',
          body: 'B',
        ),
        throwsA(
          isA<LlmSummaryException>().having(
            (e) => e.message,
            'message',
            contains('解析'),
          ),
        ),
      );
    });

    test('長編はチャンク分割で解析（処理方式=チャンクN分割）', () async {
      final engine = _ResetTrackingEngine(chunks: [goodOutput]);
      final service = LocalLlmService(engineFactory: (p) => engine);
      await service.loadModel(writeModel());
      final big = ('第一章。本文の続き。' * 30 + '\n\n') * 80;
      var lastStage = 0;
      var stageTotal = 0;
      final result = await LlmSummaryService.generate(
        service: service,
        title: 'T',
        body: big,
        onStageProgress: (c, t) {
          lastStage = c;
          stageTotal = t;
        },
      );
      expect(result.processingMode, contains('分割'));
      expect(result.bodySourceNote, contains('分割して解析'));
      expect(engine.generateCalls, greaterThan(2),
          reason: 'チャンク毎の map + 最終生成で複数回呼び出し');
      expect(stageTotal, greaterThan(1));
      expect(lastStage, greaterThanOrEqualTo(1));
    });
  });

  group('M1: オウム返し防止', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('llm_m1_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String writeModel() {
      final f = File('${tmp.path}/model.gguf')..writeAsStringSync('gguf');
      return f.path;
    }

    const desc =
        'この物語は主人公が剣と魔法の世界に転生し、王軍に追われながら、'
        '神秘の少女と出会い、冒険の旅に出る。'
        'テーマは友情の成長と人間関係の絆。'
        'ドキドキ感のある作品。';

    const unrelatedText =
        '海沿いの静かな村。'
        '灯台守と猫の日常が、あたたかい筆致で描かれる。'
        '季節の移ろいと心のおだやかな交わりを描く、ゆっくりとした作品。';

    String parrotOutput() =>
        '【あらすじ】\n'
        'この物語は主人公が剣と魔法の世界に転生し、王軍に追われながら、神秘の少女と出会う。\n'
        'テーマは友情の成長と人間関係の絆。\n'
        'ドキドキ感のある作品。\n'
        '【紹介】\n'
        'この物語は主人公が剣と魔法の世界に転生し、王軍に追われながら、神秘の少女と出会い、冒険の旅に出る。\n'
        '【タグ】\n転生, ファンタジー, 冒険, 少女, 友情';

    test('空本文: フォールバック禁止メッセージを投げる', () async {
      final service = LocalLlmService(
        engineFactory: (p) => _FakeEngine([goodOutput]),
      );
      await service.loadModel(writeModel());
      await expectLater(
        LlmSummaryService.generate(
          service: service,
          title: 'T',
          body: '   ',
          description: desc,
        ),
        throwsA(
          isA<LlmSummaryException>().having(
            (e) => e.message,
            'message',
            '小説本文を取得できないため、AI要約を生成できません。',
          ),
        ),
      );
    });

    test('本文タグの除去（挿絵・ルビ・制御タグ）', () {
      const raw =
          'かつて、[[rb:風 > かぜ]]が吹いた。\n\n'
          '[pixivimage:12345]\n\n'
          '物語はここから始まる。\n[uploadedimage:2]\n[newpage]';
      final out = LlmSummaryService.normalizeNovelBody(raw);
      expect(out, contains('風'));
      expect(out, isNot(contains('かぜ')));
      expect(out, isNot(contains('pixivimage')));
      expect(out, isNot(contains('uploadedimage')));
      expect(out, isNot(contains('newpage')));
      expect(out, contains('物語はここから始まる。'));
    });

    test('コピー検出: 作者説明の丸写しは true / 無関係は false', () {
      expect(
        LlmSummaryService.isExcessiveCopy(
          output: parrotOutput(),
          body: 'まったく別の無関係な本文。説明とは共通点がない文。',
          description: desc,
        ),
        isTrue,
      );
      expect(
        LlmSummaryService.isExcessiveCopy(
          output: unrelatedText,
          body: 'まったく別の無関係な本文。説明とは共通点がない文。',
          description: desc,
        ),
        isFalse,
      );
    });

    test('n-gram重複率: 自己は高い / 無関係は低い / 短文は0', () {
      expect(
        LlmSummaryService.calculateNgramOverlap(output: desc, source: desc),
        greaterThan(0.9),
      );
      expect(
        LlmSummaryService.calculateNgramOverlap(
          output: unrelatedText,
          source: desc,
        ),
        lessThan(0.3),
      );
      expect(
        LlmSummaryService.calculateNgramOverlap(output: 'short', source: desc),
        0.0,
      );
    });

    test('キャッシュなし: 本文取得を呼び出し + キャッシュ保存', () async {
      var fetched = 0;
      var saved = 0;
      final text = await LlmSummaryService.resolveNovelBody(
        workId: 7,
        getCached: (_) async => null,
        fetchText: (id) async {
          fetched++;
          expect(id, 7);
          return NovelTextData(
            id: 7,
            novelText: '取得した本文。',
            novelPages: const [],
          );
        },
        saveToCache: (_) async => saved++,
      );
      expect(text, '取得した本文。');
      expect(fetched, 1);
      expect(saved, 1);
    });

    test('キャッシュあり: 取得を呼ばない', () async {
      var fetched = 0;
      final text = await LlmSummaryService.resolveNovelBody(
        workId: 7,
        getCached: (_) async => {'text': 'キャッシュ済み本文。'},
        fetchText: (_) async {
          fetched++;
          throw StateError('呼ばれるべきでない');
        },
      );
      expect(text, 'キャッシュ済み本文。');
      expect(fetched, 0);
    });

    test('取得失敗: null（作者説明へのフォールバックなし）', () async {
      final text = await LlmSummaryService.resolveNovelBody(
        workId: 7,
        getCached: (_) async => throw StateError('db down'),
        fetchText: (_) async => throw Exception('network down'),
      );
      expect(text, isNull);
    });

    test('過度な重複: 1回だけ再生成（上限1回）-> 2回目は警告なし', () async {
      final engine = _MultiEngine([
        [parrotOutput()],
        [goodOutput],
      ]);
      final service = LocalLlmService(engineFactory: (p) => engine);
      await service.loadModel(writeModel());
      final result = await LlmSummaryService.generate(
        service: service,
        title: 'T',
        body: '本文は作者の紹介とは無関係です。' * 5,
        description: desc,
      );
      expect(engine.callCount, 2, reason: '過度な重複で1回だけ再生成');
      expect(result.copyWarning, isFalse);
      expect(result.bodySourceNote, contains('生成元: 小説本文'));
    });

    test('2回目も過度: copyWarning付きで表示（無限再生成しない）', () async {
      final engine = _MultiEngine([
        [parrotOutput()],
        [parrotOutput()],
      ]);
      final service = LocalLlmService(engineFactory: (p) => engine);
      await service.loadModel(writeModel());
      final result = await LlmSummaryService.generate(
        service: service,
        title: 'T',
        body: '本文は作者の紹介とは無関係です。' * 5,
        description: desc,
      );
      expect(engine.callCount, 2, reason: '無限再生成禁止');
      expect(result.copyWarning, isTrue);
    });

    testWidgets('本文取得失敗: 作者説明を使わずエラー表示', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LlmSummarySheet(
              modelPath: 'unused.gguf',
              title: 'T',
              description: '作者が書いたあらすじ。',
              resolveBody: () async => null,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('小説本文を取得できないため、AI要約を生成できません。'), findsOneWidget);
      expect(find.text('作者が書いたあらすじ。'), findsNothing);
    });
  });

  group('GGUF 発見', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('llm_disc_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('*.gguf を検出する（大文字も・ソート済み）', () async {
      File('${dir.path}/b.GGUF').writeAsStringSync('x');
      File('${dir.path}/a.gguf').writeAsStringSync('x');
      File('${dir.path}/skip.txt').writeAsStringSync('x');
      final found = await LlmModelPaths.discover(dirPath: dir.path);
      expect(found, hasLength(2));
      expect(found.first, endsWith('a.gguf'));
      expect(found.last, endsWith('b.GGUF'));
    });

    test('空ディレクトリ: 空リスト', () async {
      expect(await LlmModelPaths.discover(dirPath: dir.path), isEmpty);
    });

    test('存在しないディレクトリ: 空リスト（例外なし）', () async {
      expect(
        await LlmModelPaths.discover(dirPath: '${dir.path}/nope'),
        isEmpty,
      );
    });
  });

  group('プラットフォーム分岐', () {
    test('Android: 対応', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(LlmModelPaths.isSupportedPlatform(), isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    test('Windows: 非対応', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(LlmModelPaths.isSupportedPlatform(), isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    test('iOS: 非対応', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(LlmModelPaths.isSupportedPlatform(), isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    test('非 Android では resolveModelPath が null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(await LlmModelPaths.resolveModelPath(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('UI: モデル未配置状態', () {
    Novel buildNovel() => Novel(
      id: 1,
      title: 'テスト小説',
      caption: 'テスト用のあらすじ',
      author: Author(id: 10, name: '作者名', account: 'author'),
      tags: const ['タグ1'],
      coverUrl: '',
      textCount: 100,
      wordCount: 100,
      textLength: 100,
      pageCount: 1,
      createDate: '2026-01-01T00:00:00+09:00',
      totalView: 10,
      totalBookmarks: 5,
      isBookmarked: false,
    );

    testWidgets('非 Android: AI要約ボタンは非表示', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(
        MaterialApp(home: NovelDetailScreen(novel: buildNovel())),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('AI要約（実験）'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Android + モデル未配置: AI要約ボタンは非表示', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        MaterialApp(home: NovelDetailScreen(novel: buildNovel())),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('AI要約（実験）'), findsNothing);
      // 読書ボタンは引き続き表示される（機能破壊チェック）
      expect(find.text('小説を読む'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
