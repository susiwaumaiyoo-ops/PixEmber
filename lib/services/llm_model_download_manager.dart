// LLM モデルダウンロードマネージャ（純 Dart 実装）。
//
// llamadart の DefaultModelDownloadManager 置換として Phase A で追加。
// llamadart 時代の公開型シグネチャ（ModelSource / ModelCacheEntry /
// ModelDownloadProgress / ModelLoadOptions / ModelDownloadCancelToken /
// ModelDownloadManager / DefaultModelDownloadManager）を模倣しているため、
// llm_model_download_service.dart とテストの fake は import 先の変更だけで
// そのまま動作する。
//
// 仕様:
// - 出典: HuggingFace の pin revision（https://huggingface.co/{repo}/resolve/{rev}/{file}）。
// - 再開: {target}.part へ Range 指定追記（既存 .part サイズ分をスキップ）。
// - 検証: SHA-256（options.sha256 指定時。不一致は .part を削除して失敗）。
// - キャッシュレイアウト: {cacheDirectory}/{safeStem}-{cacheKey[:12]}/{fileName}
//   （llamadart 時代の保存形式と互換。既存キャッシュを再利用できる）。
// - cancelToken（ModelDownloadCancelToken）による協力型キャンセル。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// モデルのソース（リポジトリ + リビジョン + ファイル）。
class ModelSource {
  /// HuggingFace リポジトリのファイルを指すコンストラクタ。
  const ModelSource.huggingFace({
    required this.repoId,
    required this.filePath,
    required this.revision,
  });

  final String repoId;
  final String filePath;
  final String revision;

  /// ファイル名（ダウンロード後の保存名）。
  String get fileName => p.basename(filePath);

  /// 正規化された一意キー（キャッシュ index の論理キー）。
  String get canonicalKey => 'hf://$repoId@$revision/$filePath';

  /// sha256(canonicalKey) の 16 進（キャッシュ判定用）。
  String get cacheKey => sha256.convert(utf8.encode(canonicalKey)).toString();

  /// 実ダウンロード URL。
  String get downloadUrl =>
      'https://huggingface.co/$repoId/resolve/$revision/$filePath';

  @override
  String toString() => canonicalKey;
}

/// キャッシュ済みモデルエントリ（ファイル実体のメタデータ）。
class ModelCacheEntry {
  const ModelCacheEntry({
    required this.sourceCanonicalKey,
    required this.cacheKey,
    required this.fileName,
    required this.filePath,
    required this.createdAt,
    required this.updatedAt,
    required this.bytes,
    this.sha256,
  });

  final String sourceCanonicalKey;
  final String cacheKey;
  final String fileName;
  final String filePath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int bytes;
  final String? sha256;
}

/// ダウンロード進捗。totalBytes 不明時は fraction=null。
class ModelDownloadProgress {
  const ModelDownloadProgress({required this.receivedBytes, this.totalBytes});

  final int receivedBytes;
  final int? totalBytes;

  /// 0.0-1.0（全体サイズ不明なら null）。
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final f = receivedBytes / total;
    return f < 0 ? 0 : (f > 1 ? 1 : f);
  }
}

/// ダウンロード時の追加オプション。
class ModelLoadOptions {
  const ModelLoadOptions({
    this.cacheDirectory,
    this.sha256,
    this.resume = true,
    this.cancelToken,
  });

  /// 既定オプション（キャッシュディレクトリ未指定時はシステム一時領域）。
  static const ModelLoadOptions defaults = ModelLoadOptions();

  /// 保存先ルート（null の場合はシステム cacheDirectory 相当）。
  final String? cacheDirectory;

  /// 期待 SHA-256（指定時はダウンロード後に検証）。
  final String? sha256;

  /// .part からの再開を試みるか。
  final bool resume;

  /// 協力型キャンセルトークン。
  final ModelDownloadCancelToken? cancelToken;
}

/// 協力型ダウンロードキャンセルトークン。
class ModelDownloadCancelToken {
  bool _cancelled = false;

  /// キャンセル済みか。
  bool get isCancelled => _cancelled;

  /// キャンセルを要求する。
  void cancel() {
    _cancelled = true;
  }
}

