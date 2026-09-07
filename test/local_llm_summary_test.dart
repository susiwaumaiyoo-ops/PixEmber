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
import 'package:llamadart/llamadart.dart'
    show
        GenerationParams,
        LlamaChatMessage,
        LlamaChatRole,
        LlamaCompletionChunk,
        LlamaCompletionChunkChoice,
        LlamaCompletionChunkDelta;
import 'package:pixiv_viewer/illust_model.dart';
import 'package:pixiv_viewer/novel_model.dart';
import 'package:pixiv_viewer/screens/novel_detail_screen.dart';
import 'package:pixiv_viewer/services/llm_summary_service.dart';
import 'package:pixiv_viewer/services/local_llm_service.dart';

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
  Stream<LlamaCompletionChunk> generate({
    required List<LlamaChatMessage> messages,
    required GenerationParams options,
  }) async* {
    for (final c in chunks) {
      await Future<void>.delayed(chunkDelay);
      yield _chunk(c);
    }
    if (error != null) throw error!;
  }

  static LlamaCompletionChunk _chunk(String text) {
    return LlamaCompletionChunk(
      id: 'fake',
      object: 'chat.completion.chunk',
      created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      model: 'fake',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(content: text),
        ),
      ],
    );
  }

  @override
  void dispose() {}
}

final _userMsg = [
  LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
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

  group('2000文字截断', () {
    test('2000字未満: 変更なし', () {
      final s = 'a' * 1999;
      expect(LlmSummaryService.clampBody(s), s);
    });

    test('ちょうど2000字: 変更なし', () {
      final s = 'a' * 2000;
      expect(LlmSummaryService.clampBody(s), s);
      expect(LlmSummaryService.clampBody(s).length, 2000);
    });

    test('2000字超過: ちょうど2000字に截断', () {
      final s = 'a' * 2500;
      final out = LlmSummaryService.clampBody(s);
      expect(out.length, 2000);
      expect(out, 'a' * 2000);
    });

    test('前後の空白は除去される', () {
      expect(LlmSummaryService.clampBody('  本文  '), '本文');
    });

    test('空文字列: 空', () {
      expect(LlmSummaryService.clampBody(''), '');
      expect(LlmSummaryService.clampBody('   '), '');
    });

    test('日本語文字も文字数で截断', () {
      final s = 'あ' * 2100;
      expect(LlmSummaryService.clampBody(s).length, 2000);
    });
  });

  group('プロンプト構築', () {
    test('タイトル・説明・タグを含む', () {
      final messages = LlmSummaryService.buildPrompt(
        title: 'テスト小説',
        description: 'あらすじです',
        tags: ['魔法', '青春'],
        body: '本文の冒頭。',
      );
      expect(messages, hasLength(2));
      final user = messages[1].content;
      expect(user, contains('テスト小説'));
      expect(user, contains('あらすじです'));
      expect(user, contains('魔法'));
      expect(user, contains('青春'));
      expect(user, contains('本文の冒頭。'));
    });

    test('system が先頭メッセージ', () {
      final messages = LlmSummaryService.buildPrompt(
        title: 'T',
        description: 'D',
        body: 'B',
      );
      expect(messages.first.role, LlamaChatRole.system);
      expect(messages.last.role, LlamaChatRole.user);
      // 日本語の形式指示が含まれる
      expect(messages.first.content, contains('あらすじ'));
      expect(messages.first.content, contains('紹介'));
      expect(messages.first.content, contains('タグ'));
    });

    test('長い本文は2000字で截断される', () {
      final messages = LlmSummaryService.buildPrompt(
        title: 'T',
        description: 'D',
        body: 'x' * 2500,
      );
      final user = messages[1].content;
      expect(user.contains('x' * 2000), isTrue);
      expect(user.contains('x' * 2001), isFalse);
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
