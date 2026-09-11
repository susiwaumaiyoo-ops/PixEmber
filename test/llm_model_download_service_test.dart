// LlmModelDownloadService（M4）のテスト。
//
// 実ネットワーク・実モデルは使用しない。ModelDownloadManager を fake（gate）
// で置き換え、以下を検証する:
// - 通常フロー（resolving→checkingCache→downloading→verifying→ready）
// - FIFO + 同時 1 件
// - キャッシュ再利用（サイズ一致で再 DL しない / 不一致なら再 DL）
// - キャンセル（実行中 / 待機中）
// - failed 後の retry
// - サイズ検証（不一致 → failed）
// - 未検証エントリの拒否（ArgumentError）
// - 重複 enqueue の防止（実行中 / ready 後）

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/llm_model_download_manager.dart'
    show
        ModelCacheEntry,
        ModelDownloadManager,
        ModelDownloadProgress,
        ModelLoadOptions,
        ModelSource;
import 'package:pixiv_viewer/models/llm_model_catalog_entry.dart';
import 'package:pixiv_viewer/services/llm_model_download_service.dart';

const String _goodRev = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
const String _goodSha =
    'a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1';

LlmModelCatalogEntry _entry({
  String id = 'model-a',
  String fileName = 'model-a.gguf',
  int size = 100,
  String sha256 = _goodSha,
  String revision = _goodRev,
  String repositoryId = 'mradermacher/Huihui-Qwen3.5-0.8B-abliterated-GGUF',
}) {
  return LlmModelCatalogEntry(
    id: id,
    displayName: 'Model $id',
    family: 'Test',
    parameterCount: '0.8B',
    quantization: 'Q4_K_M',
    repositoryId: repositoryId,
    revision: revision,
    fileName: fileName,
    expectedSizeBytes: size,
    sha256: sha256,
    licenseId: 'apache-2.0',
    attribution: 'test',
    description: 'fake entry',
    recommendedContext: 4096,
    maxOutputTokens: 512,
    estimatedRamBytes: 1024,
    preferredBackend: 'llama_cpp',
    preferredGpuLayers: 0,
    capabilities: const ['text_generation'],
    reducedSafetyAlignment: true,
    platforms: const ['android'],
    isExperimental: false,
  );
}

/// ModelDownloadManager の fake。
///
/// ensureModel は gate で停止するため、テスト側がダウンロード進行を制御
/// できる。complete されたら [ensureBytes] バイトのファイルを
/// cacheDirectory/{fileName} に書き、entry を返す。
class _FakeManager implements ModelDownloadManager {
  _FakeManager(this.managedDir);

  final Directory managedDir;

  final List<Completer<void>> gates = [];
  Object? ensureError;
  int ensureBytes = 100;
  ModelCacheEntry? cacheHit;

  /// ensureModel 内（throw 前）に記録した cancelToken の状態。
  final List<bool> cancelFlagsAtThrow = [];

  int ensureCalls = 0;
  int getCalls = 0;
  int active = 0;
  int maxActive = 0;
  ModelSource? lastSource;
  ModelLoadOptions? lastOptions;
  String? lastGetCacheKey;
  String? lastGetCacheDirectory;

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    void Function(ModelDownloadProgress)? onProgress,
  }) async {
    ensureCalls++;
    lastSource = source;
    lastOptions = options;
    active++;
    if (active > maxActive) maxActive = active;
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    active--;
    cancelFlagsAtThrow.add(options.cancelToken?.isCancelled ?? false);
    if (options.cancelToken?.isCancelled ?? false) {
      throw StateError('cancelled by user');
    }
    if (ensureError != null) {
      throw ensureError!;
    }
    final base = options.cacheDirectory ?? managedDir.path;
    final file = File('$base/${source.fileName}');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(ensureBytes, 0x41));
    onProgress?.call(
      ModelDownloadProgress(
        receivedBytes: ensureBytes ~/ 2,
        totalBytes: ensureBytes,
      ),
    );
    onProgress?.call(
      ModelDownloadProgress(
        receivedBytes: ensureBytes,
        totalBytes: ensureBytes,
      ),
    );
    return ModelCacheEntry(
      sourceCanonicalKey: source.canonicalKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: file.path,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      bytes: ensureBytes,
      sha256: options.sha256,
    );
  }

  @override
  Future<ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async {
    getCalls++;
    lastGetCacheKey = cacheKey;
    lastGetCacheDirectory = cacheDirectory;
    return cacheHit;
  }

  @override
  Future<List<ModelCacheEntry>> list({String? cacheDirectory}) async =>
      const [];

  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) async {}

  @override
  Future<void> clear({String? cacheDirectory}) async {}

  @override
  Future<List<ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  }) async => const [];
}

