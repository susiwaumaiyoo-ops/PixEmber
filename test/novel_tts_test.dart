// Phase 3 小説TTS読み上げのユニットテスト。
//
// 対象:
// - 純粋関数: normalizeNovelTextForSpeech / chunkNovelForSpeech
// - NovelTtsService ステートマシン（フェイクエンジンで差し替え）
// - tts_reading_positions（DB v18）CRUD（sqflite_ffi インメモリDB）
//
// 実TTSエンジン・ネットワーク・ファイルシステムには依存しない。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_viewer/services/database_service.dart';
import 'package:pixiv_viewer/services/novel_tts_service.dart';

/// テスト用TTSエンジンフェイク。
class _FakeTtsEngine implements TtsEngine {
  /// true の場合、speak() の完了Futureを保留し、
  /// finishPendingSpeak() か stop() で打ち切られるまで完了しない
  /// （再生中の割り込みタイミングを再現するための制御）。
  bool manualSpeakCompletion = false;
  bool failOnSpeak = false;

  int initializeCount = 0;
  int speakCount = 0;
  int stopCount = 0;
  int disposeCount = 0;
  double? lastRate;
  double? lastPitch;
  final List<String> spokenTexts = <String>[];

  Completer<bool>? _pendingSpeak;

  /// 保留中の発話を完了させる（テストからの手動制御用）。
  void finishPendingSpeak([bool result = true]) {
    final p = _pendingSpeak;
    _pendingSpeak = null;
    if (p != null && !p.isCompleted) p.complete(result);
  }

  @override
  Future<void> initialize(String locale) async {
    initializeCount++;
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    lastRate = rate;
  }

  @override
  Future<void> setPitch(double pitch) async {
    lastPitch = pitch;
  }

  @override
  Future<bool> speak(String text) async {
    spokenTexts.add(text);
    speakCount++;
    if (failOnSpeak) return false;
    if (!manualSpeakCompletion) return true;
    _pendingSpeak = Completer<bool>();
    return _pendingSpeak!.future;
  }