/// モデルダウンロードマネージャの抽象（テストの fake が実装する）。
abstract class ModelDownloadManager {
  /// ソースに対応するモデルを確保（キャッシュ命中なら再利用）。
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    void Function(ModelDownloadProgress)? onProgress,
  });

  /// cacheKey に対応するキャッシュ済みエントリ（なければ null）。
  Future<ModelCacheEntry?> get(String cacheKey, {String? cacheDirectory});

  /// キャッシュ済みエントリ一覧。
  Future<List<ModelCacheEntry>> list({String? cacheDirectory});

  /// cacheKey に対応するキャッシュを削除。
  Future<void> remove(String cacheKey, {String? cacheDirectory});

  /// キャッシュを全て削除。
  Future<void> clear({String? cacheDirectory});

  /// 期限・容量超過のキャッシュを削除し、削除済み一覧を返す。
  Future<List<ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  });
}

/// 純 Dart 実装のデフォルトマネージャ。
class DefaultModelDownloadManager implements ModelDownloadManager {
  DefaultModelDownloadManager({this.baseUri});

  /// ダウンロード元ベース URL（テストで差し替え可。既定: huggingface.co）。
  final Uri? baseUri;

  /// 進捗報告の間隔バイト数。
  static const int _progressEveryBytes = 512 * 1024;

  String _root(String? cacheDirectory) =>
      cacheDirectory ?? Directory.systemTemp.path;

  Uri _urlFor(ModelSource source) {
    final base = baseUri ?? Uri.https('huggingface.co', '');
    return base.resolve(
      '${source.repoId}/resolve/${source.revision}/${source.filePath}',
    );
  }

  Directory _cacheDirFor(String root, ModelSource source) {
    final stem = p.basenameWithoutExtension(source.fileName);
    final safeStem = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return Directory(
      p.join(root, '$safeStem-${source.cacheKey.substring(0, 12)}'),
    );
  }

  ModelCacheEntry _entryFrom(
    File file, {
    required String cacheKey,
    required String canonicalKey,
    String? sha256,
  }) {
    final stat = file.statSync();
    return ModelCacheEntry(
      sourceCanonicalKey: canonicalKey,
      cacheKey: cacheKey,
      fileName: p.basename(file.path),
      filePath: file.path,
      createdAt: stat.changed,
      updatedAt: stat.modified,
      bytes: stat.size,
      sha256: sha256,
    );
  }

