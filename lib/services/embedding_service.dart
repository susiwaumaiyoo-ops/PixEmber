import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// Isolate で実行する重い語彙パース処理（型安全版）
/// JSON デコードと大規模マップ構築をメインスレッドからオフロード
/// 型キャストエラーを防ぐため、is チェックによる安全な型判定を使用
Future<Map<String, int>> _parseVocabInIsolate(String tokenizerJson) async {
  final dynamic decoded = jsonDecode(tokenizerJson);
  final Map<String, int> vocab = {};

  if (decoded is Map<String, dynamic>) {
    // 1. 'model' -> 'vocab' (Map形式) の安全な読み込み
    final model = decoded['model'];
    if (model is Map<String, dynamic>) {
      final rawVocab = model['vocab'];
      if (rawVocab is Map) {
        rawVocab.forEach((key, value) {
          if (value is int) {
            vocab[key.toString()] = value;
          }
        });
      }
    }

    // 2. 'added_tokens' (List形式) の安全な読み込み
    final addedTokens = decoded['added_tokens'];
    if (addedTokens is List) {
      for (final token in addedTokens) {
        if (token is Map && token['content'] != null && token['id'] is int) {
          vocab[token['content'].toString()] = token['id'] as int;
        }
      }
    }

    // 3. max_seq_length があれば取得（truncation 設定から）
    int? maxSeqLength;
    final truncation = decoded['truncation'];
    if (truncation is Map<String, dynamic> && truncation['max_length'] is int) {
      maxSeqLength = truncation['max_length'] as int;
    }

    // maxSeqLength も含めて返す（特別なキーで）
    if (maxSeqLength != null) {
      vocab['__max_seq_length__'] = maxSeqLength;
    }
  }

  return vocab;
}

/// 日本語対応軽量Embeddingモデル（paraphrase-multilingual-MiniLM-L12-v2 等）を用いた
/// ローカルONNX推論サービス。
/// - アセットからモデル・トークナイザーを読み込み
/// - テキストをトークナイズして入力テンソル生成
/// - ONNX Runtime で推論実行
/// - 平均プーリングで単一ベクトル（384次元等）を出力
class EmbeddingService {
  static final EmbeddingService _instance = EmbeddingService._internal();
  factory EmbeddingService() => _instance;
  EmbeddingService._internal();

  OrtSession? _session;
  final Map<String, int> _vocab = {};
  int _maxSeqLength = 128; // パディング/切り捨て長
  bool _isInitialized = false;
  String? _initError;
  final Completer<void> _initCompleter = Completer<void>();

  /// 初期化完了を待つ
  Future<void> get ready => _initCompleter.future;

  /// 初期化エラーを取得（失敗時のみ非null）
  String? get initError => _initError;

  /// 初期化成功かどうか
  bool get isInitialized => _isInitialized;

  /// 非同期初期化：モデルとトークナイザーの読み込み
  /// 例外を内部でキャッチし、アプリクラッシュを防ぐ
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      // 1. 語彙（vocab）読み込み
      await _loadVocab();

      // 2. ONNX モデル読み込み
      final ort = OnnxRuntime();
      _session = await ort.createSessionFromAsset(
        'assets/models/embedding_model.onnx',
      );

      // 入力名・出力名の確認（デバッグ用）
      // print('Input names: ${_session!.inputNames}');
      // print('Output names: ${_session!.outputNames}');

