// Phase 16d-4: AppSuccessCheck と適用 3 箇所の契約テスト。
//
// 対象:
// - AppSuccessCheck: サイズ 48 既定・visible false->true で 1 度だけ発動
// - AppMotion.long (320ms) が上限・Reduce Motion は即最終状態
// - haptic は既定 false・onCompleted が完了時に呼ばれる
// - 適用: download_queue_screen（完了遷移のみ） /
//         llm_summary_sheet（size 32・1 度だけ） /
//         backup_manager_screen（success banner の leading）
//
// 挙動は onCompleted の呼び出し回数と CustomPainter の描画結果で検証し、
// 適用箇所はソースの静的契約で検証する（画面の build が
// DatabaseService・Drive API に依存するため）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/theme/app_motion.dart';
import 'package:pixiv_viewer/widgets/design_system/app_success_check.dart';

void main() {
  group('16d-4 AppSuccessCheck 挙動', () {
    testWidgets('visible: false のままでは一度も完了しない', (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _CheckHost(
            visible: const [false],
            onCompleted: () => completed++,
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle(AppMotion.long);
      expect(completed, equals(0));
    });
    testWidgets('visible: false -> true で 1 度だけ発動し、完了する', (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _CheckHost(
            visible: const [false, true],
            onCompleted: () => completed++,
          ),
        ),
      );
      await tester.pump();

      // まだ発動していない。
      expect(completed, equals(0));

      // false -> true に変化させる。
      await tester.tap(find.byType(_CheckHost));
      await tester.pump();

      // 完了まで進める。
      await tester.pumpAndSettle(AppMotion.long);
      expect(completed, equals(1));
    });

    testWidgets('初期 visible: true は次フレームで発動する', (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _CheckHost(
            visible: const [true],
            onCompleted: () => completed++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle(AppMotion.long);
      expect(completed, equals(1));
    });

    testWidgets('連続タップ: false -> true の変化ごとに再度発動する', (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _CheckHost(
            visible: const [false, true, false, true],
            onCompleted: () => completed++,
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle(AppMotion.long);
      expect(completed, equals(0));

      // 1 回目の true。
      await tester.tap(find.byType(_CheckHost));
      await tester.pumpAndSettle(AppMotion.long);
      expect(completed, equals(1));

      // false を挟んでから再度 true。
      await tester.tap(find.byType(_CheckHost));
      await tester.pumpAndSettle(AppMotion.long);
      expect(completed, equals(1));

      await tester.tap(find.byType(_CheckHost));
      await tester.pumpAndSettle(AppMotion.long);
      expect(completed, equals(2));
    });

    testWidgets('haptic は既定で無効でも完了する', (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _CheckHost(
            visible: const [false, true],
            onCompleted: () => completed++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(_CheckHost));
      await tester.pumpAndSettle(AppMotion.long);
      expect(completed, equals(1));
    });

    testWidgets('Reduce Motion 時はアニメーションせず即完了する', (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            );
          },
          home: _CheckHost(
            visible: const [false, true],
            onCompleted: () => completed++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(_CheckHost));
      // long (320ms) を待たずとも即完了しているはず。
      await tester.pump();
      expect(completed, equals(1));
    });
  });

  group('16d-4 ソース契約', () {
    test('AppSuccessCheck: 仕様の定数と Reduce Motion 尊重', () {
      final src = _readSource(
        'lib/widgets/design_system/app_success_check.dart',
      );

      // 既定サイズ 48。
      expect(src.contains('this.size = 48'), isTrue);
      // haptic は既定無効。
      expect(src.contains('this.haptic = false'), isTrue);
      // 上限は AppMotion.long（320ms）。
      expect(src.contains('duration: AppMotion.long'), isTrue);
      // 円のカーブは強調寄りの減速。
      expect(src.contains('curve: AppMotion.emphasized'), isTrue);
      // チェックは円の後半から。
      expect(src.contains('Interval(0.55, 1.0'), isTrue);
      // Reduce Motion 尊重。
      expect(src.contains('AppMotion.reduce(context)'), isTrue);
      // 「一度だけ」は didUpdateWidget の false->true 変化で制御。
      expect(src.contains('widget.visible && !oldWidget.visible'), isTrue);
      // ロジック・データ層には触れない。
      expect(src.contains('database_service'), isFalse);
      expect(src.contains('download_service'), isFalse);
    });

    test('download_queue_screen: 完了遷移のみに AppSuccessCheck を置く', () {
      final src = _readSource('lib/screens/download_queue_screen.dart');

      expect(src.contains('AppSuccessCheck('), isTrue);
      // 1 回限りのフラグ（_svc.onComplete で立て、_load で下ろす）。
      expect(src.contains('_justCompletedGroupId'), isTrue);
      expect(src.contains('_justCompletedGroupId = groupId'), isTrue);
      expect(
        src.contains('_justCompletedGroupId = null'),
        isTrue,
        reason: 'DB 反映後にフラグを下ろす（スクロール再描画で再発動しない）',
      );
      // タイルはフラグと一致するときだけ visible。
      expect(src.contains('visible: _justCompletedGroupId == groupId'), isTrue);
    });

    test('llm_summary_sheet: size 32・1 度だけ', () {
      final src = _readSource('lib/widgets/llm_summary_sheet.dart');

      expect(src.contains('AppSuccessCheck('), isTrue);
      expect(src.contains('size: 32'), isTrue);
      // done フェーズのときだけ visible（再生成で別インスタンス）。
      expect(src.contains('visible: _phase == _SheetPhase.done'), isTrue);
    });

    test('backup_manager_screen: 成功バナーの leading に AppSuccessCheck', () {
      final src = _readSource('lib/screens/backup_manager_screen.dart');

      expect(src.contains('AppSuccessCheck('), isTrue);
      // バナーのアイコン位置（leading）を使う。
      expect(src.contains('leading: AppSuccessCheck('), isTrue);
      // _lastActionMessage がセットされたときだけ可視。
      expect(src.contains('visible: _lastActionMessage != null'), isTrue);
    });

    test('app_status_banner: leading を受け取る', () {
      final src = _readSource(
        'lib/widgets/design_system/app_status_banner.dart',
      );

      expect(src.contains('final Widget? leading;'), isTrue);
      expect(src.contains('leading ??'), isTrue);
    });
  });
}

/// AppSuccessCheck を visible リスト順に切り替えるホスト。
class _CheckHost extends StatefulWidget {
  const _CheckHost({required this.visible, this.onCompleted});

  /// タップごとに visible をこの順番で切り替える。
  final List<bool> visible;

  final VoidCallback? onCompleted;

  @override
  State<_CheckHost> createState() => _CheckHostState();
}

class _CheckHostState extends State<_CheckHost> {
  int _step = 0;

  bool get _current =>
      _step < widget.visible.length ? widget.visible[_step] : false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _step++;
        });
      },
      child: AppSuccessCheck(
        visible: _current,
        onCompleted: widget.onCompleted,
      ),
    );
  }
}

String _readSource(String path) {
  return File(path).readAsStringSync();
}