  @override
  Future<bool> stop() async {
    stopCount++;
    // 実エンジンと同様、stop() は保留中の発話Futureを完了させる
    finishPendingSpeak(true);
    return true;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

/// イベントループを数周回して非同期処理を進める。
Future<void> _pump([int times = 8]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<TtsChunk> _chunks3() => const [
  TtsChunk(pageIndex: 0, startOffset: 0, text: '一つ目。'),
  TtsChunk(pageIndex: 0, startOffset: 5, text: '二つ目。'),
  TtsChunk(pageIndex: 1, startOffset: 0, text: '三つ目。'),
];

void main() {
  // ==========================================================================
  // 純粋関数: normalizeNovelTextForSpeech
  // ==========================================================================
  group('normalizeNovelTextForSpeech', () {
    test('ルビを親文字側に展開する（readRuby: false）', () {
      expect(
        normalizeNovelTextForSpeech('[[rb:東京都 > とうきょうと]]へ行く', readRuby: false),
        '東京都へ行く',
      );
    });

    test('ルビをかな側に展開する（readRuby: true）', () {
      expect(
        normalizeNovelTextForSpeech('[[rb:東京都 > とうきょうと]]へ行く', readRuby: true),
        'とうきょうとへ行く',
      );
    });

    test('ルビ記法内の空白を許容する', () {
      expect(
        normalizeNovelTextForSpeech('[[rb:親文字 > みやこ]]', readRuby: false),
        '親文字',
      );
    });

    test('[newpage]/[jump:N] 指令を除去する', () {
      expect(normalizeNovelTextForSpeech('あ[newpage]い', readRuby: false), 'あい');
      expect(normalizeNovelTextForSpeech('さ[jump:5]し', readRuby: false), 'さし');
      expect(
        normalizeNovelTextForSpeech('[Newpage][JUMP:3]', readRuby: false),
        '',
      );
    });

    test('3行以上の連続空行を1空行に圧縮する', () {
      expect(
        normalizeNovelTextForSpeech('あ\n\n\n\nい', readRuby: false),
        'あ\n\nい',
      );
    });

    test('前後の空白を除去する', () {
      expect(normalizeNovelTextForSpeech('  あ  ', readRuby: false), 'あ');
    });
  });

  // ==========================================================================
  // 純粋関数: chunkNovelForSpeech
  // ==========================================================================
  group('chunkNovelForSpeech', () {
    test('1ページ内の短い文は1チャンクにパックされる', () {
      final chunks = chunkNovelForSpeech([
        'これは一文です。短い文。もう一つ。',
      ], readRuby: false);
      expect(chunks, hasLength(1));
      expect(chunks[0].pageIndex, 0);
      expect(chunks[0].startOffset, 0);
      expect(chunks[0].text, 'これは一文です。 短い文。 もう一つ。');
    });

    test('複数ページは pageIndex を保持した別チャンクになる', () {
      final chunks = chunkNovelForSpeech(['一ページ目。', '二ページ目。'], readRuby: false);
      expect(chunks, hasLength(2));
      expect(chunks[0].pageIndex, 0);
      expect(chunks[1].pageIndex, 1);
      expect(chunks[1].startOffset, 0);
    });

    test('次の文で上限を超える場合は新チャンクを始める', () {
      final page = 'あいうえお。' * 3; // 6文字の文 × 3
      final chunks = chunkNovelForSpeech(
        [page],
        readRuby: false,
        maxChunkChars: 10,
      );
      // 1文6文字: 2文目で 7+1+6 > 10 のため1文ずつ別チャンクになる
      expect(chunks, hasLength(3));
      expect(chunks[0].text, 'あいうえお。');
      expect(chunks[1].startOffset, 6);
    });

    test('上限内に収まる文は同じチャンクにパックされる', () {
      final chunks = chunkNovelForSpeech(
        ['あい。うえ。'],
        readRuby: false,
        maxChunkChars: 10,
      );
      expect(chunks, hasLength(1));
      expect(chunks[0].text, 'あい。 うえ。');
    });

    test('startOffset は元本文の文字位置を指す', () {
      final chunks = chunkNovelForSpeech(
        ['あいう。かきく。'],
        readRuby: false,
        maxChunkChars: 4,
      );
      expect(chunks, hasLength(2));
      expect(chunks[0].startOffset, 0);
      // 'あいう。' は元本文の位置 0-3 を占めるため、2文目は位置 4 から始まる
      expect(chunks[1].startOffset, 4);
    });

    test('1文が上限を超える場合は上限毎に強制分割する', () {
      final long = 'あ' * 25; // 終端記号なしの25文字
      final chunks = chunkNovelForSpeech(
        [long],
        readRuby: false,
        maxChunkChars: 10,
      );
      expect(chunks, hasLength(3));
      expect(chunks[0].text, 'あ' * 10);
      expect(chunks[1].text, 'あ' * 10);
      expect(chunks[2].text, 'あ' * 5);
      expect(chunks[1].startOffset, 10);
      expect(chunks[2].startOffset, 20);
    });

    test('ルビ読み方設定がチャンクテキストへ反映される', () {
      const page = '[[rb:漢字 > かんじ]]だ。';
      final parent = chunkNovelForSpeech([page], readRuby: false);
      final ruby = chunkNovelForSpeech([page], readRuby: true);
      expect(parent.single.text, '漢字だ。');
      expect(ruby.single.text, 'かんじだ。');
    });

    test('空ページは空チャンクを生まない', () {
      final chunks = chunkNovelForSpeech(['', '　'], readRuby: false);
      expect(chunks, isEmpty);
    });
  });

  // ==========================================================================
  // NovelTtsService ステートマシン
  // ==========================================================================
  group('NovelTtsService ステートマシン', () {
    test('全チャンク読了で completed になる', () async {
      final engine = _FakeTtsEngine();
      final service = NovelTtsService(engine);
      final states = <TtsState>[];
      final chunkStarts = <int>[];
      var completed = false;
      service.onStateChanged = states.add;
      service.onChunkStart = (i, c) => chunkStarts.add(i);
      service.onAllCompleted = () => completed = true;

      await service.start(_chunks3());

      expect(service.state, TtsState.completed);
      expect(engine.initializeCount, 1);
      expect(engine.speakCount, 3);
      expect(engine.spokenTexts, ['一つ目。', '二つ目。', '三つ目。']);
      expect(chunkStarts, [0, 1, 2]);
      expect(completed, isTrue);
      expect(states, [TtsState.playing, TtsState.completed]);
    });

    test('空チャンクリストは即 completed になる', () async {
      final engine = _FakeTtsEngine();
      final service = NovelTtsService(engine);
      var completed = false;
      service.onAllCompleted = () => completed = true;

      await service.start(const []);

      expect(service.state, TtsState.completed);
      expect(engine.speakCount, 0);
      expect(completed, isTrue);
    });

    test('発話失敗で error に遷移する', () async {
      final engine = _FakeTtsEngine()..failOnSpeak = true;
      final service = NovelTtsService(engine);
      var errorMessage = '';
      service.onError = (m) => errorMessage = m;

      await service.start(_chunks3());

      expect(service.state, TtsState.error);
      expect(errorMessage, isNotEmpty);
      expect(engine.speakCount, 1); // 最初のチャンクで失敗して停止
    });

    test('startIndex から再生を開始できる', () async {
      final engine = _FakeTtsEngine();
      final service = NovelTtsService(engine);

      await service.start(_chunks3(), startIndex: 1);

      expect(engine.spokenTexts, ['二つ目。', '三つ目。']);
      expect(service.state, TtsState.completed);
    });

    test('pause で停止し現在チャンクの先頭から再開する', () async {
      final engine = _FakeTtsEngine()..manualSpeakCompletion = true;
      final service = NovelTtsService(engine);
      final session = service.start(_chunks3());
      await _pump();
      expect(engine.speakCount, 1);
      expect(service.state, TtsState.playing);

      await service.pause();
      expect(service.state, TtsState.paused);
      // start 時の halt(1) + pause 時の halt(2)
      expect(engine.stopCount, 2);
      // stop() で保留中の発話Futureが完了しても error に遷移しない
      await _pump();
      expect(service.state, TtsState.paused);
      await session; // 旧ループはここで正常終了している

      // resume() は新しい再生セッション（完了まで解けないFuture）を返す
      final resumeSession = service.resume();
      await _pump();
      expect(service.state, TtsState.playing);
      expect(engine.speakCount, 2); // 現在チャンクの先頭から読み直す
      expect(engine.spokenTexts.last, '一つ目。');

      engine.finishPendingSpeak(); // 1チャンク目（再読）完了
      await _pump();
      expect(engine.speakCount, 3);
      engine.finishPendingSpeak(); // 2チャンク目完了
      await _pump();
      expect(engine.speakCount, 4);
      engine.finishPendingSpeak(); // 3チャンク目完了
      await resumeSession;

      expect(service.state, TtsState.completed);
      expect(engine.spokenTexts, ['一つ目。', '一つ目。', '二つ目。', '三つ目。']);
    });

    test('二重start保護: 実行中の旧ループは無効化される', () async {
      final engine = _FakeTtsEngine()..manualSpeakCompletion = true;
      final service = NovelTtsService(engine);

      final sessionA = service.start(_chunks3());
      await _pump();
      expect(engine.speakCount, 1); // A の1チャンク目が発話中

      final chunksB = const [
        TtsChunk(pageIndex: 0, startOffset: 0, text: 'びー1'),
        TtsChunk(pageIndex: 0, startOffset: 0, text: 'びー2'),
      ];
      final sessionB = service.start(chunksB);
      await _pump();
      // 旧セッション A は runId 不一致で打ち切り、B の1チャンク目が発話中
      expect(engine.speakCount, 2);
      expect(engine.spokenTexts.last, 'びー1');
      expect(service.state, TtsState.playing);

      engine.finishPendingSpeak();
      await _pump();
      expect(engine.speakCount, 3); // B の2チャンク目
      engine.finishPendingSpeak();
      await sessionB;
      await sessionA; // 旧セッションも（無効化されて）正常終了している

      expect(service.state, TtsState.completed);
      expect(engine.spokenTexts, ['一つ目。', 'びー1', 'びー2']);
    });

    test('stop で idle に戻り発話が進まない', () async {
      final engine = _FakeTtsEngine()..manualSpeakCompletion = true;
      final service = NovelTtsService(engine);
      final session = service.start(_chunks3());
      await _pump();
      expect(service.state, TtsState.playing);

      await service.stop();
      expect(service.state, TtsState.idle);
      await session;

      expect(engine.speakCount, 1);
      // start 時の halt(1) + stop 時の halt(2)
      expect(engine.stopCount, 2);
    });

    test('setRate はエンジンへ反映される', () async {
      final engine = _FakeTtsEngine();
      final service = NovelTtsService(engine);

      await service.start(_chunks3(), rate: 2.0);
      expect(engine.lastRate, 2.0);

      await service.setRate(1.5);
      expect(engine.lastRate, 1.5);
    });

    test('disposeService でエンジンを破棄する', () async {
      final engine = _FakeTtsEngine();
      final service = NovelTtsService(engine);

      await service.start(_chunks3());
      await service.disposeService();

      expect(service.state, TtsState.idle);
      expect(engine.disposeCount, 1);
    });
  });

  // ==========================================================================
  // tts_reading_positions CRUD（DB v18）
  // ==========================================================================
  group('tts_reading_positions CRUD（DB v18）', () {
    late DatabaseService db;
    late Database testDb;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      db = DatabaseService();
      testDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 18,
          onCreate: (d, v) async {
            // v18 の tts_reading_positions と同一スキーマ
            await d.execute('''
              CREATE TABLE IF NOT EXISTS tts_reading_positions (
                work_id INTEGER PRIMARY KEY,
                chunk_index INTEGER NOT NULL DEFAULT 0,
                page_index INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
              )
            ''');
          },
        ),
      );
      db.setTestDatabase(testDb);
    });

    tearDown(() async {
      await testDb.close();
      await db.restartDatabase();
    });

    test('saveTtsPosition + getTtsPosition のラウンドトリップ', () async {
      await db.saveTtsPosition(workId: 123, chunkIndex: 4, pageIndex: 2);
      final row = await db.getTtsPosition(123);
      expect(row, isNotNull);
      expect(row!['work_id'], 123);
      expect(row['chunk_index'], 4);
      expect(row['page_index'], 2);
      expect(row['updated_at'], isNotEmpty);
    });

    test('saveTtsPosition は同一 work_id を UPSERT する', () async {
      await db.saveTtsPosition(workId: 1, chunkIndex: 0, pageIndex: 0);
      await db.saveTtsPosition(workId: 1, chunkIndex: 9, pageIndex: 3);

      final rows = await testDb.query('tts_reading_positions');
      expect(rows, hasLength(1));
      expect(rows.first['chunk_index'], 9);
      expect(rows.first['page_index'], 3);
    });

    test('未保存の work_id は null を返す', () async {
      expect(await db.getTtsPosition(999), isNull);
    });

    test('deleteTtsPosition で行を削除できる', () async {
      await db.saveTtsPosition(workId: 5, chunkIndex: 1, pageIndex: 1);
      expect(await db.deleteTtsPosition(5), 1);
      expect(await db.getTtsPosition(5), isNull);
      expect(await db.deleteTtsPosition(5), 0);
    });

    test('DDL は IF NOT EXISTS で冪等（v17→v18 再適用が安全）', () async {
      await db.saveTtsPosition(workId: 77, chunkIndex: 2, pageIndex: 1);
      // _createTtsReadingPositions と同一の DDL を再実行しても既存データは保持される
      await testDb.execute('''
        CREATE TABLE IF NOT EXISTS tts_reading_positions (
          work_id INTEGER PRIMARY KEY,
          chunk_index INTEGER NOT NULL DEFAULT 0,
          page_index INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL
        )
      ''');
      final row = await db.getTtsPosition(77);
      expect(row, isNotNull);
      expect(row!['chunk_index'], 2);
    });
  });
}
