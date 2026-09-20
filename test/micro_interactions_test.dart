// Phase 16d-3: マイクロインタラクションの契約テスト。
//
// 対象: 画像フェードイン / グリッド stagger / ブックマーク バウンス。
// いずれも AppMotion のトークン（160/240/320ms・easeOutCubic・emphasized）
// を使い、Reduce Motion を尊重し、240ms 以内で完了する。
//
// 実画面の build は DatabaseService・Pixiv API に依存するため、
// hero_motion_test.dart と同じく **ソースコードの静的契約** で検証する。
// BounceBookmarkIcon だけは単体で動くので WidgetTester で挙動検証する。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_viewer/theme/app_motion.dart';
import 'package:pixiv_viewer/screens/illust_detail_ui_components.dart';

void main() {
  group('16d-3 ソース契約', () {
    test('PixivImage: frameBuilder がフェードインを実装している', () {
      final src = _readSource('lib/widgets/pixiv_image.dart');
      final networkBlock = _extractBody(src, 'Widget _buildNetworkImage(');

      // デコード完了を知るための公式 API を使っていること。
      expect(
        networkBlock.contains(
          'frameBuilder: (context, child, frame, wasSynchronouslyLoaded)',
        ),
        isTrue,
      );
      // 同期ロード（キャッシュヒット）はアニメーションなしで即表示。
      expect(
        networkBlock.contains('if (wasSynchronouslyLoaded || frame != null)'),
        isTrue,
      );
      // デコード中のみフェード。0.0 -> 1.0 を AppMotion で。
      expect(
        networkBlock.contains('Tween<double>(begin: 0.0, end: 1.0)'),
        isTrue,
      );
      expect(networkBlock.contains('duration: AppMotion.medium'), isTrue);
      expect(networkBlock.contains('curve: AppMotion.enter'), isTrue);
    });

    test('グリッド: stagger が初回描画のみ発動する作りになっている', () {
      final src = _readSource('lib/screens/home_ui_components.dart');

      // 発動追跡用のカウント（初回描画のみ true にするための仕掛け）。
      expect(src.contains('int _staggeredCount = 0;'), isTrue);

      final staggerBlock = _extractBody(src, 'Widget _buildStaggeredGridItem(');
      // 初回かどうかの判定。
      expect(
        staggerBlock.contains(
          'final isFirstAppearance = index >= _staggeredCount;',
        ),
        isTrue,
      );
      // 2 回目以降はアニメーションなしでそのまま返す。
      expect(
        staggerBlock.contains('if (!isFirstAppearance)') &&
            staggerBlock.contains('return content;'),
        isTrue,
      );
      // AnimationController を使わず TweenAnimationBuilder で実装。
      expect(
        staggerBlock.contains('TweenAnimationBuilder<double>(') &&
            !staggerBlock.contains('AnimationController('),
        isTrue,
      );
      // インデックスごとの遅延。8 項目で頭打ち。
      expect(staggerBlock.contains('(index < 8 ? index : 8)'), isTrue);
      // 240ms 以内（AppMotion.medium）。
      expect(staggerBlock.contains('duration: AppMotion.medium'), isTrue);
    });

    test('ブックマーク: bounce は API 成功後のみ発動する', () {
      final src = _readSource('lib/screens/illust_detail_state.dart');

      // 「API 成功」を伝える公開フラグ。UI 側から consume する必要は
      // ない（アイコンが false -> true の差分で判定する）。
      expect(
        src.contains('bool get didBookmarkSucceed => _didBookmarkSucceed;'),
        isTrue,
      );
      expect(src.contains('bool _didBookmarkSucceed = false;'), isTrue);
      // handler（別ライブラリ）が立てるための public setter。
      expect(
        src.contains('set didBookmarkSucceed(bool value)') &&
            src.contains('_didBookmarkSucceed = value;'),
        isTrue,
      );

      final handlerSrc = _readSource('lib/screens/illust_detail_handler.dart');
      final toggleBlock = _extractBody(
        handlerSrc,
        'Future<void> toggleBookmark(',
      );
      // 成功ブランチでのみフラグを立てる。
      expect(
        toggleBlock.contains('if (errorMessage == null)') &&
            toggleBlock.contains('state.didBookmarkSucceed = toAdd;'),
        isTrue,
      );
      // 16d-3 で直した isToggling の解除が成功ブランチにあること。
      expect(toggleBlock.contains('state.isToggling = false;'), isTrue);
    });

    test('ブックマーク: 3 箇所のボタンが BounceBookmarkIcon を使っている', () {
      final src = _readSource('lib/screens/illust_detail_ui_components.dart');

      // スマホ AppBar / タブレット AppBar / メタパネルの 3 箇所。
      // bounce に state.didBookmarkSucceed を渡している。
      expect(src.contains('bounce: state.didBookmarkSucceed,'), isTrue);
      // 3 箇所（スマホ AppBar / タブレット AppBar / メタパネル）
      // + コンストラクタ定義 1 つ = 4。
      expect(src.split('BounceBookmarkIcon(').length - 1, 4);

      // 「API 成功後のみ」を成立させるための TweenSequence。
      // 押し出し 1.0 -> 1.25（70%）/ 戻り 1.25 -> 1.0（30%）。
      // ※ TweenSequence は State クラス内にあるため、ファイル全体から
      //   探す（_extractClass は widget クラスの範囲しか返さない）。
      expect(src.contains('TweenSequence<double>'), isTrue);
      // 改行位置は dart format 次第なので、値だけを個別に検証する。
      expect(src.contains('begin: 1.0,'), isTrue);
      expect(src.contains('end: 1.25,'), isTrue);
      expect(src.contains('begin: 1.25,'), isTrue);
      expect(src.contains('end: 1.0,'), isTrue);
      expect(src.contains('weight: 70'), isTrue);
      expect(src.contains('weight: 30'), isTrue);
      // 240ms 以内。
      expect(src.contains('duration: AppMotion.medium'), isTrue);
      // 「一度だけ」: false -> true の差分で発動する。
      expect(src.contains('if (widget.bounce && !oldWidget.bounce)'), isTrue);
      expect(src.contains('_controller.forward(from: 0.0)'), isTrue);
    });
  });

  group('16d-3 BounceBookmarkIcon 挙動', () {
    // TweenSequence で変換済みの Animation<double> を観察する
    // （コントローラそのものは private で別ライブラリから取得できない）。
    // 値が 1.0 から離れる = バウンス発動、1.0 のまま = 非発動。
    Animation<double> scaleOf(WidgetTester tester) {
      return tester
          .widget<ScaleTransition>(
            find.descendant(
              of: find.byType(_BounceHost),
              matching: find.byType(ScaleTransition),
            ),
          )
          .scale;
    }

    testWidgets('bounce が false -> true に変わったときだけ 1 回発動する', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const Scaffold(body: _BounceHost(bounces: [false, true, true])),
        ),
      );

      // 0. 初期状態（bounce=false）: スケール 1.0。
      expect(scaleOf(tester).value, 1.0);

      // 1. false -> true で発動。少し時間を進めると 1.0 より大きくなる。
      await tester.tap(find.byType(_BounceHost));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(scaleOf(tester).value, greaterThan(1.0));

      // 2. 完了まで進める。ピーク 1.25 を経て 1.0 に戻る。
      await tester.pumpAndSettle(AppMotion.medium);
      expect(scaleOf(tester).value, closeTo(1.0, 0.01));

      // 3. true -> true（再発動しない。「一度だけ」）。
      final before = scaleOf(tester).value;
      await tester.tap(find.byType(_BounceHost));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(scaleOf(tester).value, equals(before));
    });

    testWidgets('API 成功でない（bounce=false のまま）ときは発動しない', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const Scaffold(body: _BounceHost(bounces: [false, false])),
        ),
      );
      await tester.tap(find.byType(_BounceHost));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(scaleOf(tester).value, equals(1.0));
    });

    testWidgets('連続タップ: true -> false -> true で再度発動する', (tester) async {
      // 初期 bounce=false で始め、タップごとに false -> true -> false -> true
      // と切り替える。didUpdateWidget は初回 build では呼ばれないので、
      // 初期値は false にしておく。
      await tester.pumpWidget(
        MaterialApp(
          home: const Scaffold(
            body: _BounceHost(bounces: [false, true, false, true]),
          ),
        ),
      );

      // 0. 初期状態（bounce=false）: 発動しない。
      expect(scaleOf(tester).value, equals(1.0));

      // 1. タップで true に。1 回目発動。
      await tester.tap(find.byType(_BounceHost));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(scaleOf(tester).value, greaterThan(1.0));
      await tester.pumpAndSettle(AppMotion.medium);

      // 2. さらにタップで false に戻る（アニメーションしない）。
      await tester.tap(find.byType(_BounceHost));
      await tester.pump();
      expect(scaleOf(tester).value, equals(1.0));

      // 3. さらにタップで再び true に。再度発動する。
      await tester.tap(find.byType(_BounceHost));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(scaleOf(tester).value, greaterThan(1.0));
    });
  });

  group('16d-3 Reduce Motion', () {
    testWidgets('Reduce Motion 時は AppMotion.of が Duration.zero を返す', (
      tester,
    ) async {
      // Reduce Motion を有効にする。maybeDisableAnimationsOf は
      // MediaQueryData.disableAnimations のみを見る。テストからは
      // MaterialApp.builder で MediaQuery を上書きして設定する。
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            );
          },
          home: const Scaffold(body: _ReduceMotionProbe()),
        ),
      );
      expect(_ReduceMotionProbe.reduceOf(tester), isTrue);
      expect(
        _ReduceMotionProbe.durationOf(tester, AppMotion.medium),
        equals(Duration.zero),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // チップ / セグメントの判断（16d-3）
  // ---------------------------------------------------------------------------
  // M3 の ChoiceChip / SegmentedButton は選択状態の遷移に組み込みの
  // アニメーション（selection overlay のフェード＋スケール）を持つ。
  // 240ms 以内・派手すぎない・Reduce Motion にも従うため、**何もしない**
  // という判断を採用した。ここでは「チップ群に AppMotion トークンを
  // 持ち込んでいないこと」でその判断を固定する。
  group('16d-3 チップ/セグメント', () {
    test('検索ソースチップ: M3 標準の ChoiceChip のまま何も足さない', () {
      final chips = _readSource('lib/screens/home_search_source_chips.dart');
      expect(chips.contains('ChoiceChip('), isTrue);
      expect(
        chips.contains('AppMotion'),
        isFalse,
        reason: 'チップに AppMotion トークンを持ち込んでいない',
      );
    });

    test('コンテンツ種別: M3 標準の SegmentedButton のまま何も足さない', () {
      final selector = _readSource(
        'lib/widgets/home_content_mode_selector.dart',
      );
      expect(selector.contains('SegmentedButton<int>'), isTrue);
      expect(selector.contains('AppMotion'), isFalse);
    });
  });
}