  @override
  Future<ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async {
    final dir = Directory(_root(cacheDirectory));
    if (!dir.existsSync()) return null;
    final suffix = '-${cacheKey.substring(0, 12)}';
    for (final e in dir.listSync()) {
      if (e is! Directory) continue;
      if (!p.basename(e.path).endsWith(suffix)) continue;
      for (final f in e.listSync()) {
        if (f is! File || f.path.endsWith('.part')) continue;
        return _entryFrom(
          f,
          cacheKey: cacheKey,
          canonicalKey: '',
          sha256: null,
        );
      }
    }
    return null;
  }

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    void Function(ModelDownloadProgress)? onProgress,
  }) async {
    final token = options.cancelToken;
    void ensureNotCancelled() {
      if (token?.isCancelled ?? false) {
        throw StateError('cancelled by user');
      }
    }

    ensureNotCancelled();
    final dir = _cacheDirFor(_root(options.cacheDirectory), source);
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, source.fileName));

    // キャッシュ命中（ファイル既存 + SHA 一致ならそのまま返す）。
    if (target.existsSync()) {
      if (options.sha256 == null ||
          await _verifySha(target.path, options.sha256!, token)) {
        return _entryFrom(
          target,
          cacheKey: source.cacheKey,
          canonicalKey: source.canonicalKey,
          sha256: options.sha256,
        );
      }
      // SHA 不一致（破損キャッシュ）→ 削除して再取得。
      await target.delete();
    }

    final part = File('${target.path}.part');
    var received = options.resume && part.existsSync()
        ? await part.length()
        : 0;
    if (!options.resume && part.existsSync()) {
      await part.delete();
      received = 0;
    }

    final url = _urlFor(source);
    final client = HttpClient();
    IOSink? sink;
    try {
      final request = await client.getUrl(url);
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      }
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${response.statusCode} at $url', uri: url);
      }
      // Range 指定が無視された（200 が返った）場合は最初から書き直す。
      if (received > 0 && response.statusCode == HttpStatus.ok) {
        await part.delete();
        received = 0;
      }
      final contentLength = response.contentLength;
      final int? total = contentLength > 0 ? contentLength + received : null;

      final hash = options.sha256 != null ? _IncrementalSha256() : null;
      if (hash != null && received > 0) {
        // 再開時は既存 .part 全体を再ハッシュ（正確性優先）。
        await for (final bytes in part.openRead(0, received)) {
          ensureNotCancelled();
          hash.add(bytes);
        }
      }

      final out = part.openWrite(mode: FileMode.append);
      sink = out;
      var sinceReport = 0;
      await for (final bytes in response) {
        if (token?.isCancelled ?? false) {
          // .part は保持（resume 対応）。
          await out.flush();
          await out.close();
          sink = null;
          throw StateError('cancelled by user');
        }
        received += bytes.length;
        hash?.add(bytes);
        out.add(bytes);
        sinceReport += bytes.length;
        if (sinceReport >= _progressEveryBytes) {
          sinceReport = 0;
          onProgress?.call(
            ModelDownloadProgress(receivedBytes: received, totalBytes: total),
          );
        }
      }
      await out.flush();
      await out.close();
      sink = null;
      onProgress?.call(
        ModelDownloadProgress(
          receivedBytes: received,
          totalBytes: total ?? received,
        ),
      );

      if (hash != null) {
        final digest = hash.digestString();
        if (digest != options.sha256!.toLowerCase()) {
          await part.delete();
          throw StateError(
            'SHA-256 mismatch (expected ${options.sha256}, got $digest)',
          );
        }
      }
      await part.rename(target.path);
      return _entryFrom(
        target,
        cacheKey: source.cacheKey,
        canonicalKey: source.canonicalKey,
        sha256: options.sha256,
      );
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  Future<bool> _verifySha(
    String path,
    String expected,
    ModelDownloadCancelToken? token,
  ) async {
    final hash = _IncrementalSha256();
    await for (final bytes in File(path).openRead()) {
      if (token?.isCancelled ?? false) return false;
      hash.add(bytes);
    }
    return hash.digestString() == expected.toLowerCase();
  }

  @override
  Future<List<ModelCacheEntry>> list({String? cacheDirectory}) async {
    final dir = Directory(_root(cacheDirectory));
    if (!dir.existsSync()) return const [];
    final result = <ModelCacheEntry>[];
    for (final e in dir.listSync()) {
      if (e is! Directory) continue;
      final match = RegExp(
        r'^(.+)-([0-9a-fA-F]{12})$',
      ).firstMatch(p.basename(e.path));
      if (match == null) continue;
      for (final f in e.listSync()) {
        if (f is! File || f.path.endsWith('.part')) continue;
        result.add(_entryFrom(f, cacheKey: match.group(2)!, canonicalKey: ''));
      }
    }
    return result;
  }

  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) async {
    final dir = Directory(_root(cacheDirectory));
    if (!dir.existsSync()) return;
    final suffix = '-${cacheKey.substring(0, 12)}';
    for (final e in dir.listSync()) {
      if (e is! Directory) continue;
      if (!p.basename(e.path).endsWith(suffix)) continue;
      await e.delete(recursive: true);
      return;
    }
  }

  @override
  Future<void> clear({String? cacheDirectory}) async {
    final dir = Directory(_root(cacheDirectory));
    if (!dir.existsSync()) return;
    for (final e in dir.listSync()) {
      if (e is! Directory) continue;
      if (RegExp(r'-[0-9a-fA-F]{12}$').hasMatch(p.basename(e.path))) {
        await e.delete(recursive: true);
      }
    }
  }

  @override
  Future<List<ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  }) async {
    if (maxAge == null && maxBytes == null) return const [];
    final all = await list(cacheDirectory: cacheDirectory);
    all.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final removed = <ModelCacheEntry>[];
    var total = all.fold<int>(0, (sum, e) => sum + e.bytes);
    final cutoff = maxAge == null ? null : DateTime.now().subtract(maxAge);
    for (final e in all) {
      final expired =
          (cutoff != null && e.updatedAt.isBefore(cutoff)) ||
          (maxBytes != null && total > maxBytes);
      if (!expired) continue;
      await remove(e.cacheKey, cacheDirectory: cacheDirectory);
      removed.add(e);
      total -= e.bytes;
    }
    return removed;
  }
}

/// SHA-256 ダイジェスト受取先（chunked conversion 用 Sink）。
class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 増分 SHA-256 ヘルパ（crypto の startChunkedConversion のラッパ）。
class _IncrementalSha256 {
  final _DigestCollector _out = _DigestCollector();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_out);

  void add(List<int> bytes) => _input.add(bytes);

  String digestString() {
    _input.close();
    return _out.value.toString();
  }
}
