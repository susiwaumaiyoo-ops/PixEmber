// Phase 9-B2/B2-4+5: LlmRunArbiter の仲裁ロジック回帰テスト。
//
// 実推論は使わず、LocalLlmService の engineFactory に制御可能な fake を注入し、
// 「自動生成中の手動待ち受けと自動完了後のキュー消化（drain）」
// 「二重配送防止」「セッション内でモデルを1回だけロード」を検証する。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/llm_run_arbiter.dart';
import 'package:pixiv_viewer/services/llm_summary_service.dart';
import 'package:pixiv_viewer/services/local_llm_service.dart';

/// 有効な要約出力（parseOutput が成功する形式）。
String _goodOutput(String tag) =>
    '【あらすじ】\n$tagのあらすじです。\n'
    '【紹介】\n$tagの紹介文です。\n'
    '【タグ】\n$tag, テスト';

/// generate の「呼ばれた」と「進行を許す」を外部から制御できる fake エンジン。
///
/// - generate が呼ばれると [_started] を完成させる（=生成中を確定できる）。
/// - 最初の generate は [_gate] の解除まで待って chunks を流す。
/// - gate 解除後は [_gateFuture] が常に完了済みなので、以降の generate は
///   待たずに完了する（自動→手動の連続 generate を素通しできる）。
class _ControllableEngine implements LlmInferenceEngine {
  _ControllableEngine(this.tag);

  final String tag;
  int loadCalls = 0;
  int generateCalls = 0;

  final Completer<void> _started = Completer<void>();
  final Completer<void> _gate = Completer<void>();

  /// generate が実際に呼ばれたことを待つ。
  Future<void> get started => _started.future;

  /// 進行を待たせている generate を完了させる。
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<void> loadModel(String modelPath) async {
    loadCalls++;
  }

  @override
  Stream<String> generate({
    required List<LlmChatMessage> messages,
    required LlmGenerationOptions options,
  }) {
    generateCalls++;
    if (!_started.isCompleted) _started.complete();
    Stream<String> body() async* {
      await _gate.future;
      yield _goodOutput(tag);
    }

    return body();
  }

  @override
  void dispose() {}
}

void main() {
  late Directory tmp;
  late String modelPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('arbiter_test_');
    final f = File('${tmp.path}/model.gguf')..writeAsStringSync('gguf');
    modelPath = f.path;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  LlmRunArbiter arbiterWith(_ControllableEngine engine) {
    return LlmRunArbiter(
      modelPathResolver: () async => modelPath,
      serviceFactory: (path) => LocalLlmService(engineFactory: (_) => engine),
    );
  }

  group('LlmRunArbiter 仲裁', () {
    test('自動生成中の手動 submit → waiting、自動完了後に自動で消化され completed', () async {
      final engine = _ControllableEngine('モデル');
      final arb = arbiterWith(engine);

      final statuses = <String>[];
      final completed = Completer<LlmSummaryResult?>();
      arb.onManualEvent = (id, status, {token, result, error}) {
        statuses.add('$id:${status.name}');
        if (id == 'm1' &&
            status == ManualRequestStatus.completed &&
            !completed.isCompleted) {
          completed.complete(result);
        }
      };

      // 自動生成を開始（await せず生成中状態を作る）。
      final autoFuture = arb.generateAuto(
        workId: 100,
        title: '自動作品',
        tags: const ['a'],
        body: '自動の本文です。' * 10,
      );
      await engine.started;
      expect(arb.isGenerating, isTrue);

      // 自動生成中に手動 submit → waiting（キュー行き）。
      final manual = ManualSummaryRequest(
        requestId: 'm1',
        workId: 200,
        title: '手動作品',
        tags: const ['b'],
        body: '手動の本文です。' * 10,
      );
      await arb.submitManual(manual);
      expect(statuses, contains('m1:waiting'));
      expect(arb.hasManualPending, isTrue);
      expect(arb.isGenerating, isTrue); // まだ自動が生成中

      // 自動を完了させる → _scheduleDrain が走り、手動が自動で消化される。
      // gate 解除後は同一エンジンの次の generate は即完了するので待つだけ。
      // drain の手動 generate も同一 gate を通る（既に open）。
      engine.release();
      await autoFuture;

      // completed イベントを明示的に待つ（drain 経由で自動消化されるはず）。
      final result = await completed.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      expect(result, isNotNull, reason: 'drain が手動を完了させるべき');

      expect(statuses, contains('m1:generating'));
      expect(statuses, contains('m1:completed'));
      expect(arb.hasManualPending, isFalse);
      expect(arb.isGenerating, isFalse);
    });

    test('同一 requestId の二重配送は2回目を無視する', () async {
      final engine = _ControllableEngine('モデル');
      final arb = arbiterWith(engine);
      var completedCount = 0;
      arb.onManualEvent = (id, status, {token, result, error}) {
        if (status == ManualRequestStatus.completed) completedCount++;
      };

      final req = ManualSummaryRequest(
        requestId: 'dup',
        workId: 1,
        title: 'T',
        tags: const [],
        body: '本文です。' * 10,
      );
      // 1回目: 生成開始まで待つ → release → 完了。
      final f1 = arb.submitManual(req);
      await engine.started;
      engine.release();
      await f1;
      expect(completedCount, 1);

      // 2回目: 同一 requestId はイベントを発火させない。
      await arb.submitManual(req);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(completedCount, 1, reason: '二重配送は completed を増やさない');
    });

    test('セッション内でモデルは1回だけロードされる（自動→自動）', () async {
      final engine = _ControllableEngine('モデル');
      final arb = arbiterWith(engine);

      // 1作品目（release して完了）。
      final a = arb.generateAuto(
        workId: 1,
        title: 'A',
        tags: const [],
        body: 'あ' * 50,
      );
      await engine.started;
      engine.release();
      await a;

      // 2作品目（同一 arbiter）→ ensureModel はスキップ、gate 解除済みで即完了。
      final b = arb.generateAuto(
        workId: 2,
        title: 'B',
        tags: const [],
        body: 'い' * 50,
      );
      await b;

      expect(engine.loadCalls, 1, reason: 'セッション内でモデルロードは1回');
      expect(engine.generateCalls, greaterThanOrEqualTo(2));
      expect(arb.modelId, 'model.gguf');
    });
  });
}
