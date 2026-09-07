// LlmModelImportService のテスト（GGUF ピッカー取り込み）。
//
// 対象:
// - ピッカーキャンセルは null（エラー扱いしない）
// - FilePicker 呼び出し: FileType.any・allowedExtensions 非指定・withData 非使用
//   （MethodChannel モックで検証し、実ダイアログは開かない）
// - .gguf を大文字小文字無視で受理 / .txt 等は拒否
// - 拡張子が .gguf でもマジック不一致なら拒否
// - GGUF マジックならコピー成功
// - readStream 経由で大きいファイルを逐次コピーできる
// - コピー中断時に .part が削除される
// - readStream が null で path のみなら File(path) でフォールバック
// - 出力ファイルは内部 models/llm（destDir）へ保存される
import 'dart:io';

// ignore: implementation_imports
import 'package:file_picker/src/file_picker_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pixiv_viewer/services/llm_model_import_service.dart';

/// file_picker の MethodChannel（file_picker-8.1.2 lib/src/file_picker_io.dart）。
///
/// コーデックを file_picker 内部 channel と同一（OS による条件分岐）にする。
/// 食い違いがあるとモックが本物のメッセージをデコードできず
/// FormatException: Message corrupted となる。
final MethodChannel kFilePickerChannel = MethodChannel(
  'miguelruivo.flutter.plugins.filepicker',
  (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
      ? const JSONMethodCodec()
      : const StandardMethodCodec(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // テストではプラットフォーム側プラグイン登録が実行されないため、
  // file_picker の既定 MethodChannel 実装を明示的に初期化する。
  FilePickerIO.registerWith();

  late Directory srcDir;
  late Directory destDir;

  setUp(() async {
    srcDir = await Directory.systemTemp.createTemp('llm_imp_src_');
    destDir = await Directory.systemTemp.createTemp('llm_imp_dst_');
  });

  tearDown(() {
    if (srcDir.existsSync()) srcDir.deleteSync(recursive: true);
    if (destDir.existsSync()) destDir.deleteSync(recursive: true);
  });

  /// 有効な GGUF（マジック + パディング）を生成してパスを返す。
  Future<String> writeGguf(String name, {int paddingBytes = 4096}) async {
    final f = File('${srcDir.path}/$name');
    await f.writeAsBytes([...kGgufMagic, ...Uint8List(paddingBytes)]);
    return f.path;
  }

  LlmModelImportService service({
    Future<String?> Function()? pickSourcePath,
    Future<PickedGgufFile?> Function()? pickFile,
  }) {
    return LlmModelImportService(
      pickSourcePath: pickSourcePath,
      pickFile: pickFile,
      destDirResolver: () async => destDir,
    );
  }

  /// パス指定（または null）の PickedGgufFile を返すピッカー注入。
  Future<PickedGgufFile?> Function() pickFileOf(String? path) {
    return () async => path == null ? null : PickedGgufFile(path: path);
  }

  /// file_picker の channel にモックハンドラを設定する（実ダイアログなし）。
  void mockPickFiles(Future<Object?> Function(MethodCall call) handler) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(kFilePickerChannel, handler);
    addTearDown(
      () => messenger.setMockMethodCallHandler(kFilePickerChannel, null),
    );
  }

  /// GGUF マジック付きチャンクストリームを生成する。
  List<Uint8List> buildChunks(int totalBytes, int chunkSize) {
    final chunks = <Uint8List>[];
    var remaining = totalBytes;
    while (remaining > 0) {
      final n = remaining < chunkSize ? remaining : chunkSize;
      final chunk = Uint8List(n);
      for (var i = 0; i < n; i++) {
        chunk[i] = i & 0xFF;
      }
      // 先頭チャンク先頭に GGUF マジック。
      if (chunks.isEmpty) {
        chunk[0] = 0x47; // G
        chunk[1] = 0x47; // G
        chunk[2] = 0x55; // U
        chunk[3] = 0x46; // F
      }
      chunks.add(chunk);
      remaining -= n;
    }
    return chunks;
  }

  group('LlmModelImportService', () {
    test('ピッカーでキャンセルした場合は null を返し何もコピーしない（エラーにならない）', () async {
      final svc = service(pickFile: () async => null);
      final result = await svc.importFromPicker();
      expect(result, isNull);
      expect(destDir.listSync(), isEmpty);
    });

    test('.gguf 以外の拡張子は拒否する', () async {
      final src = await writeGguf('model.txt');
      final svc = service(pickFile: pickFileOf(src));
      await expectLater(
        svc.importFromPicker(),
        throwsA(
          isA<LlmModelImportException>().having(
            (e) => e.message,
            'message',
            contains('GGUFモデルファイルを選択してください'),
          ),
        ),
      );
      expect(destDir.listSync(), isEmpty);
    });

    test('大文字 .GGUF も受理する（大文字小文字無視）', () async {
      final src = await writeGguf('MODEL.GGUF');
      final svc = service(pickFile: pickFileOf(src));
      final result = await svc.importFromPicker();
      expect(result, isNotNull);
      expect(result!.fileName, 'MODEL.GGUF');
      expect(p.basename(result.path), 'MODEL.GGUF');
      expect(
        await LlmModelImportService.hasGgufMagic(File(result.path)),
        isTrue,
      );
    });

    test('GGUF マジックが一致しないファイルは拒否し .part を残さない', () async {
      final f = File('${srcDir.path}/fake.gguf');
      await f.writeAsBytes(List.filled(1024, 0x00));
      final svc = service(pickFile: pickFileOf(f.path));
      await expectLater(
        svc.importFromPicker(),
        throwsA(
          isA<LlmModelImportException>().having(
            (e) => e.message,
            'message',
            contains('有効なGGUFモデルではありません'),
          ),
        ),
      );
      expect(destDir.listSync(), isEmpty);
    });

    test('正常系: コピー先に実体が作られ、進捗が (total, total) で完了する', () async {
      final src = await writeGguf('model.gguf', paddingBytes: 10 << 20); // 10MB
      var lastCopied = 0;
      var lastTotal = 0;
      final svc = service(pickFile: pickFileOf(src));
      final result = await svc.importFromPicker(
        onProgress: (copied, total) {
          lastCopied = copied;
          lastTotal = total;
        },
      );
      expect(result, isNotNull);
      expect(result!.fileName, 'model.gguf');
      expect(p.basename(result.path), 'model.gguf');
      expect(p.dirname(result.path), destDir.path);
      final copiedFile = File(result.path);
      expect(await copiedFile.exists(), isTrue);
      expect(await copiedFile.length(), await File(src).length());
      expect(await LlmModelImportService.hasGgufMagic(copiedFile), isTrue);
      expect(lastCopied, lastTotal);
      expect(lastTotal, greaterThan(0));
      expect(
        destDir.listSync().where((e) => e.path.endsWith('.part')),
        isEmpty,
      );
    });

    test('コピー中断時に例外を投げ、.part を削除する', () async {
      final src = await writeGguf('big.gguf', paddingBytes: 8 << 20);
      final svc = service(pickFile: pickFileOf(src));
      await expectLater(
        svc.importFromPicker(isCancelled: () => true),
        throwsA(isA<LlmModelImportCancelledException>()),
      );
      expect(
        destDir.listSync().where((e) => e.path.endsWith('.part')),
        isEmpty,
      );
      expect(destDir.listSync(), isEmpty);
    });

    test('同名・同サイズの取り込み済みファイルは再コピーせず再利用する', () async {
      final src = await writeGguf('same.gguf');
      final svc = service(pickFile: pickFileOf(src));
      final first = await svc.importFromPicker();
      expect(first, isNotNull);
      // 同サイズの別内容で上書きし、再コピーが走らないことを確認する。
      final destFile = File(first!.path);
      final len = await destFile.length();
      await destFile.writeAsBytes(List.filled(len, 0xAB));
      final second = await svc.importFromPicker();
      expect(second!.path, first.path);
      final bytesAfter = await destFile.readAsBytes();
      expect(bytesAfter.every((b) => b == 0xAB), isTrue);
    });

    test('同名・異サイズなら上書きコピーする', () async {
      final src1 = await writeGguf('grow.gguf', paddingBytes: 1024);
      final svc = service(pickFile: pickFileOf(src1));
      final first = await svc.importFromPicker();
      final src2 = await writeGguf('grow.gguf', paddingBytes: 2048);
      final svc2 = service(pickFile: pickFileOf(src2));
      final second = await svc2.importFromPicker();
      expect(second!.path, first!.path);
      expect(await File(second.path).length(), await File(src2).length());
    });

    test('readStream 経由で大きいファイルを逐次コピーできる（30MB・1MB チャンク）', () async {
      const totalBytes = 30 << 20;
      const chunkSize = 1 << 20;
      final chunks = buildChunks(totalBytes, chunkSize);
      final picked = PickedGgufFile(
        name: 'stream.gguf',
        readStream: Stream<List<int>>.fromIterable(chunks),
        path: null,
        size: totalBytes,
      );
      final svc = service();
      var lastCopied = 0;
      var lastTotal = -1;
      final result = await svc.importFile(
        picked,
        onProgress: (copied, total) {
          lastCopied = copied;
          lastTotal = total;
        },
      );
      expect(result, isNotNull);
expect(result.fileName, 'stream.gguf');
      expect(p.dirname(result.path), destDir.path);
      expect(await File(result.path).length(), totalBytes);
      expect(
        await LlmModelImportService.hasGgufMagic(File(result.path)),
        isTrue,
      );
      expect(lastCopied, totalBytes);
      expect(lastTotal, totalBytes);
    });

    test('readStream が null で path のみなら File(path) でフォールバックコピーする', () async {
      final src = await writeGguf('fallback.gguf', paddingBytes: 2 << 20);
      final picked = PickedGgufFile(name: 'fallback.gguf', path: src);
      final svc = service();
      final result = await svc.importFile(picked);
      expect(result, isNotNull);
expect(await File(result.path).length(), await File(src).length());
      expect(
        await LlmModelImportService.hasGgufMagic(File(result.path)),
        isTrue,
      );
    });

    test('readStream のマジック不一致は拒否し .part を残さない', () async {
      final picked = PickedGgufFile(
        name: 'bad.gguf',
        readStream: Stream<List<int>>.fromIterable([List.filled(1024, 0x00)]),
      );
      final svc = service();
      await expectLater(
        svc.importFile(picked),
        throwsA(
          isA<LlmModelImportException>().having(
            (e) => e.message,
            'message',
            contains('有効なGGUFモデルではありません'),
          ),
        ),
      );
      expect(
        destDir.listSync().where((e) => e.path.endsWith('.part')),
        isEmpty,
      );
      expect(destDir.listSync(), isEmpty);
    });

    test('マジック判定後もストリームは欠落なく完全に書き写される', () async {
      // 検証とコピーが同一パスでも出力は入力と同一バイト列になること
      // （先頭 4 バイトのマジックが欠落しない）。
      const totalBytes = 5 << 20;
      const chunkSize = 1 << 20;
      final chunks = buildChunks(totalBytes, chunkSize);
      final picked = PickedGgufFile(
        name: 'reuse.gguf',
        readStream: Stream<List<int>>.fromIterable(chunks),
        size: totalBytes,
      );
      final svc = service();
      final result = await svc.importFile(picked);
      expect(result, isNotNull);
final destFile = File(result.path);
      expect(await destFile.length(), totalBytes);
      final raf = await destFile.open();
      final head = await raf.read(4);
      await raf.close();
      expect(head, kGgufMagic);
    });

    test('出力ファイルは内部 models/llm（destDir）へ保存される', () async {
      // コピー先ディレクトリを既定ディレクトリ（models/llm）相当に注入し、
      // 出力がその直下に入ることを確認する。
      final src = await writeGguf('loc.gguf');
      final svc = service(pickFile: pickFileOf(src));
      final result = await svc.importFromPicker();
      expect(result, isNotNull);
      expect(p.dirname(result!.path), destDir.path);
      expect(p.basename(result.path), 'loc.gguf');
      expect(
        destDir.listSync().whereType<File>().map((f) => f.path).toList(),
        contains(result.path),
      );
    });

    test('hasGgufMagic: 短いファイル・空ファイルは false', () async {
      final empty = File('${srcDir.path}/empty.gguf');
      await empty.writeAsBytes([]);
      final short = File('${srcDir.path}/short.gguf');
      await short.writeAsBytes(kGgufMagic.sublist(0, 2));
      expect(await LlmModelImportService.hasGgufMagic(empty), isFalse);
      expect(await LlmModelImportService.hasGgufMagic(short), isFalse);
    });

    test('hasGgufMagicStream: 先頭チャンクで判定する', () async {
      final ok = Uint8List(64)
        ..[0] = 0x47
        ..[1] = 0x47
        ..[2] = 0x55
        ..[3] = 0x46;
      expect(
        await LlmModelImportService.hasGgufMagicStream(
          Stream<List<int>>.fromIterable([ok]),
        ),
        isTrue,
      );
      expect(
        await LlmModelImportService.hasGgufMagicStream(
          Stream<List<int>>.fromIterable([List<int>.filled(4, 0)]),
        ),
        isFalse,
      );
      expect(
        await LlmModelImportService.hasGgufMagicStream(
          Stream<List<int>>.fromIterable([List<int>.filled(2, 0x47)]),
        ),
        isFalse,
      );
    });
  });

  group('FilePicker 呼び出し（MethodChannel モック・実ダイアログなし）', () {
    test('FileType.any・allowedExtensions 非指定・withData 非使用で呼び出す', () async {
      final src = await writeGguf('picked.gguf', paddingBytes: 256);
      final size = 4 + 256;
      var calls = 0;
      mockPickFiles((call) async {
        calls++;
        // file_picker は type をメソッド名として渡す（invokeListMethod(type, ...)）。
        expect(call.method, 'any');
        final args = call.arguments as Map;
        // 実機不具合の核心: allowedExtensions は一切指定しないこと。
        expect(args['allowedExtensions'], isNull);
        expect(args['allowMultipleSelection'], false);
        expect(args['withData'], false);
        return [
          {'name': 'picked.gguf', 'path': src, 'size': size, 'bytes': null},
        ];
      });
      final svc = LlmModelImportService(destDirResolver: () async => destDir);
      final result = await svc.importFromPicker();
      expect(calls, 1);
      expect(result, isNotNull);
      expect(result!.fileName, 'picked.gguf');
      expect(await File(result.path).length(), size);
      expect(
        await LlmModelImportService.hasGgufMagic(File(result.path)),
        isTrue,
      );
    });

    test('channel が null を返す場合（ユーザーキャンセル）は null（エラーにならない）', () async {
      mockPickFiles((call) async => null);
      final svc = LlmModelImportService(destDirResolver: () async => destDir);
      expect(await svc.importFromPicker(), isNull);
      expect(destDir.listSync(), isEmpty);
    });

    test('channel が cancelled コードの例外を送出しても null（エラーにならない）', () async {
      mockPickFiles(
(call) async => throw PlatformException(code: 'cancelled'),
      );
      final svc = LlmModelImportService(destDirResolver: () async => destDir);
      expect(await svc.importFromPicker(), isNull);
      expect(destDir.listSync(), isEmpty);
    });

    test('Unsupported filter は分類され、内部メッセージは UI に出ない', () {
      final e = PlatformException(
        code: 'FilePicker',
        message:
            'Unsupported filter. Make sure that you are only using '
            'the extension without the dot.',
      );
      expect(LlmModelImportService.isUnsupportedFilterError(e), isTrue);
      final mapped = LlmModelImportService.mapPickerError(e);
      expect(mapped.message, isNot(contains('Make sure')));
      expect(mapped.message, contains('GGUF 指定のファイル選択に失敗しました'));
    });

    test('file_not_found は読み取り失敗の定型メッセージになる', () {
final e = PlatformException(code: 'file_not_found');
      expect(LlmModelImportService.isUnsupportedFilterError(e), isFalse);
      expect(
        LlmModelImportService.mapPickerError(e).message,
        '選択したファイルを読み取れませんでした。',
      );
    });

    test('不明なコードは汎用の定型メッセージになる', () {
final e = PlatformException(
        code: 'boom',
        message: 'secret details',
      );
      expect(
        LlmModelImportService.mapPickerError(e).message,
        'ファイルの選択に失敗しました。',
      );
    });
  });
}
