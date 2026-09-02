// 小説TTS読み上げサービス（Phase 3）。
//
// - OS標準TTSエンジン（flutter_tts）のみ使用。クラウドTTSは一切使わない。
// - Pixiv ルビ記法 `[[rb:親文字 > ルビ]]` を読み上げ用テキストへ正規化。
// - 本文を文単位のチャンクに分割し、元テキストのページ番号・開始オフセット
//   を保持する（読み上げ位置のUI追従・再開位置の永続化に使用）。
// - 再生状態は idle / playing / paused / completed / error の
//   ステートマシンで管理する。
// - ユニットテスト可能にするため、エンジン依存は [TtsEngine] インターフェース
//   で抽象化し、テキスト処理（正規化・チャンク分割）は純粋関数として分離。
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// TTS読み上げの状態。
enum TtsState { idle, playing, paused, completed, error }

/// 読み上げチャンク。元本文（正規化前）内の位置情報を保持する。
class TtsChunk {
  /// 0始まりのページインデックス。
  final int pageIndex;

  /// ページ本文（正規化前）先頭からの文字オフセット（位置ハイライト用）。
  final int startOffset;

  /// 読み上げ用に正規化済みのテキスト。
  final String text;

  const TtsChunk({
    required this.pageIndex,
    required this.startOffset,
    required this.text,
  });
}

// ---------------------------------------------------------------------------
// テキスト正規化・チャンク分割（純粋関数・単体テスト対象）
// ---------------------------------------------------------------------------

/// Pixiv ルビ記法: [[rb:親文字 > ルビ]]
final RegExp _rubyPattern = RegExp(r'\[\[rb:(.+?)\s*>\s*(.+?)\]\]');

/// 改ページ・ジャンプ・挿絵タグ（本文装飾タグ。読み上げテキストからは除去する）。
/// 挿絵タグの除去は Phase 1（設計書 §8）で追加。
final RegExp _newpagePattern = RegExp(r'\[newpage\]', caseSensitive: false);
final RegExp _jumpPattern = RegExp(r'\[jump:\d+\]', caseSensitive: false);
final RegExp _uploadedImagePattern = RegExp(
  r'\[uploadedimage:\d+\]',
  caseSensitive: false,
);
final RegExp _pixivImagePattern = RegExp(
  r'\[pixivimage:\d+(?:-\d+)?\]',
  caseSensitive: false,
);