/// [id] のタスクが [stage] に到達するまで待つ（現在値を 5ms ごとポーリング）。
///
/// fake の ensureModel は gate で停止するため、待機対象ステージで必ず
/// 停止する（取り逃しなし）。
/// 注意: イベントログ方式（broadcast ストリームの購読 + 蓄積）は
/// retry 後に前回 run の同ステージへ再ヒットして即リターンし、
/// 次の gate が未作成のまま complete してしまうため不使用。
Future<LlmModelDownloadTask> _waitFor(
  LlmModelDownloadService svc,
  String id,
  LlmModelDownloadStage stage,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final t = svc.taskFor(id);
    if (t != null && t.stage == stage) return t;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        '$id が $stage に 5 秒以内に到達しなかった',
        const Duration(seconds: 5),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory managedDir;
  late _FakeManager mgr;
  late LlmModelDownloadService svc;

  setUp(() async {
    managedDir = await Directory.systemTemp.createTemp('llm_dl_test_');
    mgr = _FakeManager(managedDir);
    svc = LlmModelDownloadService(
      manager: mgr,
      managedDirProvider: () async => managedDir,
    );
  });

  tearDown(() async {
    if (await managedDir.exists()) {
      await managedDir.delete(recursive: true);
    }
  });

  test('通常フロー: downloading→ready、pin/sha/保存先がマネージャへ渡される', () async {
    svc.enqueue(_entry());
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);
    mgr.gates.last.complete();
    final t = await _waitFor(svc, 'model-a', LlmModelDownloadStage.ready);

    expect(t.localPath, isNotNull);
    final file = File(t.localPath!);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), 100);

    expect(
      mgr.lastSource!.repoId,
      'mradermacher/Huihui-Qwen3.5-0.8B-abliterated-GGUF',
    );
    expect(mgr.lastSource!.revision, _goodRev);
    expect(mgr.lastSource!.filePath, 'model-a.gguf');
    expect(mgr.lastOptions!.cacheDirectory, managedDir.path);
    expect(mgr.lastOptions!.sha256, _goodSha);
    expect(mgr.lastOptions!.resume, isTrue);
    expect(mgr.lastOptions!.cancelToken, isNotNull);

    // キャッシュ確認: 同一 cacheKey + 管理ディレクトリで 1 回だけ。
    expect(mgr.getCalls, 1);
    expect(mgr.lastGetCacheKey, mgr.lastSource!.cacheKey);
    expect(mgr.lastGetCacheDirectory, managedDir.path);
    expect(mgr.ensureCalls, 1);
  });

  test('FIFO: 同時 1 件で 2 件目は待機 → 先頭完了後に自動開始', () async {
    svc.enqueue(_entry(id: 'model-a', fileName: 'model-a.gguf'));
    svc.enqueue(_entry(id: 'model-b', fileName: 'model-b.gguf'));
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);
    expect(svc.taskFor('model-b')!.stage, LlmModelDownloadStage.queued);

    mgr.gates.last.complete();
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.ready);

    await _waitFor(svc, 'model-b', LlmModelDownloadStage.downloading);
    mgr.gates.last.complete();
    await _waitFor(svc, 'model-b', LlmModelDownloadStage.ready);

    expect(mgr.maxActive, 1);
    expect(mgr.ensureCalls, 2);
  });

  test('キャッシュヒット: サイズ一致なら再ダウンロードしない', () async {
    final f = File('${managedDir.path}/cached.gguf');
    f.writeAsBytesSync(List.filled(100, 0x42));
    mgr.cacheHit = ModelCacheEntry(
      sourceCanonicalKey: 'x',
      cacheKey: 'x',
      fileName: 'model-a.gguf',
      filePath: f.path,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      bytes: 100,
      sha256: _goodSha,
    );

    svc.enqueue(_entry());
    final t = await _waitFor(svc, 'model-a', LlmModelDownloadStage.ready);

    expect(t.localPath, f.path);
    expect(mgr.ensureCalls, 0);
    expect(mgr.getCalls, 1);
  });

  test('キャッシュサイズ不一致: 再ダウンロードに進む', () async {
    final f = File('${managedDir.path}/cached-small.gguf');
    f.writeAsBytesSync(List.filled(50, 0x42));
    mgr.cacheHit = ModelCacheEntry(
      sourceCanonicalKey: 'x',
      cacheKey: 'x',
      fileName: 'model-a.gguf',
      filePath: f.path,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      bytes: 50,
    );

    svc.enqueue(_entry());
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);
    mgr.gates.last.complete();
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.ready);

    expect(mgr.ensureCalls, 1);
  });

  test('キャンセル（実行中）: cancelled になり次が自動開始される', () async {
    svc.enqueue(_entry(id: 'model-a', fileName: 'model-a.gguf'));
    svc.enqueue(_entry(id: 'model-b', fileName: 'model-b.gguf'));
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);

    svc.cancel('model-a');
    mgr.gates.last.complete();
    final t = await _waitFor(svc, 'model-a', LlmModelDownloadStage.cancelled);

    expect(t.errorMessage, contains('キャンセル'));
    // lastOptions は後続タスク（b）で上書きされるため fake 内の記録で判定。
    expect(mgr.cancelFlagsAtThrow.first, isTrue);

    await _waitFor(svc, 'model-b', LlmModelDownloadStage.downloading);
    mgr.gates.last.complete();
    await _waitFor(svc, 'model-b', LlmModelDownloadStage.ready);
    expect(mgr.ensureCalls, 2);
  });

  test('キャンセル（待機中）: キューから除外され実行されない', () async {
    svc.enqueue(_entry(id: 'model-a', fileName: 'model-a.gguf'));
    svc.enqueue(_entry(id: 'model-b', fileName: 'model-b.gguf'));
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);

    svc.cancel('model-b');
    expect(svc.taskFor('model-b')!.stage, LlmModelDownloadStage.cancelled);

    mgr.gates.last.complete();
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.ready);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(mgr.ensureCalls, 1);
    expect(svc.taskFor('model-b')!.stage, LlmModelDownloadStage.cancelled);
  });

  test('failed → retry: 再実行して成功する', () async {
    mgr.ensureError = Exception('boom');
    svc.enqueue(_entry());
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);
    mgr.gates.last.complete();
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.failed);
    expect(svc.taskFor('model-a')!.errorMessage, contains('boom'));

    mgr.ensureError = null;
    svc.retry('model-a');
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);
    mgr.gates.last.complete();
    final t = await _waitFor(svc, 'model-a', LlmModelDownloadStage.ready);

    expect(t.errorMessage, isNull);
    expect(mgr.ensureCalls, 2);
  });

  test('サイズ不一致: ユーザー向けメッセージ付き failed', () async {
    mgr.ensureBytes = 50;
    svc.enqueue(_entry());
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);
    mgr.gates.last.complete();
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.failed);

    expect(svc.taskFor('model-a')!.errorMessage, contains('サイズ不一致'));
  });

  test('未検証エントリ: ArgumentError で拒否される', () async {
    expect(() => svc.enqueue(_entry(sha256: 'bad-sha')), throwsArgumentError);
    expect(mgr.ensureCalls, 0);
    expect(svc.taskFor('model-a'), isNull);
  });

  test('実行中の重複 enqueue: 無視される', () async {
    svc.enqueue(_entry());
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);
    svc.enqueue(_entry());
    expect(mgr.ensureCalls, 1);

    mgr.gates.last.complete();
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.ready);
    expect(mgr.ensureCalls, 1);
  });

  test('ready 後の enqueue: 再実行されない', () async {
    svc.enqueue(_entry());
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.downloading);
    mgr.gates.last.complete();
    await _waitFor(svc, 'model-a', LlmModelDownloadStage.ready);

    svc.enqueue(_entry());
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(mgr.ensureCalls, 1);
    expect(svc.taskFor('model-a')!.stage, LlmModelDownloadStage.ready);
  });
}