      _isInitialized = true;
      _initError = null;
      _initCompleter.complete();
    } catch (e) {
      _isInitialized = false;
      _initError = e.toString();
      _initCompleter.completeError(e);
      // 例外を再スローせず、アプリクラッシュを防止
    }
  }

  /// tokenizer.json から語彙マップを構築（vocab.txt は使用しない）
  /// 重い JSON デコードとマップ構築は Isolate.run() でオフロード
  Future<void> _loadVocab() async {
    final tokenizerJson = await rootBundle.loadString(
      'assets/models/tokenizer.json',
    );

    // Isolate で重いパース処理を実行
    final parsedVocab = await Isolate.run(
      () => _parseVocabInIsolate(tokenizerJson),
    );

    // max_seq_length を抽出（特別なキーで渡される）
    final maxSeqLength = parsedVocab.remove('__max_seq_length__');
    if (maxSeqLength != null) {
      _maxSeqLength = maxSeqLength;
    }

    // パースされた語彙をマージ
    _vocab.addAll(parsedVocab);

    // 4. 必須特殊トークンが欠けている場合のフォールバック（tokenizer_config.json も確認）
    await _ensureSpecialTokens();

    if (_vocab.isEmpty) {
      throw StateError('語彙マップの構築に失敗しました: tokenizer.json から vocab を読み込めません');
    }
  }

  /// tokenizer_config.json から不足している特殊トークンを補完
  Future<void> _ensureSpecialTokens() async {
    const specialTokenKeys = [
      'bos_token',
      'cls_token',
      'eos_token',
      'pad_token',
      'sep_token',
      'unk_token',
      'mask_token',
    ];

    try {
      final configJson = await rootBundle.loadString(
        'assets/models/tokenizer_config.json',
      );
      final Map<String, dynamic> config = jsonDecode(configJson);

      for (final key in specialTokenKeys) {
        if (config.containsKey(key)) {
          final tokenValue = config[key];
          String? tokenStr;
          if (tokenValue is String) {
            tokenStr = tokenValue;
          } else if (tokenValue is Map && tokenValue['content'] is String) {
            // AddedToken 形式の場合
            tokenStr = tokenValue['content'] as String;
          }
          if (tokenStr != null && !_vocab.containsKey(tokenStr)) {
            // IDは適当な値を割り当て（実際のIDは学習済みモデルに依存）
            // ここでは既存のvocabサイズ以降を使う
            _vocab[tokenStr] = _vocab.length;
          }
        }
      }
    } catch (_) {
      // tokenizer_config.json が読めなくても無視（model.vocab に含まれていればOK）
    }
  }

  /// 単一テキストをベクトル化
  /// 返り値: Float32List (次元数 = モデルの隠れ層サイズ、通常 384 or 768)
  Future<Float32List> encode(String text) async {
    await ready;

    // トークナイズ
    final inputIds = _tokenize(text);
    final attentionMask = List<int>.filled(inputIds.length, 1);

    // パディング
    final paddedLength = _maxSeqLength;
    final paddedInputIds = _padOrTruncate(
      inputIds,
      paddedLength,
      _vocab['<pad>'] ?? _vocab['[PAD]'] ?? 0,
    );
    final paddedAttentionMask = _padOrTruncate(attentionMask, paddedLength, 0);

    // Type IDs (segment embeddings) - 単一文なら全て0
    final tokenTypeIds = List<int>.filled(paddedLength, 0);

    // Int64List に明示的に変換 (ONNXモデルは tensor(int64) を期待)
    final inputIdsInt64 = Int64List.fromList(paddedInputIds);
    final attentionMaskInt64 = Int64List.fromList(paddedAttentionMask);
    final tokenTypeIdsInt64 = Int64List.fromList(tokenTypeIds);

    // 入力テンソル作成 (batch=1, seq_len)
    OrtValue? inputIdsTensor;
    OrtValue? attentionMaskTensor;
    OrtValue? tokenTypeIdsTensor;
    OrtValue? outputTensor;

    try {
      inputIdsTensor = await OrtValue.fromList(inputIdsInt64, [
        1,
        paddedLength,
      ]);
      attentionMaskTensor = await OrtValue.fromList(attentionMaskInt64, [
        1,
        paddedLength,
      ]);
      tokenTypeIdsTensor = await OrtValue.fromList(tokenTypeIdsInt64, [
        1,
        paddedLength,
      ]);

      // 推論実行
      final outputs = await _session!.run({
        _session!.inputNames[0]: inputIdsTensor,
        _session!.inputNames[1]: attentionMaskTensor,
        _session!.inputNames[2]: tokenTypeIdsTensor,
      });

      // 出力: last_hidden_state [batch, seq_len, hidden_size]
      // OrtValue から平坦化された List<double> を取得 (row-major)
      outputTensor = outputs[_session!.outputNames[0]]!;
      final lastHiddenState = await outputTensor.asFlattenedList();

      // 形状推定: [1, seq_len, hidden_size]
      // batch=1 なので、実質 [seq_len, hidden_size]
      // lastHiddenState.length = seq_len * hidden_size
      // attention_mask から有効な seq_len を推定
      int actualSeqLen = 0;
      for (int i = 0; i < paddedLength; i++) {
        if (paddedAttentionMask[i] == 1) actualSeqLen++;
      }
      if (actualSeqLen == 0) actualSeqLen = 1;

      final hiddenSize = lastHiddenState.length ~/ actualSeqLen;

      // 平均プーリング (attention_mask でマスク)
      final pooled = Float32List(hiddenSize);
      for (int i = 0; i < actualSeqLen; i++) {
        if (paddedAttentionMask[i] == 0) continue;
        final offset = i * hiddenSize;
        for (int j = 0; j < hiddenSize; j++) {
          pooled[j] += lastHiddenState[offset + j];
        }
      }

      // 有効トークン数で割る
      final validTokens = paddedAttentionMask.where((m) => m == 1).length;
      if (validTokens > 0) {
        for (int j = 0; j < hiddenSize; j++) {
          pooled[j] /= validTokens;
        }
      }

      // L2正規化（コサイン類似度計算を高速化するため）
      _l2Normalize(pooled);

      // 🚨 Nativeメモリ参照を断ち切るため標準の Float32List に安全コピーして返却
      return Float32List.fromList(pooled.toList());
    } finally {
      // 🚨 推論終了時に必ず C++ Native メモリを解放する
      await inputIdsTensor?.dispose();
      await attentionMaskTensor?.dispose();
      await tokenTypeIdsTensor?.dispose();
      await outputTensor?.dispose();
    }
  }

  /// 複数テキストを一括ベクトル化
  /// 各 encode() 内で try-finally による OrtValue 解放済み
  Future<List<Float32List>> encodeBatch(List<String> texts) async {
    final futures = texts.map((t) => encode(t));
    return Future.wait(futures);
  }

  /// BERTスタイルの簡易トークナイザー（WordPiece）
  List<int> _tokenize(String text) {
    final tokens = <String>[];

    // 簡易的な前処理：小文字化、基本的なクリーニング
    final normalized = text.toLowerCase().trim();

    // 特殊トークンの取得（tokenizer.json / tokenizer_config.json から読み込まれたものを使用）
    // tokenizer.json の added_tokens に基づく実際のトークン名を使用
    final clsToken = _vocab.keys.firstWhere(
      (k) => k == '<s>' || k == '[CLS]',
      orElse: () => '<s>',
    );
    final sepToken = _vocab.keys.firstWhere(
      (k) => k == '</s>' || k == '[SEP]',
      orElse: () => '</s>',
    );
    final unkToken = _vocab.keys.firstWhere(
      (k) => k == '<unk>' || k == '[UNK]',
      orElse: () => '<unk>',
    );

    // [CLS] トークンを追加
    tokens.add(clsToken);

    // 単語分割（簡易：スペース区切り + 基本的な punctuation 処理）
    // 実際の WordPiece 実装は複雑なため、ここでは簡易版とする
    final words = normalized.split(RegExp(r'\s+'));
    for (final word in words) {
      if (word.isEmpty) continue;
      // 単語をサブワードに分割（簡易版：語彙にあればそのまま、なければ文字ごとに分割）
      if (_vocab.containsKey(word)) {
        tokens.add(word);
      } else {
        // 簡易サブワード分割：最長一致で語彙から検索
        final subwords = _wordPieceTokenize(word);
        tokens.addAll(subwords);
      }
    }

    // [SEP] トークンを追加
    tokens.add(sepToken);

    // トークンを ID に変換
    return tokens.map((t) => _vocab[t] ?? _vocab[unkToken] ?? 0).toList();
  }

  /// 簡易 WordPiece トークナイズ（最長一致）
  List<String> _wordPieceTokenize(String word) {
    final result = <String>[];
    int start = 0;
    while (start < word.length) {
      int end = word.length;
      String? match;
      while (end > start) {
        final sub = word.substring(start, end);
        final candidate = (start == 0) ? sub : '##$sub';
        if (_vocab.containsKey(candidate)) {
          match = candidate;
          break;
        }
        end--;
      }
      if (match != null) {
        result.add(match);
        start = end;
      } else {
        // マッチしない文字は UNK 扱い
        result.add(
          _vocab.keys.firstWhere(
            (k) => k == '<unk>' || k == '[UNK]',
            orElse: () => '<unk>',
          ),
        );
        start++;
      }
    }
    return result;
  }

  /// パディングまたは切り捨て
  List<int> _padOrTruncate(List<int> input, int length, int padValue) {
    if (input.length >= length) {
      return input.sublist(0, length);
    }
    return [...input, ...List<int>.filled(length - input.length, padValue)];
  }

  /// L2正規化（インプレース）
  void _l2Normalize(Float32List vector) {
    double norm = 0.0;
    for (final v in vector) {
      norm += v * v;
    }
    norm = sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < vector.length; i++) {
        vector[i] /= norm;
      }
    }
  }

  /// リソース解放
  Future<void> dispose() async {
    await _session?.close(); // OrtSession の Native メモリを確実に解放
    _session = null;
    _isInitialized = false;
    _vocab.clear();
    if (!_initCompleter.isCompleted) {
      _initCompleter.completeError(StateError('Disposed'));
    }
  }
}
