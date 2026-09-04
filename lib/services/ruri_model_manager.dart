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

/// Ruri v3 embedding モデル1件の仕様（ONNX INT8 変換版のうち、実在確認済みのもののみ登録）。
///
/// 注意:
/// - cl-nagoya 公式リポジトリ（ruri-v3-30m/70m/130m/310m）は safetensors のみで
///   ONNX を提供していない。そのため ONNX ビルドは sirasagi62 氏のコミュニティ変換版
///   （base_model: cl-nagoya/ruri-v3-xxx）を使用する。
/// - すべての URL / ファイル名 / サイズは Hugging Face API で実在確認済み
///   （sirasagi62/ruri-v3-xxx-ONNX の onnx/model_int8.onnx）。
/// - 各サイズの埋め込み次元（hidden_size）は異なるため、DB のベクトル互換性に直結する:
///   30m=256, 70m=384, 130m=512, 310m=768。
/// - トークナイザ（tokenizer.model）は全サイズで同一（sha256 一致）のため 1 ファイルを共用する。
///   Reranker も同一語彙を共有するため、サイズ切り替え時も再ダウンロード不要。
class RuriModelSpec {
  final String id; // 保存キー（novel_embeddings.model_id 列に格納）
  final String displayName; // UI 表示名
  final String hfRepo; // Hugging Face リポジトリ
  final String onnxPath; // リポジトリ内 ONNX パス
  final int dimension; // 埋め込み次元（hidden_size）
  final int modelSizeBytes; // model_int8.onnx の正確なバイト数
  final String modelSha256; // model_int8.onnx の SHA-256（LFS oid）
  final String sizeLabel; // UI 用サイズ説明
  final String notes; // UI 用補足（精度/速度）

  const RuriModelSpec({
    required this.id,
    required this.displayName,
    required this.hfRepo,
    required this.onnxPath,
    required this.dimension,
    required this.modelSizeBytes,
    required this.modelSha256,
    required this.sizeLabel,
    required this.notes,
  });

  String get modelUrl =>
      'https://huggingface.co/$hfRepo/resolve/main/$onnxPath';

  /// トークナイザは全サイズで同一（cl-nagoya/ruri-v3-130m の tokenizer.model）。
  static const String tokenizerRepo = 'cl-nagoya/ruri-v3-130m';
  static const String tokenizerOnnxPath = 'tokenizer.model';
  static const String tokenizerUrl =
      'https://huggingface.co/$tokenizerRepo/resolve/main/$tokenizerOnnxPath';
  static const int tokenizerSizeBytes = 1831879;
  static const String tokenizerSha256 =
      '008293028e1a9d9a1038d9b63d989a2319797dfeaa03f171093a57b33a3a8277';

  /// 共通プレフィックス（すべての Ruri v3 サイズで同一）
  static const int prefixSchemeVersion = 1;
  static const int modelVersion = 1;
  static const String queryPrefix = '検索クエリ: ';
  static const String documentPrefix = '検索文書: ';

  /// 選択可能なモデル一覧（実在確認済みのみ登録）。
  static const List<RuriModelSpec> all = <RuriModelSpec>[
    RuriModelSpec(
      id: 'ruri-v3-30m-int8',
      displayName: 'Ruri v3 30m（軽量・高速）',
      hfRepo: 'sirasagi62/ruri-v3-30m-ONNX',
      onnxPath: 'onnx/model_int8.onnx',
      dimension: 256,
      modelSizeBytes: 37142404,
      modelSha256:
          '3d374a6245afef3c1710f942b25aad6b341504ba13fc82a85a844eb37b33120d',
      sizeLabel: '約35MiB',
      notes: '精度は控えめ・低メモリ/低スペック向け',
    ),
    RuriModelSpec(
      id: 'ruri-v3-70m-int8',
      displayName: 'Ruri v3 70m（バランス）',
      hfRepo: 'sirasagi62/ruri-v3-70m-ONNX',
      onnxPath: 'onnx/model_int8.onnx',
      dimension: 384,
      modelSizeBytes: 70684662,
      modelSha256:
          'c0d9885f7cdd014518b25404b75b67b2072d93c49d0cc5509263b5e8a1994dfa',
      sizeLabel: '約67MiB',
      notes: '精度と速度のバランス型',
    ),
    RuriModelSpec(
      id: 'ruri-v3-130m-int8',
      displayName: 'Ruri v3 130m（標準）',
      hfRepo: 'sirasagi62/ruri-v3-130m-ONNX',
      onnxPath: 'onnx/model_int8.onnx',
      dimension: 512,
      modelSizeBytes: 133302950,
      modelSha256:
          '36809816cdf6195b01fb6acf4526c0c1c90f60c9961a22b6ea9970d055541a43',
      sizeLabel: '約127MiB',
      notes: '精度重視の標準サイズ',
    ),
    RuriModelSpec(
      id: 'ruri-v3-310m-int8',
      displayName: 'Ruri v3 310m（高精度）',
      hfRepo: 'sirasagi62/ruri-v3-310m-ONNX',
      onnxPath: 'onnx/model_int8.onnx',
      dimension: 768,
      modelSizeBytes: 316591573,
      modelSha256:
          'b2b5af9b01ce0d5acdbb50d6d430fbe5266bb8d8c8f050ee1673d346e0a31380',
      sizeLabel: '約302MiB',
      notes: '最高精度・メモリ/ストレージ多め',
    ),
  ];