// ---------------------------------------------------------------------------
// ヘルパー: ソース読み込み
// ---------------------------------------------------------------------------

String _readSource(String path) {
  // テスト実行時のカレントディレクトリはパッケージルート。
  return File(path).readAsStringSync();
}

/// [src] 内の [startMarker]（メソッド頭）から、その **本体**（波括弧が
/// 釣り合うまで）を取り出す。hero_motion_test.dart と同じ実装。
String _extractBody(String src, String startMarker) {
  final start = src.indexOf(startMarker);
  expect(start, isNonNegative, reason: 'メソッドが存在する: $startMarker');
  final braceStart = src.indexOf('{', start);
  expect(braceStart, greaterThan(start), reason: '本体の開始波括弧がある');
  var depth = 0;
  for (var i = braceStart; i < src.length; i++) {
    final c = src[i];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  return src.substring(start);
}

// ---------------------------------------------------------------------------
// ヘルパー: BounceBookmarkIcon を駆動するホスト
// ---------------------------------------------------------------------------

class _BounceHost extends StatefulWidget {
  const _BounceHost({required this.bounces});

  /// タップごとに bounce をこの順番で切り替える。
  final List<bool> bounces;

  @override
  State<_BounceHost> createState() => _BounceHostState();
}

class _BounceHostState extends State<_BounceHost> {
  int _step = 0;

  bool get _currentBounce =>
      _step < widget.bounces.length ? widget.bounces[_step] : false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _step++;
        });
      },
      child: BounceBookmarkIcon(isBookmarked: true, bounce: _currentBounce),
    );
  }
}

/// Reduce Motion が効いているときに AppMotion が正しく抑制されるか。
class _ReduceMotionProbe extends StatelessWidget {
  const _ReduceMotionProbe();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }

  static bool reduceOf(WidgetTester tester) {
    final context = tester.element(find.byType(_ReduceMotionProbe));
    return AppMotion.reduce(context);
  }

  static Duration durationOf(WidgetTester tester, Duration d) {
    final context = tester.element(find.byType(_ReduceMotionProbe));
    return AppMotion.of(context, d);
  }
}
