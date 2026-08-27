import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ruri_model_manager.dart';

/// 高精度モード用 Ruri v3 Reranker（Cross-Encoder, INT8）の
/// ダウンロード・ハッシュ検証・保存・セッション作成を管理するシングルトン。
///
/// [RuriModelManager] と同様のパターン（DL・検証・パス管理・進捗通知）を採用。
/// モデル未DL時はクラッシュせず [isModelReady] = false を返す。
///
/// トークナイザは Ruri embedding モデルと同一語彙のため、
/// [RuriModelManager] の tokenizer ファイルを再利用する（別DL不要）。
class RerankModelManager {
  // ---- モデル仕様（定数化）----
  static const rerankerModelId = 'ruri-v3-reranker-310m-int8';
  static const rerankerModelVersion = 1;
  static const int bosTokenId = 1;
  static const int eosTokenId = 2;
  static const int padTokenId = 3;
  static const int modelMaxSeq = 512;

  // ---- 期待サイズ（検証用、コミュニティビルドは SHA が変動しうるため SHA は使わない）----
  // サイズは実機/モデルで要確認（F 課題）。ここでは INT8 の想定範囲で
  // 100MB〜500MB の範囲検証のみを行い、破損・別ファイル混入を弾く。
  static const int _minModelSize = 100 * 1024 * 1024; // 100MiB
  static const int _maxModelSize = 500 * 1024 * 1024; // 500MiB
  // SHA256 検証はコミュニティビルド可変性のため行わない（ロード可否で担保）。

  // ---- 配信元 URL（実在確認済み: szdr/ruri-v3-reranker-310m-onnx_int8_arm64）----
  // ※ ファイル名は model.onnx（公式サンプルの hf_hub_download(repo_id,"model.onnx") と一致）。
  static const String _modelUrl =
      'https://huggingface.co/szdr/ruri-v3-reranker-310m-onnx_int8_arm64/resolve/main/model.onnx';

  // ---- ローカルファイル名 ----
  static const String _modelFileName = 'ruri_v3_reranker_310m_int8.onnx';
  static const String _infoFileName = 'rerank_model_info.json';

  /// UI 表示用のサイズ説明
  static const String modelSizeDescription = '約315MiB (INT8)';

  static final RerankModelManager _instance = RerankModelManager._internal();
  factory RerankModelManager() => _instance;
  RerankModelManager._internal();

  Directory? _dirCache;

  Future<Directory> get _supportDir async {
    _dirCache ??= await getApplicationSupportDirectory();
    return _dirCache!;
  }

  Future<File> get modelFile async =>
      File(p.join((await _supportDir).path, _modelFileName));
  Future<File> get _infoFile async =>
      File(p.join((await _supportDir).path, _infoFileName));

  /// モデルファイルが存在するかのみを判定する（軽量）。
  Future<bool> isModelPresent() async {
    final m = await modelFile;
    final info = await _infoFile;
    return await m.exists() && await info.exists();
  }

  /// 保存済みモデル情報が現在の仕様と一致するか。
  Future<bool> isModelReady() async {
    final m = await modelFile;
    final info = await _infoFile;
    if (!await m.exists() || !await info.exists()) return false;
    try {
      final data =
          jsonDecode(await info.readAsString()) as Map<String, dynamic>;
      if (data['modelId'] != rerankerModelId) return false;
      if (data['modelVersion'] != rerankerModelVersion) return false;
    } catch (_) {
      return false;
    }
    return true;
  }

  /// セッションを作成し、ONNX としてロード可能か検証して返す。
  /// ロードに失敗した場合は例外を投げる（呼び出し側で isAvailable=false に戻す）。
  Future<OrtSession> loadSession() async {
    final m = await modelFile;
    if (!await m.exists()) {
      throw StateError('Reranker モデルファイルが存在しません: ${m.path}');
    }
    final ort = OnnxRuntime();
    final session = await ort.createSession(m.path);
    // 入力名が期待通り（input_ids / attention_mask, int64）か軽く検証
    final inputs = session.inputNames;
    if (!inputs.contains('input_ids') || !inputs.contains('attention_mask')) {
      await session.close();
      throw StateError('Reranker モデルの入力形式が想定と異なります: $inputs');
    }
    return session;
  }

  /// Ruri embedding と同一語彙のトークナイザパスを取得する。
  Future<String> get tokenizerPath async =>
      await RuriModelManager().tokenizerPath;