  /// 登録モデルが無い場合のフォールバック（デフォルト = 高精度 310m）。
  static const String defaultModelId = 'ruri-v3-310m-int8';

  static RuriModelSpec specById(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => all.last);

  static bool isValidId(String id) => all.any((s) => s.id == id);
}

/// Ruri v3 embedding モデルのダウンロード・ハッシュ検証・保存・セッション作成・
/// アクティブモデル切り替えを管理するシングルトン。
///
/// 複数サイズ（30m/70m/130m/310m）から選んでダウンロード・切り替えできる。
/// トークナイザは全サイズ共用の 1 ファイル。埋め込み次元はモデルごとに異なるため、
/// 検索時は「アクティブモデルで生成されたベクトル」のみを対象とする（互換フィルタ）。
class RuriModelManager {
  // ---- 静的エイリアス（既存呼び出し側互換: アクティブモデルの値を返す）----
  // アクティブIDはメモリキャッシュ（_cachedActiveId）で保持し、非同期読み書き時に更新。
  static String _cachedActiveId = RuriModelSpec.defaultModelId;

  /// アクティブユーザーモデルID（静的getter: 既存呼び出し側互換）。
  static String get embeddingModelId => _cachedActiveId;

  /// アクティブモデルの埋め込み次元（静的getter: 既存呼び出し側互換）。
  static int get embeddingDimension =>
      RuriModelSpec.specById(_cachedActiveId).dimension;

  static const int embeddingModelVersion = RuriModelSpec.modelVersion;
  static const int prefixSchemeVersion = RuriModelSpec.prefixSchemeVersion;
  static const String queryPrefix = RuriModelSpec.queryPrefix;
  static const String documentPrefix = RuriModelSpec.documentPrefix;

  /// アクティブモデルの仕様（同期取得・UI 表示用）。
  static RuriModelSpec get activeSpecSync =>
      RuriModelSpec.specById(_cachedActiveId);

  /// UI 用サイズ説明（アクティブモデルの sizeLabel）。
  static String get modelSizeDescription => activeSpecSync.sizeLabel;

  /// UI 用モデル表示名（アクティブモデルの displayName）。
  static String get modelDisplayName => activeSpecSync.displayName;

  static final RuriModelManager _instance = RuriModelManager._internal();
  factory RuriModelManager() => _instance;
  RuriModelManager._internal();

  Directory? _dirCache;

  Future<Directory> get _supportDir async {
    _dirCache ??= await getApplicationSupportDirectory();
    return _dirCache!;
  }

  // ---- アクティブモデル管理（SharedPreferences）----
  static const String _activeModelPrefsKey = 'ruri_active_model_id';

