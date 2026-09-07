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
  });

  /// アプリ内部にコピーされた GGUF の絶対パス。
  final String path;

  /// 元ファイル名（destPath の basename と一致）。
  final String fileName;

  /// ファイルサイズ（バイト）。
  final int sizeBytes;
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
      return LlmModelImportResult(
        path: dest.path,
        fileName: name,
        sizeBytes: total,
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
    return LlmModelImportResult(
      path: dest.path,
      fileName: name,
      sizeBytes: size,
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
}
