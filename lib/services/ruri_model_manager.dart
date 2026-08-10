import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ダウンロード進捗コールバック。received/total は bytes、label は識別名。
typedef ModelDownloadProgress =
    void Function(int receivedBytes, int totalBytes, String label);

/// Ruri v3-310m INT8 モデルのダウンロード・ハッシュ検証・保存・セッション作成を管理するシングルトン。
///
/// Milestone 1 で導入。EmbeddingService へは本接続せず、モデル資産の安全な
/// 取得・検証・ロードのみを責務とする。
class RuriModelManager {
  // ---- モデル仕様（定数化）----
  static const embeddingModelId = 'ruri-v3-310m-int8';
  static const embeddingModelVersion = 1;
  static const embeddingDimension = 768;
  static const prefixSchemeVersion = 1;
  static const queryPrefix = '検索クエリ: ';
  static const documentPrefix = '検索文書: ';

  // ---- 期待ハッシュ・サイズ（PC 側で事前計算済み）----
  static const String _expectedModelSha256 =
      'b2b5af9b01ce0d5acdbb50d6d430fbe5266bb8d8c8f050ee1673d346e0a31380';
  static const int _expectedModelSize = 316591573;
  static const String _expectedTokenizerSha256 =
      '008293028e1a9d9a1038d9b63d989a2319797dfeaa03f171093a57b33a3a8277';
  static const int _expectedTokenizerSize = 1831879;

  // ---- 配信元 URL ----
  static const String _modelUrl =
      'https://huggingface.co/sirasagi62/ruri-v3-310m-ONNX/resolve/main/onnx/model_int8.onnx';
  static const String _tokenizerUrl =
      'https://huggingface.co/cl-nagoya/ruri-v3-130m/resolve/main/tokenizer.model';

  // ---- ローカルファイル名 ----
  static const String _modelFileName = 'ruri_v3_310m_int8.onnx';
  static const String _tokenizerFileName = 'tokenizer.model';
  static const String _infoFileName = 'ruri_model_info.json';

  /// UI 表示用のサイズ説明
  static const String modelSizeDescription = '約302MiB';

  static final RuriModelManager _instance = RuriModelManager._internal();
  factory RuriModelManager() => _instance;
  RuriModelManager._internal();

  Directory? _dirCache;

  Future<Directory> get _supportDir async {
    _dirCache ??= await getApplicationSupportDirectory();
    return _dirCache!;
  }

  Future<File> get modelFile async =>
      File(p.join((await _supportDir).path, _modelFileName));
  Future<File> get tokenizerFile async =>
      File(p.join((await _supportDir).path, _tokenizerFileName));
  Future<File> get _infoFile async =>
      File(p.join((await _supportDir).path, _infoFileName));

  /// モデル＋トークナイザーをダウンロードし、検証後に保存する。
  /// ユーザー確認なしにモバイル通信で自動開始してはならない（呼び出し側で確認UIを経由すること）。
  Future<void> download({
    ModelDownloadProgress? onProgress,
    ValueNotifier<bool>? cancel,
  }) async {
    await _downloadFile(
      _modelUrl,
      _modelFileName,
      _expectedModelSize,
      _expectedModelSha256,
      label: 'AIモデル',
      onProgress: onProgress,
      cancel: cancel,
    );
    await _downloadFile(
      _tokenizerUrl,
      _tokenizerFileName,
      _expectedTokenizerSize,
      _expectedTokenizerSha256,
      label: 'トークナイザー',
      onProgress: onProgress,
      cancel: cancel,
    );
    await _writeInfo();
  }

  /// 保存済みモデル情報が現在の仕様と一致し、かつハッシュも一致するか。
  Future<bool> isModelReady() async {
    final m = await modelFile;
    final t = await tokenizerFile;
    final info = await _infoFile;
    if (!await m.exists() || !await t.exists() || !await info.exists()) {
      return false;
    }
    try {
      final data =
          jsonDecode(await info.readAsString()) as Map<String, dynamic>;
      if (data['modelId'] != embeddingModelId) return false;
      if (data['modelVersion'] != embeddingModelVersion) return false;
      if (data['prefixSchemeVersion'] != prefixSchemeVersion) return false;
    } catch (_) {
      return false;
    }
    final okModel = await _verifyFileCached(
      m,
      _expectedModelSize,
      _expectedModelSha256,
      'model',
    );
    final okTok = await _verifyFileCached(
      t,
      _expectedTokenizerSize,
      _expectedTokenizerSha256,
      'tokenizer',
    );
    return okModel && okTok;
  }