  /// トークナイザ（embedding 側の tokenizer.model）が利用可能か。
  /// reranker は query をトークナイズするため必須。
  /// K3 方針: embedding 未導入時は reranker 単体 DL をブロックし案内する。
  Future<bool> isTokenizerAvailable() async {
    final m = RuriModelManager();
    try {
      final path = await m.tokenizerPath;
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// モデルをダウンロードし、検証（サイズ範囲 + ONNX ロード）後に保存する。
  /// 検証失敗時はファイルを削除し、例外を投げる（破損ファイルを残さない）。
  Future<void> download({
    ModelDownloadProgress? onProgress,
    ValueNotifier<bool>? cancel,
  }) async {
    if (!await isTokenizerAvailable()) {
      throw StateError(
        'Reranker にはトークナイザ（embedding モデル）が必要です。'
        '先に「意味検索モデル」を導入してください。',
      );
    }
    try {
      await _downloadFile(
        _modelUrl,
        _modelFileName,
        label: 'Rerankerモデル',
        onProgress: onProgress,
        cancel: cancel,
      );
      // 検証: サイズ範囲 + ONNX ロード可否
      final file = await modelFile;
      final size = await file.length();
      if (size < _minModelSize || size > _maxModelSize) {
        await file.delete();
        throw StateError(
          'ダウンロードした Reranker モデルのサイズが想定範囲外です'
          '（${_formatSize(size)}）。破損または正しくないファイルの可能性があります。',
        );
      }
      // ONNX として実際にロードできるか検証
      final ort = OnnxRuntime();
      final session = await ort.createSession(file.path);
      await session.close();
      await _writeInfo();
    } catch (e) {
      // 失敗時は破損ファイルを確実に削除して「導入済みだが動かない」を防ぐ
      final f = await modelFile;
      if (await f.exists()) await f.delete();
      final i = await _infoFile;
      if (await i.exists()) await i.delete();
      rethrow;
    }
  }

  /// モデル・情報ファイルを削除（再ダウンロード用）。
  Future<void> deleteAll() async {
    for (final f in [await modelFile, await _infoFile]) {
      if (await f.exists()) await f.delete();
    }
    final part = File('${(await modelFile).path}.part');
    if (await part.exists()) await part.delete();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_verifyPrefsPrefix}model');
  }

  // ---------- 内部実装（RuriModelManager パターン踏襲）----------

  Future<void> _writeInfo() async {
    final info = await _infoFile;
    await info.writeAsString(
      jsonEncode(<String, dynamic>{
        'modelId': rerankerModelId,
        'modelVersion': rerankerModelVersion,
        'modelMaxSeq': modelMaxSeq,
      }),
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GiB';
    }
    return '${(bytes / (1024 * 1024)).round()}MiB';
  }

  Future<void> _downloadFile(
    String url,
    String fileName, {
    int expectedSize = 0,
    String expectedSha = '',
    required String label,
    ModelDownloadProgress? onProgress,
    ValueNotifier<bool>? cancel,
  }) async {
    final dir = await _supportDir;
    final target = File(p.join(dir.path, fileName));

    if (await target.exists()) {
      if (await _verifyFile(target, expectedSize, expectedSha)) {
        onProgress?.call(expectedSize, expectedSize, label);
        return;
      }
      await target.delete();
    }

    final free = await _freeSpaceBytes(dir.path);
    if (free > 0 &&
        expectedSize > 0 &&
        free < expectedSize + 50 * 1024 * 1024) {
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
            // 404 等でモデルが存在しない場合は明確な案内を出す
            throw StateError(
              'Rerankerモデルが見つかりませんでした'
              '（HTTP ${resp.statusCode}）。配信URLを確認してください: $url',
            );
          }
          final total = resp.contentLength ?? expectedSize;
          int received = 0;
          final sink = part.openWrite();
          try {
            await for (final chunk in resp.stream) {
              if (cancel?.value == true) {
                await sink.close();
                await part.delete();
                throw const _RerankDownloadCancelled();
              }
              sink.add(chunk);
              received += chunk.length;
              onProgress?.call(received, total, label);
            }
          } finally {
            await sink.close();
          }

          if (expectedSize > 0) {
            final actualSize = await part.length();
            if (actualSize != expectedSize) {
              throw StateError(
                'ダウンロードサイズ不一致 ($actualSize != $expectedSize) for $fileName',
              );
            }
          }
          if (expectedSha.isNotEmpty) {
            final sha = (await sha256.bind(part.openRead()).first).toString();
            if (sha != expectedSha) {
              throw StateError('SHA-256 不一致（破損または改ざん）for $fileName');
            }
          }
          await part.rename(target.path);
          return;
        } finally {
          client.close();
        }
      } on _RerankDownloadCancelled {
        rethrow;
      } catch (e) {
        if (await part.exists()) await part.delete();
        if (attempt == maxRetries) rethrow;
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  Future<bool> _verifyFile(File f, int expectedSize, String expectedSha) async {
    if (!await f.exists()) return false;
    if (expectedSize > 0 && await f.length() != expectedSize) return false;
    if (expectedSha.isNotEmpty) {
      final sha = (await sha256.bind(f.openRead()).first).toString();
      return sha == expectedSha;
    }
    return true;
  }

  static const String _verifyPrefsPrefix = 'rerank_verified_';

  /// df -k で対象パスの空き容量(byte)を取得。取得不可時は 0 を返す。
  Future<int> _freeSpaceBytes(String path) async {
    try {
      final result = await Process.run('df', ['-k', path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().trim().split('\n');
        if (lines.length >= 2) {
          final cols = lines.last.trim().split(RegExp(r'\s+'));
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
class _RerankDownloadCancelled implements Exception {
  const _RerankDownloadCancelled();
}