  /// 現在アクティブなモデルID（未設定時は default）。
  Future<String> getActiveModelId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_activeModelPrefsKey);
    if (id != null && RuriModelSpec.isValidId(id)) {
      _cachedActiveId = id;
      return id;
    }
    _cachedActiveId = RuriModelSpec.defaultModelId;
    return RuriModelSpec.defaultModelId;
  }

  /// アクティブモデルを設定する（後続の検索はこのモデルで生成されたベクトルのみ対象）。
  Future<void> setActiveModelId(String id) async {
    if (!RuriModelSpec.isValidId(id)) {
      throw ArgumentError('未登録のモデルID: $id');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeModelPrefsKey, id);
    _cachedActiveId = id;
  }

  /// アクティブモデルの仕様を取得。
  Future<RuriModelSpec> getActiveSpec() async =>
      RuriModelSpec.specById(await getActiveModelId());

  String _modelFileNameFor(String id) => 'ruri_${id.replaceAll('-', '_')}.onnx';
  String _infoFileNameFor(String id) =>
      'ruri_${id.replaceAll('-', '_')}_info.json';

  /// 指定モデルの .onnx ファイルパス。
  Future<File> modelFileFor(String id) async =>
      File(p.join((await _supportDir).path, _modelFileNameFor(id)));

  /// 指定モデルの info ファイルパス。
  Future<File> _infoFileFor(String id) async =>
      File(p.join((await _supportDir).path, _infoFileNameFor(id)));

  /// 共用トークナイザのファイルパス。
  Future<File> get tokenizerFile async =>
      File(p.join((await _supportDir).path, 'tokenizer.model'));

  /// 共用トークナイザのパス文字列。
  Future<String> get tokenizerPath async => (await tokenizerFile).path;

  // ---- 既存互換エイリアス（アクティブモデルを指す）----
  Future<File> get modelFile async => modelFileFor(await getActiveModelId());

  /// 指定モデルがダウンロード済み（ファイル存在のみ、軽量）か。
  Future<bool> isModelPresentFor(String id) async {
    final m = await modelFileFor(id);
    final t = await tokenizerFile;
    final info = await _infoFileFor(id);
    return await m.exists() && await t.exists() && await info.exists();
  }

  /// アクティブモデルがダウンロード済み（軽量）。
  Future<bool> isModelPresent() async =>
      isModelPresentFor(await getActiveModelId());

  /// 指定モデルの保存済み情報を読み取り。
  Future<Map<String, dynamic>?> readInfoFor(String id) async {
    final info = await _infoFileFor(id);
    if (!await info.exists()) return null;
    try {
      return jsonDecode(await info.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// アクティブモデルの保存済み情報を読み取り（既存互換）。
  Future<Map<String, dynamic>?> readInfo() async =>
      readInfoFor(await getActiveModelId());

  /// 指定モデルが準備完了（ハッシュ・仕様一致）か。
  Future<bool> isModelReadyFor(String id) async {
    final spec = RuriModelSpec.specById(id);
    final m = await modelFileFor(id);
    final t = await tokenizerFile;
    final info = await _infoFileFor(id);
    if (!await m.exists() || !await t.exists() || !await info.exists()) {
      return false;
    }
    try {
      final data =
          jsonDecode(await info.readAsString()) as Map<String, dynamic>;
      if (data['modelId'] != spec.id) return false;
      if (data['modelVersion'] != RuriModelSpec.modelVersion) return false;
      if (data['prefixSchemeVersion'] != RuriModelSpec.prefixSchemeVersion) {
        return false;
      }
    } catch (_) {
      return false;
    }
    final okModel = await _verifyFileCached(
      m,
      spec.modelSizeBytes,
      spec.modelSha256,
      'model_$id',
    );
    final okTok = await _verifyFileCached(
      t,
      RuriModelSpec.tokenizerSizeBytes,
      RuriModelSpec.tokenizerSha256,
      'tokenizer',
    );
    return okModel && okTok;
  }

  /// アクティブモデルが準備完了か。
  Future<bool> isModelReady() async =>
      isModelReadyFor(await getActiveModelId());

  /// アクティブモデルのセッションを作成して返す（呼び出し側が close すること）。
  Future<OrtSession> loadSession() async {
    final m = await modelFile;
    if (!await m.exists()) {
      throw StateError('モデルファイルが存在しません: ${m.path}');
    }
    final ort = OnnxRuntime();
    return ort.createSession(m.path);
  }

  /// 指定モデルをダウンロード（トークナイザは共用のため未存在時のみ DL）。
  Future<void> downloadModel(
    String id, {
    ModelDownloadProgress? onProgress,
    ValueNotifier<bool>? cancel,
  }) async {
    final spec = RuriModelSpec.specById(id);
    final tok = await tokenizerFile;
    if (!await tok.exists()) {
      await _downloadFile(
        RuriModelSpec.tokenizerUrl,
        'tokenizer.model',
        RuriModelSpec.tokenizerSizeBytes,
        RuriModelSpec.tokenizerSha256,
        label: 'トークナイザー',
        onProgress: onProgress,
        cancel: cancel,
      );
    }
    await _downloadFile(
      spec.modelUrl,
      _modelFileNameFor(id),
      spec.modelSizeBytes,
      spec.modelSha256,
      label: spec.displayName,
      onProgress: onProgress,
      cancel: cancel,
    );
    await _writeInfo(id);
  }

  /// アクティブモデルのダウンロード（既存呼び出し互換）。
  Future<void> download({
    ModelDownloadProgress? onProgress,
    ValueNotifier<bool>? cancel,
  }) async {
    await downloadModel(
      await getActiveModelId(),
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  /// 指定モデルのローカルファイル（モデル・info）を削除。
  /// トークナイザは共用のため削除しない（他モデル/reranker が使う）。
  Future<void> deleteModel(String id) async {
    for (final f in [await modelFileFor(id), await _infoFileFor(id)]) {
      if (await f.exists()) await f.delete();
    }
    final part = File('${(await modelFileFor(id)).path}.part');
    if (await part.exists()) await part.delete();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_verifyPrefsPrefix}model_$id');
  }

  /// アクティブモデル以外のすべてのダウンロード済みモデルを削除（ストレージ節約）。
  Future<void> deleteInactiveModels() async {
    final active = await getActiveModelId();
    for (final spec in RuriModelSpec.all) {
      if (spec.id != active) {
        await deleteModel(spec.id);
      }
    }
  }

  /// 指定モデルの info を書き込む。
  Future<void> _writeInfo(String id) async {
    final spec = RuriModelSpec.specById(id);
    final info = await _infoFileFor(id);
    await info.writeAsString(
      jsonEncode(<String, dynamic>{
        'modelId': spec.id,
        'modelVersion': RuriModelSpec.modelVersion,
        'embeddingDimension': spec.dimension,
        'prefixSchemeVersion': RuriModelSpec.prefixSchemeVersion,
        'modelSha256': spec.modelSha256,
        'tokenizerSha256': RuriModelSpec.tokenizerSha256,
      }),
    );
  }

  // ---------- 内部実装 ----------

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
        '空き容量が不足しています（必要約${(expectedSize / 1048576).round()}MiB, '
        '空き約${(free / 1048576).round()}MiB）',
      );
    }

    final part = File('${target.path}.part');
    // 既存の .part があれば HTTP Range で再開（サーバーが 206 を返さなければ最初から）。
    int resumeOffset = 0;
    if (await part.exists()) {
      final existing = await part.length();
      if (existing > 0 && expectedSize > 0 && existing < expectedSize) {
        resumeOffset = existing;
      } else if (existing >= expectedSize) {
        // 部分的に完成しているように見えるが未検証のため破棄
        await part.delete();
      } else {
        await part.delete();
      }
    }

    const maxRetries = 3;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final client = http.Client();
        try {
          final req = http.Request('GET', Uri.parse(url));
          if (resumeOffset > 0) {
            req.headers['Range'] = 'bytes=$resumeOffset-';
          }
          final resp = await client.send(req);
          // 206 = 再開成功。200 = サーバーが範囲を無視して全体を返すため最初からやり直し。
          if (resp.statusCode == 200) {
            if (resumeOffset > 0) {
              await part.delete();
              resumeOffset = 0;
            }
          } else if (resp.statusCode != 206) {
            throw StateError('HTTP ${resp.statusCode} for $url');
          }
          // Content-Length 確認（サーバーが提供する場合のみ）
          if (resp.contentLength != null && expectedSize > 0) {
            if (resp.contentLength != expectedSize - resumeOffset) {
              debugPrint(
                '[warn] Content-Length(${resp.contentLength}) != expected($expectedSize - $resumeOffset) for $fileName',
              );
            }
          }
          final total = expectedSize > 0
              ? expectedSize
              : (resp.contentLength ?? 0) + resumeOffset;
          int received = resumeOffset;
          // 再開時は既存バイトを保持するため append モードで開く
          final sink = part.openWrite(mode: FileMode.append);
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

          // サイズ確認（.part 全体が expectedSize と一致するか）
          final actualSize = await part.length();
          if (expectedSize > 0 && actualSize != expectedSize) {
            throw StateError(
              'ダウンロードサイズ不一致 ($actualSize != $expectedSize) for $fileName',
            );
          }
          // SHA-256 検証
          final sha = (await sha256.bind(part.openRead()).first).toString();
          if (sha != expectedSha) {
            throw StateError('ダウンロード破損/改ざん: SHA-256 不一致 for $fileName');
          }
          // 原子 rename
          await part.rename(target.path);
          return;
        } finally {
          client.close();
        }
      } on _DownloadCancelled {
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
