// GGUF モデルの「ピッカー取り込み」サービス（ローカルAI実験機能）。
//
// 背景（実機不具合の根本原因）:
// - Android の Scoped Storage では /storage/emulated/0/Download など
//   外部ストレージ上のパスを C++（llama.cpp）から直接 fopen すると
//   FUSE 仮想化の影響で内容を読めず、「Model file does not appear to be
//   GGUF」エラーになる。このため SAF（file_picker）で選択したファイルを
//   必ず Dart 側でアプリ内部ディレクトリ（models/llm/）へ実コピーし、
//   以後は内部パスのみをエンジンに渡す。
// - Android で FileType.custom + allowedExtensions: ['gguf'] を指定すると、
//   GGUF が標準 MIME タイプとして認識されない端末で file_picker 側の
//   MIME 変換に失敗し、ピッカー起動前に PlatformException
//   （Unsupported filter）が送出されてファイル選択画面自体が開けなかった。
//   対策として全 OS で FileType.any（allowedExtensions 非指定）で選択させ、
//   拡張子・GGUF マジックの検証は選択後にアプリ側（本サービス）で行う。
//
// 設計メモ:
// - 権限は不要（SAF の ACTION_OPEN_DOCUMENT を利用するため）。
// - withData は使用せず（500MB 超のファイルを全量メモリ読み込みしない）。
//   withReadStream: true のストリームで逐次コピーし、readStream が null
//   な場合は File(path) でフォールバックする。
// - 検証順序: 拡張子（大文字小文字無視で .gguf）→ 先頭 4 バイト "GGUF"
//   → 逐次コピー。拡張子だけ書き換えられたファイルは拒否。
// - readStream のマジック検証はコピーと同じパスで実施する
//   （シングルスクリプションストリームは二回読めない）。
// - 中断時にゴミを残さないよう `.part` に書き出し、完了後に rename（原子性）。
//   キャンセル/失敗時は .part を削除する。
// - 進捗コールバック（copied/total）は既定 4MB ごとに間引く。
// - 取り込み済み判定: 同名・同サイズなら再コピーせず既存ファイルを再利用。
// - PlatformException の内部メッセージは UI に出さず、用途別の定型文に
//   置き換える（mapPickerError を参照）。
// - テスト用にピッカー（pickFile / pickSourcePath）とコピー先ディレクトリを
//   注入可能。
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'local_llm_service.dart' show LlmModelPaths;

/// GGUF マジックナンバー（ASCII "GGUF"）。
const List<int> kGgufMagic = <int>[0x47, 0x47, 0x55, 0x46];

/// インポート失敗（ユーザーに表示可能な定型メッセージを保持）。
class LlmModelImportException implements Exception {
  const LlmModelImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// ユーザーによるコピー中断。
class LlmModelImportCancelledException implements Exception {
  const LlmModelImportCancelledException();

  @override
  String toString() => 'Model import cancelled.';
}

/// インポート結果。
class LlmModelImportResult {
  const LlmModelImportResult({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    this.quantization,
    this.npuCompatible = true,
  });

  /// アプリ内部にコピーされた GGUF の絶対パス。
  final String path;

  /// 元ファイル名（destPath の basename と一致）。
  final String fileName;

  /// ファイルサイズ（バイト）。
  final int sizeBytes;

  /// 検出した量子化名（例: 'Q4_0', 'Q4_K_M'）。GGUF メタデータまたはファイル名から。
  final String? quantization;

  /// NPU(Hexagon HTP) 対応か（C-2/C-3）。量子化名から判定。
  final bool npuCompatible;

  const LlmModelImportResult.withQuant({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.quantization,
    required this.npuCompatible,
  });
}

/// ピッカーから得られた選択ファイル（実装詳細をサービス内部へ隠す）。
///
/// - [readStream]: SAF/FilePicker が提供する逐次読み取りストリーム
///   （file_picker の withReadStream: true）。500MB 超でもメモリに
///   読み込まない。
/// - [path]: readStream が利用できない場合のフォールバック
///   （file_picker の PlatformFile.path。Android では選択ファイルの
///   キャッシュコピーのパスが返る）。
class PickedGgufFile {
  const PickedGgufFile({this.name, this.readStream, this.path, this.size = 0});

  final String? name;
  final Stream<List<int>>? readStream;
  final String? path;