  /// セッションを作成して返す（呼び出し側が close すること）。
  Future<OrtSession> loadSession() async {
    final m = await modelFile;
    if (!await m.exists()) {
      throw StateError('モデルファイルが存在しません: ${m.path}');
    }
    final ort = OnnxRuntime();
    return ort.createSession(m.path);
  }

  /// トークナイザーのファイルパス（SentencePiece 初期化用）。
  Future<String> get tokenizerPath async => (await tokenizerFile).path;

  /// 保存済みモデル情報を読み取り（UI 表示・マイグレーション判定用）。
  Future<Map<String, dynamic>?> readInfo() async {
    final info = await _infoFile;
    if (!await info.exists()) return null;
    try {
      return jsonDecode(await info.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// モデル・トークナイザー・情報ファイルをすべて削除（再ダウンロード用）。
  Future<void> deleteAll() async {
    for (final f in [await modelFile, await tokenizerFile, await _infoFile]) {
      if (await f.exists()) await f.delete();
    }
    final part = File('${(await modelFile).path}.part');
    if (await part.exists()) await part.delete();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_verifyPrefsPrefix}model');
    await prefs.remove('${_verifyPrefsPrefix}tokenizer');
  }

  // ---------- 内部実装 ----------

  Future<void> _writeInfo() async {
    final info = await _infoFile;
    await info.writeAsString(
      jsonEncode(<String, dynamic>{
        'modelId': embeddingModelId,
        'modelVersion': embeddingModelVersion,
        'embeddingDimension': embeddingDimension,
        'prefixSchemeVersion': prefixSchemeVersion,
        'modelSha256': _expectedModelSha256,
        'tokenizerSha256': _expectedTokenizerSha256,
      }),
    );
  }

  Future<void> _downloadFile(
    String url,
    String fileName,
    int expectedSize,
    String expectedSha, {
    required String label,
    ModelDownloadProgress? onProgress,
    ValueNotifier<bool>? cancel,
  }) async {
    final dir = await _supportDir;
    final target = File(p.join(dir.path, fileName));

    // 既存ファイルは検証して合格ならスキップ
    if (await target.exists()) {
      if (await _verifyFile(target, expectedSize, expectedSha)) {
        onProgress?.call(expectedSize, expectedSize, label);
        return;
      }
      await target.delete();
    }

    // 空き容量確認（モデル + 余裕 50MiB）
    final free = await _freeSpaceBytes(dir.path);
    if (free > 0 && free < expectedSize + 50 * 1024 * 1024) {
      throw StateError(
        '空き容量が不足しています（必要約${(expectedSize / 1048576).round()}MiB, 空き約${(free / 1048576).round()}MiB）',
      );
    }

    final part = File('${target.path}.part');
    if (await part.exists()) await part.delete();

    const maxRetries = 3;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final client = http.Client();
        try {
          final req = http.Request('GET', Uri.parse(url));
          final resp = await client.send(req);
          if (resp.statusCode != 200) {
            throw StateError('HTTP ${resp.statusCode} for $url');
          }
          // Content-Length 確認（サーバーが提供する場合のみ）
          if (resp.contentLength != null && expectedSize > 0) {
            if (resp.contentLength != expectedSize) {
              debugPrint(
                '[warn] Content-Length(${resp.contentLength}) != expected($expectedSize) for $fileName',
              );
            }
          }
          final total = resp.contentLength ?? expectedSize;
          int received = 0;
          final sink = part.openWrite();
          try {
            await for (final chunk in resp.stream) {
              if (cancel?.value == true) {
                await sink.close();
                await part.delete();
                throw const _DownloadCancelled();
              }
              sink.add(chunk);
              received += chunk.length;
              onProgress?.call(received, total, label);
            }
          } finally {
            await sink.close();
          }

          // サイズ確認
          final actualSize = await part.length();
          if (expectedSize > 0 && actualSize != expectedSize) {
            throw StateError(
              'ダウンロードサイズ不一致 ($actualSize != $expectedSize) for $fileName',
            );
          }
          // SHA-256 検証
          final sha = (await sha256.bind(part.openRead()).first).toString();
          if (sha != expectedSha) {
            throw StateError('SHA-256 不一致（破損または改ざん）for $fileName');
          }
          // 原子 rename（部分ファイルをロードさせない）
          await part.rename(target.path);
          return;
        } finally {
          client.close();
        }
      } on _DownloadCancelled {
        rethrow;
      } catch (e) {
        // 部分ファイルを確実に破棄
        if (await part.exists()) await part.delete();
        if (attempt == maxRetries) rethrow;
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  Future<bool> _verifyFile(File f, int expectedSize, String expectedSha) async {
    if (!await f.exists()) return false;
    if (expectedSize > 0 && await f.length() != expectedSize) return false;
    final sha = (await sha256.bind(f.openRead()).first).toString();
    return sha == expectedSha;
  }

  static const String _verifyPrefsPrefix = 'ruri_verified_';

  /// SHA-256 のフル検証は初回（またはファイル変化時）のみ行い、
  /// 2 回目以降はサイズ・更新日時の照合だけで済ませる高速版。
  Future<bool> _verifyFileCached(
    File f,
    int expectedSize,
    String expectedSha,
    String key,
  ) async {
    if (!await f.exists()) return false;
    final stat = await f.stat();
    if (expectedSize > 0 && stat.size != expectedSize) return false;
    final signature =
        '$expectedSha|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    final prefsKey = '$_verifyPrefsPrefix$key';
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(prefsKey) == signature) {
      debugPrint('[RuriModelManager] $key: 検証キャッシュヒット (SHA-256 スキップ)');
      return true;
    }
    final sha = (await sha256.bind(f.openRead()).first).toString();
    if (sha != expectedSha) {
      await prefs.remove(prefsKey);
      return false;
    }
    await prefs.setString(prefsKey, signature);
    debugPrint('[RuriModelManager] $key: SHA-256 フル検証 OK (結果をキャッシュ)');
    return true;
  }

  /// df -k で対象パスの空き容量(byte)を取得。取得不可時は 0 を返す。
  Future<int> _freeSpaceBytes(String path) async {
    try {
      final result = await Process.run('df', ['-k', path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().trim().split('\n');
        if (lines.length >= 2) {
          final cols = lines.last.trim().split(RegExp(r'\s+'));
          // Filesystem 1K-blocks Used Available Use% Mounted
          if (cols.length >= 4) {
            final availKb = int.tryParse(cols[3]);
            if (availKb != null) return availKb * 1024;
          }
        }
      }
    } catch (_) {
      // 一部プラットフォームでは df が使えない
    }
    return 0;
  }
}

/// ダウンロード中のキャンセルを示す内部例外。
class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

/// 別 isolate で実行するスモーク推論（UI スレッドをブロックしないため）。
/// セッション作成から推論までを同一 isolate 内で完結させる。
/// modelPath を受け取り、[要素数, NaN/Infフラグ, 先頭5サンプル] を返す。
Future<Map<String, dynamic>> smokeRunInIsolate(
  Map<String, dynamic> args,
) async {
  final modelPath = args['modelPath'] as String;
  final token = args['token'] as RootIsolateToken?;
  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
  final ort = OnnxRuntime();
  final session = await ort.createSession(modelPath);
  try {
    final len = 32;
    final inputIds = Int64List(len);
    final attn = Int64List(len);
    for (int i = 0; i < len; i++) {
      inputIds[i] = 10 + (i % 100);
      attn[i] = 1;
    }
    final aT = await OrtValue.fromList(inputIds, [1, len]);
    final mT = await OrtValue.fromList(attn, [1, len]);
    final feeds = <String, OrtValue>{
      session.inputNames[0]: aT,
      session.inputNames[1]: mT,
    };
    final res = await session.run(feeds);
    final out = res[session.outputNames.first]!;
    final flat = await out.asFlattenedList();
    final hasNan = flat.any((e) => e is double && (e.isNaN || e.isInfinite));
    final sample = flat is List<double>
        ? flat.take(5).map((e) => e.toStringAsFixed(4)).toList()
        : <String>[];
    await aT.dispose();
    await mT.dispose();
    await out.dispose();
    return <String, dynamic>{
      'elementCount': flat.length,
      'hasNan': hasNan,
      'sample': sample,
      'inputNames': session.inputNames,
      'outputNames': session.outputNames,
    };
  } finally {
    await session.close();
  }
}
