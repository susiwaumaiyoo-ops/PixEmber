// Phase 16d-1: AppMotion トークンと AppPageTransitionsBuilder の契約テスト。
//
// 検証対象:
// - AppMotion.of が Reduce Motion 時に Duration.zero を返す
// - AppPageTransitionsBuilder が MaterialPageRoute で例外なく動く
// - 遷移中のツリーに Transform / FadeTransition が含まれる
// - disableAnimations: true の配下ではフェードのみ（Slide/Scale が無い）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/theme/app_motion.dart';
import 'package:pixiv_viewer/theme/app_page_transitions.dart';

/// 全プラットフォームを [AppPageTransitionsBuilder] にした ThemeData。
ThemeData _themeWithAppTransitions() {
  const builder = AppPageTransitionsBuilder();
  return ThemeData(
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: builder,
        TargetPlatform.iOS: builder,
        TargetPlatform.macOS: builder,
        TargetPlatform.linux: builder,
        TargetPlatform.windows: builder,
        TargetPlatform.fuchsia: builder,
      },
    ),
  );
}

/// [MaterialApp] の上に「次画面」を push し、遷移途中で止める。
Future<void> _pushNext(WidgetTester tester) async {
  tester
      .element(find.byType(_Placeholder))
      .findAncestorStateOfType<NavigatorState>()!
      .pushNamed('next');
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  group('AppMotion トークン（16d-1）', () {
    test('Duration は 160 / 240 / 320ms', () {
      expect(AppMotion.short, const Duration(milliseconds: 160));
      expect(AppMotion.medium, const Duration(milliseconds: 240));
      expect(AppMotion.long, const Duration(milliseconds: 320));
    });

    test('Duration は全て 400ms 以下（禁止事項の境界）', () {
      expect(AppMotion.short.inMilliseconds, lessThanOrEqualTo(400));
      expect(AppMotion.medium.inMilliseconds, lessThanOrEqualTo(400));
      expect(AppMotion.long.inMilliseconds, lessThanOrEqualTo(400));
    });

    test('enter は減速・exit は加速・emphasized は M3 値', () {
      expect(AppMotion.enter, Curves.easeOutCubic);
      expect(AppMotion.exit, Curves.easeInCubic);
      expect(AppMotion.emphasized, const Cubic(0.05, 0.7, 0.1, 1.0));
    });

    testWidgets('reduce は未指定なら false（MediaQuery 無しでも安全）', (tester) async {
      // MediaQuery を被せない素の context でも maybeDisableAnimationsOf は
      // null を返すので false に倒れる（テスト以外では起こらないが安全策）。
      late BuildContext captured;
      await tester.pumpWidget(
        Builder(
          builder: (ctx) {
            captured = ctx;
            return const SizedBox.shrink();
          },
        ),
      );
      expect(AppMotion.reduce(captured), isFalse);
      expect(AppMotion.of(captured, AppMotion.long), AppMotion.long);
    });

    testWidgets('reduce が true のとき of は Duration.zero を返す', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(AppMotion.reduce(captured), isTrue);
      expect(AppMotion.of(captured, AppMotion.long), Duration.zero);
      expect(AppMotion.of(captured, AppMotion.short), Duration.zero);
    });

    testWidgets('reduce が false のとき of はそのまま返す', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(AppMotion.reduce(captured), isFalse);
      expect(AppMotion.of(captured, AppMotion.medium), AppMotion.medium);
    });
  });

  group('AppPageTransitionsBuilder（16d-1）', () {
    testWidgets('MaterialPageRoute で例外なく遷移できる', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _themeWithAppTransitions(),
          home: const _Placeholder(title: 'root'),
          onGenerateRoute: (settings) {
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const _Placeholder(title: 'pushed'),
            );
          },
        ),
      );
      expect(find.text('root'), findsOneWidget);

      tester
          .element(find.byType(_Placeholder))
          .findAncestorStateOfType<NavigatorState>()!
          .pushNamed('next');
      await tester.pumpAndSettle();
      expect(find.text('pushed'), findsOneWidget);
      expect(find.text('root'), findsNothing);
    });

    testWidgets('遷移中のツリーに Transform と FadeTransition が含まれる', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _themeWithAppTransitions(),
          home: const _Placeholder(title: 'root'),
          onGenerateRoute: (settings) {
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const _Placeholder(title: 'pushed'),
            );
          },
        ),
      );
      await _pushNext(tester);

      expect(
        find.byType(Transform),
        findsWidgets,
        reason: 'Slide/Scale が Transform を生成する',
      );
      expect(find.byType(FadeTransition), findsWidgets);
      expect(find.byType(SlideTransition), findsOneWidget);
      expect(find.byType(ScaleTransition), findsOneWidget);
    });

    testWidgets('disableAnimations 配下では Slide/Scale が適用されない', (tester) async {
      // Reduce Motion 時はフェードのみ。Slide/Scale が出現しないことを検証する。
      // MaterialApp.builder で既存の MediaQuery に disableAnimations を上書きする
      // （WidgetsApp は View 経由で MediaQuery を作るので、 MaterialApp の外に
      //  MediaQuery を置いても上書きされてしまう。builder は Navigator より
      //  内側で確実に伝わる）。
      await tester.pumpWidget(
        MaterialApp(
          theme: _themeWithAppTransitions(),
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            );
          },
          home: const _Placeholder(title: 'root'),
          onGenerateRoute: (settings) {
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const _Placeholder(title: 'pushed'),
            );
          },
        ),
      );
      await _pushNext(tester);

      // フェードは FadeTransition だけで Slide/Scale は出ない。
      expect(find.byType(FadeTransition), findsWidgets);
      expect(
        find.byType(SlideTransition),
        findsNothing,
        reason: 'Reduce Motion 時は Slide をスキップする',
      );
      expect(
        find.byType(ScaleTransition),
        findsNothing,
        reason: 'Reduce Motion 時は Scale をスキップする',
      );
    });
  });
}

// Scaffold を使わない: Scaffold の FAB デフォルト演出が
// ScaleTransition/Transform を出し、遷移検証のノイズになる。
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF000000),
      child: Center(child: Text(title)),
    );
  }
}