  /// ファイルサイズ（0 = 不明）。進捗表示と再利用判定に使用。
  final int size;
}

/// SAF ピッカー → アプリ内部ストレージへの GGUF 取り込み。
class LlmModelImportService {
  /// [pickFile]: テスト注入用のピッカー代替（null = 通常の SAF ピッカー）。
  /// [pickSourcePath]: 後方互換のパス注入（pickFile より優先度が低い）。
  /// [destDirResolver]: テスト注入用のコピー先ディレクトリ解決。
  LlmModelImportService({
    this.pickFile,
    this.pickSourcePath,
    this.destDirResolver,
  });

  /// テスト注入用のピッカー代替（null を返すとユーザーキャンセル扱い）。
  final Future<PickedGgufFile?> Function()? pickFile;

  /// 後方互換のピッカー代替（パスのみ。readStream なしの File 読み取り）。
  final Future<String?> Function()? pickSourcePath;

  /// テスト注入用のコピー先ディレクトリ解決。
  final Future<Directory> Function()? destDirResolver;

  /// ピッカーを開き、選択された GGUF をアプリ内部へ取り込む。
  ///
  /// ピッカーがキャンセルされた場合は null を返す（エラー扱いしない）。
  Future<LlmModelImportResult?> importFromPicker({
    void Function(int copiedBytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final PickedGgufFile picked;
    if (pickFile != null) {
      picked = (await pickFile!()) ?? PickedGgufFile();
    } else if (pickSourcePath != null) {
      picked = PickedGgufFile(path: await pickSourcePath!());
    } else {
      picked = await _pickWithFilePicker();
    }
    if (picked.readStream == null &&
        (picked.path == null || picked.path!.isEmpty)) {
      // ピッカーがキャンセルされた（実ダイアログでも null が返る）。
      return null;
    }
    return importFile(picked, onProgress: onProgress, isCancelled: isCancelled);
  }

  /// 既定の SAF ピッカー。
  ///
  /// 全 OS で FileType.any（allowedExtensions は指定しない）で選択し、
  /// GGUF かどうかの検証はアプリ側で行う。理由: Android で
  /// FileType.custom + ['gguf'] は標準 MIME として認識されない端末で
  /// PlatformException(Unsupported filter) を送出し、ファイル選択画面
  /// 自体が開けない（実機で確認済み）。withData は使用しない。
  Future<PickedGgufFile> _pickWithFilePicker() async {
    try {
      return await _pick(FileType.any);
    } on PlatformException catch (e) {
      if (isCancelledError(e)) {
        // 一部のプラットフォームはユーザーキャンセルを PlatformException
        // として届ける（エラー扱いしない）。
        return PickedGgufFile();
      }
      throw mapPickerError(e);
    }
  }

  /// [fileType] でピッカーを開き PickedGgufFile を返す。
  ///
  /// キャンセル（null 結果）は空の PickedGgufFile（readStream/path なし）で返す。
  Future<PickedGgufFile> _pick(FileType fileType) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'GGUF モデルを選択',
      type: fileType,
      // allowedExtensions は一切指定しない。
      // 'gguf' を MIME へ変換できず Unsupported filter になる Android 端末を
      // 避けるため。GGUF かどうかの検証は選択後にアプリ側で行う。
      allowMultiple: false,
      withData: false,
      withReadStream: true,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return PickedGgufFile();
    final f = result.files.single;
    return PickedGgufFile(
      name: f.name,
      readStream: f.readStream,
      path: f.path,
      size: f.size,
    );
  }

  /// [picked] の GGUF を検証（拡張子・マジック）してコピー先へ取り込む。
  Future<LlmModelImportResult> importFile(
    PickedGgufFile picked, {
    void Function(int copiedBytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // 1. 拡張子（大文字小文字無視で .gguf）。
    final name = (picked.name != null && picked.name!.isNotEmpty)
        ? picked.name!
        : (picked.path != null ? p.basename(picked.path!) : '');
    if (!name.toLowerCase().endsWith('.gguf')) {
      throw const LlmModelImportException('GGUFモデルファイルを選択してください。');
    }

    final Stream<List<int>>? stream = picked.readStream;
    final String? path = picked.path;

    // 2. ソースの解決: readStream 優先、File(path) はフォールバック。
    // 3. GGUF マジック（先頭 4 バイト "GGUF"）。拡張子だけ書き換えられた
    //    別ファイルをここで拒否する。
    int? total;
    if (stream != null) {
      // マジックはコピーと同じパスで検証（ストリームは一回しか読めない）。
      total = picked.size > 0 ? picked.size : null;
    } else {
      if (path == null || path.isEmpty) {
        throw const LlmModelImportException('選択したファイルを読み取れませんでした。');
      }
      final src = File(path);
      if (!await src.exists()) {
        throw const LlmModelImportException('選択したファイルを読み取れませんでした。');
      }
      if (!await hasGgufMagic(src)) {
        throw const LlmModelImportException('有効なGGUFモデルではありません。');
      }
      total = await src.length();
    }

    // 4. アプリ内部ディレクトリ（models/llm/imported/）へ逐次コピー。
    //    アプリ内ダウンロード（M4）は models/llm/managed/ に置くため、
    //    ピッカー取り込みは imported サブディレクトリへ分離する。
    //    （既定ディレクトリ直下の旧ファイルも discover 継続して検出される）
    final dir = await (destDirResolver?.call() ?? LlmModelPaths.importedDir());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final destPath = p.join(dir.path, name);
    final dest = File(destPath);
    final part = File('$destPath.part');

    // 同名・同サイズなら取り込み済みとみなし、再コピーを回避する。
    // サイズ不明のストリームは常にコピーする。
    if (total != null && await dest.exists() && await dest.length() == total) {
      onProgress?.call(total, total);
      final quant = detectQuantization(name);
      return LlmModelImportResult.withQuant(
        path: dest.path,
        fileName: name,
        sizeBytes: total,
        quantization: quant,
        npuCompatible: npuCompatibleForQuant(quant),
      );
    }

    if (await part.exists()) {
      await part.delete();
    }
    try {
      if (stream != null) {
        await _copyStreamWithProgress(
          stream,
          part,
          total: total ?? 0,
          verifyGgufMagic: true,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      } else {
        await _copyWithProgress(
          File(path!).openRead(),
          part,
          total: total!,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }
    } on LlmModelImportCancelledException {
      await _deletePart(part);
      rethrow;
    } on LlmModelImportException {
      // マジック不一致等の定型メッセージはそのまま保持する。
      await _deletePart(part);
      rethrow;
    } catch (_) {
      await _deletePart(part);
      throw const LlmModelImportException('モデルの取り込みに失敗しました');
    }
    await part.rename(destPath);
    final size = await dest.length();
    onProgress?.call(size, size);
    // 量子化形式を GGUF file_type メタデータから検出（C-2）。
    // 読めなければファイル名判定にフォールバック。
    final metaQuant = await readGgufFileType(dest);
    final quant = metaQuant ?? detectQuantization(name);
    final npuOk = npuCompatibleForQuant(quant);
    return LlmModelImportResult.withQuant(
      path: dest.path,
      fileName: name,
      sizeBytes: size,
      quantization: quant,
      npuCompatible: npuOk,
    );
  }

  /// [sourcePath] の GGUF を検証してコピー先へ取り込む。
  ///
  /// ピッカーを経由しない直接取り込み（テスト・将来の共有受信連携向け）。
  Future<LlmModelImportResult> importFromPath(
    String sourcePath, {
    void Function(int copiedBytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    return importFile(
      PickedGgufFile(path: sourcePath),
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// file_picker が送出する Unsupported filter の PlatformException か。
  ///
  /// 実機: `PlatformException(FilePicker, Unsupported filter. Make sure that
  /// you are only using the extension without the dot...)`。
  static bool isUnsupportedFilterError(PlatformException e) {
    final code = e.code.toLowerCase();
    final message = (e.message ?? '').toLowerCase();
    return code.contains('unsupported') ||
        message.contains('unsupported filter');
  }

  /// ユーザーキャンセルを表す PlatformException か（エラー扱いしない）。
  static bool isCancelledError(PlatformException e) {
    final code = e.code.toLowerCase();
    return code == 'cancelled' || code == 'canceled';
  }

  /// ピッカー由来の PlatformException を用途別の定型メッセージへ変換する。
  ///
  /// 内部メッセージ（長い文字列等）は UI に出さない。
  static LlmModelImportException mapPickerError(PlatformException e) {
    if (isUnsupportedFilterError(e)) {
      return const LlmModelImportException('この端末では GGUF 指定のファイル選択に失敗しました。');
    }
    if (e.code == 'file_not_found') {
      return const LlmModelImportException('選択したファイルを読み取れませんでした。');
    }
    return const LlmModelImportException('ファイルの選択に失敗しました。');
  }

  static Future<void> _deletePart(File part) async {
    try {
      if (await part.exists()) {
        await part.delete();
      }
    } catch (_) {
      // クリーンアップ失敗は本エラーを隠蔽しない。
    }
  }

  /// ストリーム逐次コピー。
  ///
  /// ファイル全体をメモリへ読み込まない（チャンク毎に writeFrom）。
  /// [total] が 0（サイズ不明）の場合は進捗を不定で通知する。
  ///
  /// [verifyGgufMagic] が true の場合、先頭 4 バイトのマジックを検証してから
  /// 書き進める（シングルスクリプションストリームは二回読めないため
  /// 検証とコピーを同一パスで行う）。出力は入力をそのまま書き写す
  /// （マジックバイトも欠落しない）。
  Future<void> _copyStreamWithProgress(
    Stream<List<int>> src,
    File dest, {
    required int total,
    required bool verifyGgufMagic,
    required void Function(int copiedBytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final out = await dest.open(mode: FileMode.write);
    var copied = 0;
    var lastReported = 0;
    var magicChecked = false;
    final head = <int>[];
    const step = 1 << 22; // 4MB
    try {
      await for (final chunk in src) {
        if (isCancelled?.call() ?? false) {
          throw const LlmModelImportCancelledException();
        }
        if (verifyGgufMagic && !magicChecked) {
          final need = 4 - head.length;
          if (chunk.length < need) {
            // 本チャンクはファイルの一部 → 書き込みつつマジック検証へ蓄積。
            head.addAll(chunk);
            await out.writeFrom(chunk);
            copied += chunk.length;
            continue;
          }
          head.addAll(chunk.sublist(0, need));
          if (!_isGgufMagic(head)) {
            throw const LlmModelImportException('有効なGGUFモデルではありません。');
          }
          magicChecked = true;
        }
        await out.writeFrom(chunk);
        copied += chunk.length;
        if (copied - lastReported >= step) {
          lastReported = copied;
          onProgress?.call(copied, total);
        }
      }
    } finally {
      await out.close();
    }
    if (verifyGgufMagic && !magicChecked) {
      // ストリームが 4 バイト未満 → 有効な GGUF ではない。
      throw const LlmModelImportException('有効なGGUFモデルではありません。');
    }
    onProgress?.call(copied, copied);
  }

  /// [inStream] をチャンク逐次コピーし、[dest] へ書き込む（total 已知）。
  Future<void> _copyWithProgress(
    Stream<List<int>> inStream,
    File dest, {
    required int total,
    required void Function(int copiedBytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final out = await dest.open(mode: FileMode.write);
    var copied = 0;
    var lastReported = 0;
    const step = 1 << 22; // 4MB
    try {
      await for (final chunk in inStream) {
        if (isCancelled?.call() ?? false) {
          throw const LlmModelImportCancelledException();
        }
        await out.writeFrom(chunk);
        copied += chunk.length;
        if (copied - lastReported >= step || copied == total) {
          lastReported = copied;
          onProgress?.call(copied, total);
        }
      }
    } finally {
      await out.close();
    }
  }

  /// [file] の先頭 4 バイトが GGUF マジックかどうか。
  static Future<bool> hasGgufMagic(File file) async {
    RandomAccessFile raf;
    try {
      raf = await file.open();
    } catch (e) {
      debugPrint('GGUF マジック検証でファイルを開けませんでした: $e');
      return false;
    }
    try {
      final bytes = await raf.read(4);
      return _isGgufMagic(bytes);
    } finally {
      await raf.close();
    }
  }

  /// [stream] の先頭 4 バイトが GGUF マジックかどうか。
  ///
  /// 判定に必要な分だけストリームを消費する。消費後はストリームを再読めない
  /// ため、この後ストリームを再利用しないこと（取り込み経路はコピーと同じ
  /// パスで検証するため本メソッドは使わない）。
  static Future<bool> hasGgufMagicStream(Stream<List<int>> stream) async {
    try {
      final head = <int>[];
      await for (final chunk in stream) {
        if (head.length < 4) {
          final need = 4 - head.length;
          head.addAll(
            chunk.sublist(0, chunk.length < need ? chunk.length : need),
          );
        }
        if (head.length >= 4) return _isGgufMagic(head);
      }
      return false;
    } catch (e) {
      debugPrint('GGUF マジック検証でストリームを読み取れませんでした: $e');
      return false;
    }
  }

  static bool _isGgufMagic(List<int> bytes) {
    if (bytes.length < 4) return false;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != kGgufMagic[i]) return false;
    }
    return true;
  }

  /// ファイル名から量子化形式を検出する（C-2 のメタデータ読取失敗時フォールバック）。
  ///
  /// mradermacher/Huihui 系の命名（`...i1-Q4_0.gguf` / `...Q4_K_M.gguf`）や
  /// 一般的な `model-Q8_0.gguf` を想定。'Q0'_K_L' などのファイル名パターン
  /// （"Q4_K", "Q5_K", "Q6_K", "IQ"）を拾う。見つからなければ null。
  static String? detectQuantization(String fileName) {
    final up = fileName.toUpperCase();
    // IQ 系を優先（IQ1_xS 等、Q を含まない命名がある）。
    if (RegExp(r'IQ[0-9]').hasMatch(up)) {
      final m = RegExp(r'IQ[0-9][A-Z0-9_]*').firstMatch(up);
      return m?.group(0);
    }
    // Q<bit><type>_<variant>（Q4_0 / Q4_K_M / Q8_0 / Q2_K_XL 等）。
    final m = RegExp(r'Q[0-9]_[A-Z](?:_[A-Z])?').firstMatch(up);
    return m?.group(0);
  }

  /// 量子化名から NPU(HTP) 対応かを判定（'Q4_K', 'Q5_K', 'Q6_K', IQ 系は非対応）。
  static bool npuCompatibleForQuant(String? quantization) {
    if (quantization == null || quantization.isEmpty) return true;
    final q = quantization.toUpperCase();
    if (RegExp(r'_K[MSL]').hasMatch(q)) return false;
    if (q.contains('_K_')) return false;
    if (q.startsWith('IQ')) return false;
    return true;
  }

  /// GGUF ファイルの `general.file_type` メタデータ（量子化種別 enum）を読む（C-2）。
  ///
  /// 読めなければ null（呼び出し側でファイル名判定へフォールバック）。
  /// 先頭 256KB だけ読み、プロパティテーブルを走査する。
  static Future<String?> readGgufFileType(File file) async {
    RandomAccessFile raf;
    try {
      raf = await file.open();
    } catch (_) {
      return null;
    }
    try {
      final len = await raf.length();
      if (len < 24) return null;
      final cap = len < (1 << 18) ? len : (1 << 18);
      await raf.setPosition(0);
      final head = await raf.read(cap.toInt());
      return _parseGgufFileType(head);
    } catch (_) {
      return null;
    } finally {
      await raf.close();
    }
  }

  /// GGUF バイト列から `general.file_type`（u32 enum）を走査して量子化名へ変換。
  static String? _parseGgufFileType(List<int> bytes) {
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    var off = 0;
    if (off + 24 > bytes.length) return null;
    if (bytes[0] != 0x47 ||
        bytes[1] != 0x47 ||
        bytes[2] != 0x55 ||
        bytes[3] != 0x46) {
      return null;
    }
    off += 4; // magic
    off += 4; // version (u32)
    // n_tensors(u64), n_kv(u64)：Little Endian（GGUF v3 は LE 前提）。
    final nTensors = _rdU64(bd, off);
    off += 8;
    final nKv = _rdU64(bd, off);
    off += 8;
    // テンソリ情報テーブルをスキップ。
    for (var i = 0; i < nTensors; i++) {
      final nameLen = _rdU64(bd, off);
      off += 8;
      if (nameLen < 0 || off + nameLen > bytes.length) return null;
      off += nameLen.toInt(); // name
      if (off + 4 > bytes.length) return null;
      final nDims = bd.getUint32(off, Endian.little);
      off += 4;
      if (off + nDims * 8 > bytes.length) return null;
      off += nDims * 8; // dims (u64 × n)
      if (off + 4 + 8 > bytes.length) return null;
      off += 4; // type (u32)
      off += 8; // offset (u64)
    }
    // KV プロパティ。
    for (var i = 0; i < nKv; i++) {
      final keyLen = _rdU64(bd, off);
      off += 8;
      if (keyLen < 0 || off + keyLen > bytes.length) return null;
      final key = String.fromCharCodes(bytes.sublist(off, off + keyLen.toInt()));
      off += keyLen.toInt();
      if (off + 4 > bytes.length) return null;
      final type = bd.getUint32(off, Endian.little);
      off += 4;
      // 不要な型はスキップ、file_type(0, u32) のみ値を取る。
      if (key == 'general.file_type') {
        if (type != kGgufTypeU32 || off + 4 > bytes.length) return null;
        final ft = bd.getUint32(off, Endian.little);
        return _ggufFileTypeToQuant(ft);
      }
      final skip = _ggufValueSkip(type, bd, off, bytes.length);
      if (skip < 0) return null;
      off += skip;
    }
    return null;
  }

  static int _rdU64(ByteData bd, int off) =>
      bd.lengthInBytes >= off + 8
      ? bd.getUint64(off, Endian.little)
      : -1;

  /// GGUF 値のバイト長を返す。読取不能なら -1。
  static int _ggufValueSkip(int type, ByteData bd, int off, int maxLen) {
    switch (type) {
      case kGgufTypeU8:
      case kGgufTypeI8:
      case kGgufTypeBool:
        return off + 1 <= maxLen ? 1 : -1;
      case kGgufTypeU16:
      case kGgufTypeI16:
        return off + 2 <= maxLen ? 2 : -1;
      case kGgufTypeU32:
      case kGgufTypeI32:
      case kGgufTypeF32:
        return off + 4 <= maxLen ? 4 : -1;
      case kGgufTypeU64:
      case kGgufTypeI64:
      case kGgufTypeF64:
        return off + 8 <= maxLen ? 8 : -1;
      case kGgufTypeStr: {
        final ln = _rdU64(bd, off);
        if (ln < 0) return -1;
        final need = 8 + ln.toInt();
        return off + need <= maxLen ? need : -1;
      }
      case kGgufTypeArr: {
        if (off + 12 > maxLen) return -1;
        final elemType = bd.getUint32(off, Endian.little);
        final cnt = _rdU64(bd, off + 4);
        if (cnt < 0) return -1;
        var p = 12;
        for (var k = 0; k < cnt; k++) {
          final s = _ggufValueSkip(elemType, bd, off + p, maxLen);
          if (s < 0) return -1;
          p += s;
        }
        return p;
      }
      default:
        return -1;
    }
  }

  /// GGUF file_type enum → 量子化名。
  static String? _ggufFileTypeToQuant(int ft) {
    switch (ft) {
      case 0:
        return 'F32';
      case 1:
        return 'F16';
      case 2:
        return 'Q4_0';
      case 3:
        return 'Q4_1';
      case 7:
        return 'Q8_0';
      case 8:
        return 'Q5_0';
      case 9:
        return 'Q5_1';
      case 10:
        return 'Q2_K';
      case 11:
        return 'Q3_K_S';
      case 12:
        return 'Q3_K_M';
      case 13:
        return 'Q3_K_L';
      case 14:
        return 'Q4_K_S';
      case 15:
        return 'Q4_K_M';
      case 16:
        return 'Q5_K_S';
      case 17:
        return 'Q5_K_M';
      case 18:
        return 'Q6_K';
      case 19:
        return 'IQ2_XXS';
      case 20:
        return 'IQ2_XS';
      case 21:
        return 'Q2_K_S';
      case 22:
        return 'IQ3_XS';
      case 23:
        return 'IQ3_XXS';
      case 24:
        return 'IQ1_S';
      case 25:
        return 'IQ4_NL';
      case 26:
        return 'IQ3_S';
      case 27:
        return 'IQ3_M';
      case 28:
        return 'IQ2_S';
      case 29:
        return 'IQ2_M';
      case 30:
        return 'IQ4_XS';
      case 31:
        return 'IQ1_M';
      case 32:
        return 'BF16';
      default:
        return null;
    }
  }
}

// GGUF value type enum（llama.cpp gguf.h 準拠）。
const int kGgufTypeU8 = 0;
const int kGgufTypeI8 = 1;
const int kGgufTypeU16 = 2;
const int kGgufTypeI16 = 3;
const int kGgufTypeU32 = 4;
const int kGgufTypeI32 = 5;
const int kGgufTypeF32 = 6;
const int kGgufTypeBool = 7;
const int kGgufTypeStr = 8;
const int kGgufTypeArr = 9;
const int kGgufTypeU64 = 10;
const int kGgufTypeI64 = 11;
const int kGgufTypeF64 = 12;