/// 読み上げ用に本文を正規化する（純粋関数）。
///
/// - [readRuby] が true ならルビ（かな）側、false なら親文字側を読み上げる。
/// - `[newpage]` / `[jump:N]` 指令と挿絵タグ（`[uploadedimage:N]` /
///   `[pixivimage:N]` / `[pixivimage:N-M]`）を除去する。
/// - 3行以上の連続空行を1空行に圧縮し、前後の空白を除去する。
String normalizeNovelTextForSpeech(String raw, {required bool readRuby}) {
  var text = raw.replaceAllMapped(_rubyPattern, (m) {
    return readRuby ? m.group(2)! : m.group(1)!;
  });
  text = text.replaceAll(_newpagePattern, '');
  text = text.replaceAll(_jumpPattern, '');
  text = text.replaceAll(_uploadedImagePattern, '');
  text = text.replaceAll(_pixivImagePattern, '');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// 文区切りの終端文字。
const String _sentenceTerminators = '。！？!?…\r\n';

/// 元本文内の開始オフセット付きの一文。
class _RawSentenceSpan {
  final int start;
  final String raw;
  const _RawSentenceSpan(this.start, this.raw);
}

/// ページ本文を終端記号（。！？!?…・改行）単位の文に分割する。
List<_RawSentenceSpan> _splitRawSentences(String page) {
  final spans = <_RawSentenceSpan>[];
  var start = 0;
  var i = 0;
  while (i < page.length) {
    if (_sentenceTerminators.contains(page[i])) {
      // 終端記号の連続（例: 「！？」や「。\n」）はまとめて1つの文末とする
      var end = i + 1;
      while (end < page.length && _sentenceTerminators.contains(page[end])) {
        end++;
      }
      spans.add(_RawSentenceSpan(start, page.substring(start, end)));
      start = end;
      i = end;
    } else {
      i++;
    }
  }
  if (start < page.length) {
    spans.add(_RawSentenceSpan(start, page.substring(start)));
  }
  return spans;
}

/// ページ本文列を読み上げチャンクに分割する（純粋関数）。
///
/// - 文単位で [maxChunkChars] を超えないようパッキングする
///   （Android の TTS 入力上限対策。既定 180 文字）。
/// - 1文が上限を超える場合は [maxChunkChars] 毎に強制分割する。
/// - 各チャンクは元本文の pageIndex / startOffset を保持する
///   （チャンク → 元テキスト位置のマッピング）。
/// - ルビ記法は [readRuby] に従い正規化される。
List<TtsChunk> chunkNovelForSpeech(
  List<String> pages, {
  required bool readRuby,
  int maxChunkChars = 180,
}) {
  assert(maxChunkChars > 0, 'maxChunkChars は正の整数である必要があります');
  final chunks = <TtsChunk>[];
  for (var p = 0; p < pages.length; p++) {
    final spans = _splitRawSentences(pages[p]);
    if (spans.isEmpty) continue;
    final buffer = StringBuffer();
    var bufferStart = spans.first.start;
    for (final span in spans) {
      final piece = normalizeNovelTextForSpeech(span.raw, readRuby: readRuby);
      if (piece.isEmpty) continue;
      if (piece.length > maxChunkChars) {
        // バッファ残を吐き出してから、1文を上限毎に強制分割する
        if (buffer.isNotEmpty) {
          chunks.add(
            TtsChunk(
              pageIndex: p,
              startOffset: bufferStart,
              text: buffer.toString().trim(),
            ),
          );
          buffer.clear();
        }
        for (var off = 0; off < piece.length; off += maxChunkChars) {
          final end = (off + maxChunkChars < piece.length)
              ? off + maxChunkChars
              : piece.length;
          chunks.add(
            TtsChunk(
              pageIndex: p,
              startOffset: span.start + off,
              text: piece.substring(off, end),
            ),
          );
        }
        continue;
      }
      if (buffer.isNotEmpty &&
          buffer.length + 1 + piece.length > maxChunkChars) {
        // 次の文を足すと上限を超えるなら現在のバッファを確定する
        chunks.add(
          TtsChunk(
            pageIndex: p,
            startOffset: bufferStart,
            text: buffer.toString().trim(),
          ),
        );
        buffer.clear();
      }
      if (buffer.isEmpty) bufferStart = span.start;
      buffer.write(piece);
      buffer.write(' ');
    }
    if (buffer.isNotEmpty) {
      chunks.add(
        TtsChunk(
          pageIndex: p,
          startOffset: bufferStart,
          text: buffer.toString().trim(),
        ),
      );
    }
  }
  return chunks;
}

// ---------------------------------------------------------------------------
// TTSエンジン抽象（テストで差し替え可能）
// ---------------------------------------------------------------------------

/// TTSエンジンの抽象。テストではフェイクを実装して差し替える。
abstract class TtsEngine {
  /// ロケールを設定する（例: ja-JP）。初回のみ完了待ちの初期化を行う。
  Future<void> initialize(String locale);

  /// 読み上げ速度を設定する（1.0 = 標準速度）。
  Future<void> setSpeechRate(double rate);

  /// ピッチを設定する（1.0 = 標準）。
  Future<void> setPitch(double pitch);

  /// 発話を開始する。awaitSpeakCompletion 有効時は発話完了まで完了しない。
  Future<bool> speak(String text);

  /// 発話を完全に停止する。
  Future<bool> stop();

  /// エンジンを破棄する。
  Future<void> dispose();
}

/// flutter_tts を用いた実機用エンジンラッパー。
class FlutterTtsEngine implements TtsEngine {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  @override
  Future<void> initialize(String locale) async {
    await _tts.setLanguage(locale);
    if (!_initialized) {
      // speak() の Future が発話完了まで待機するようにする
      // （チャンク逐次再生の要。二重待ちを避けるため初回のみ設定）。
      await _tts.awaitSpeakCompletion(true);
      _initialized = true;
    }
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    // flutter_tts の速度スケールはプラットフォーム毎に異なる:
    // Android/Web: 1.0=標準 / iOS: 0.5=標準。1.0=標準速度に正規化して渡す。
    final double engineRate =
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
        ? rate / 2.0
        : rate;
    await _tts.setSpeechRate(engineRate);
  }

  @override
  Future<void> setPitch(double pitch) async {
    await _tts.setPitch(pitch.clamp(0.5, 2.0));
  }

  @override
  Future<bool> speak(String text) async {
    try {
      final result = await _tts.speak(text);
      return result != false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> stop() async {
    try {
      await _tts.stop();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {
      // 破棄時の失敗は無視
    }
  }
}

// ---------------------------------------------------------------------------
// 読み上げステートマシン
// ---------------------------------------------------------------------------

/// 小説TTS読み上げのステートマシン＋エンジン制御。
///
/// 再生は「チャンク配列 + 現在インデックス」で管理し、
/// speak() の完了Futureを待って次チャンクへ進める。
/// 一時停止は全プラットフォームで「エンジン停止 → 現在チャンクの先頭から
/// 再開」の方式に統一する（flutter_tts に発話再開APIが存在しないため）。
class NovelTtsService {
  // ignore: prefer_initializing_formals
  NovelTtsService(this._engine, {String locale = 'ja-JP'}) : _locale = locale;

  final TtsEngine _engine;
  final String _locale;

  List<TtsChunk> _chunks = const [];
  int _index = -1;
  TtsState _state = TtsState.idle;
  double _rate = 1.0;
  int _runId = 0;

  /// 現在の再生状態。
  TtsState get state => _state;

  /// 現在読み上げ中のチャンク番号（-1=未再生）。
  int get currentIndex => _index;

  /// 現在読み上げ中のチャンク（なければ null）。
  TtsChunk? get currentChunk =>
      (_index >= 0 && _index < _chunks.length) ? _chunks[_index] : null;

  /// 登録チャンク総数。
  int get chunkCount => _chunks.length;

  /// 状態遷移時のコールバック。
  void Function(TtsState state)? onStateChanged;

  /// 各チャンク読み上げ開始時のコールバック（UI追従・位置保存に使用）。
  void Function(int index, TtsChunk chunk)? onChunkStart;

  /// 全チャンク読み上げ完了時のコールバック。
  void Function()? onAllCompleted;

  /// エラー発生時のコールバック。
  void Function(String message)? onError;

  void _setState(TtsState next) {
    if (_state == next) return;
    _state = next;
    onStateChanged?.call(next);
  }

  /// 読み上げを開始する。返す Future はセッション終了
  /// （全チャンク読了・停止・エラー）まで完了しないため、UI からは
  /// unawaited で呼ぶこと。
  Future<void> start(
    List<TtsChunk> chunks, {
    int startIndex = 0,
    double rate = 1.0,
    double pitch = 1.0,
  }) async {
    // 二重開始の保護: 実行中のループを無効化してから新しいセッションを開始
    _runId++;
    final myRun = _runId;
    await _haltEngine();

    _chunks = List<TtsChunk>.unmodifiable(chunks);
    _rate = rate;
    if (_chunks.isEmpty) {
      _index = -1;
      _setState(TtsState.completed);
      onAllCompleted?.call();
      return;
    }
    var start = startIndex;
    if (start < 0) start = 0;
    if (start >= _chunks.length) start = _chunks.length - 1;
    _index = start;
    try {
      await _engine.initialize(_locale);
      await _engine.setSpeechRate(_rate);
      await _engine.setPitch(pitch);
    } catch (e) {
      _setState(TtsState.error);
      onError?.call('TTSエンジンの初期化に失敗しました: $e');
      return;
    }
    _setState(TtsState.playing);
    await _runLoop(myRun);
  }

  /// エンジンを停止して待機中の発話を打ち切る（状態は変更しない）。
  Future<void> _haltEngine() async {
    try {
      await _engine.stop();
    } catch (_) {
      // 停止失敗は無視（未初期化等）
    }
  }

  Future<void> _runLoop(int myRun) async {
    while (_runId == myRun &&
        _state == TtsState.playing &&
        _index >= 0 &&
        _index < _chunks.length) {
      final chunk = _chunks[_index];
      onChunkStart?.call(_index, chunk);
      final ok = await _engine.speak(chunk.text);
      if (_runId != myRun) return; // 新しい start() に交代した
      // pause/stop による打ち切りを「失敗」と誤判定しないよう状態を先に確認する
      // （Android では stop() が保留中の発話Futureを失敗扱いで完了させる場合がある）
      if (_state != TtsState.playing) return; // pause/stop された
      if (!ok) {
        _setState(TtsState.error);
        onError?.call('読み上げに失敗しました');
        return;
      }
      _index++;
    }
    if (_runId == myRun && _state == TtsState.playing) {
      // 全チャンクを読了
      _setState(TtsState.completed);
      onAllCompleted?.call();
    }
  }

  /// 読み上げを一時停止する。
  ///
  /// flutter_tts には発話再開APIが存在しないため、すべてのプラットフォームで
  /// 「停止して現在チャンクの先頭から再開する」方式に統一する。
  Future<void> pause() async {
    if (_state != TtsState.playing) return;
    // 先に状態を切る（完了Futureの誤進行を防止する）
    _setState(TtsState.paused);
    await _haltEngine();
  }

  /// 一時停止から再開する。
  /// 返す Future は再開後の再生セッション終了まで完了しないため、
  /// UI からは unawaited で呼ぶこと。
  Future<void> resume() async {
    if (_state != TtsState.paused) return;
    _setState(TtsState.playing);
    // 現在チャンクの先頭から再読み上げする
    await _runLoop(_runId);
  }

  /// 再生速度を変更する（再生中も即時反映）。
  Future<void> setRate(double rate) async {
    _rate = rate;
    try {
      await _engine.setSpeechRate(rate);
    } catch (_) {
      // 速度変更失敗は無視
    }
  }

  /// 読み上げを停止する（idle へ遷移）。
  Future<void> stop() async {
    if (_state == TtsState.idle) return;
    _setState(TtsState.idle);
    await _haltEngine();
  }

  /// サービスを破棄する（エンジンも停止）。
  Future<void> disposeService() async {
    await stop();
    try {
      await _engine.dispose();
    } catch (_) {
      // 破棄失敗は無視
    }
  }
}
