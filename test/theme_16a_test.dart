// Phase 16a: Warm Earthy Neutral パレットの契約テスト。
//
// 1. dark/light 双方で primary/onPrimary, surface/onSurface のコントラスト比が
//    WCAG AA（4.5:1）以上であることを相対輝度から計算で検証。
// 2. CardTheme が elevation 0・半径 20・outlineVariant 枠であること。
// 3. Button / Chip が StadiumBorder（pill）であること。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/theme/app_spacing.dart';
import 'package:pixiv_viewer/theme/app_theme.dart';

/// WCAG 2.x 準拠のコントラスト比を計算する。
double _contrastRatio(Color a, Color b) {
  double lum(Color c) {
    // sRGB → linear
    double chan(double v8) {
      final v = v8 / 255.0;
      return v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4) as double;
    }

    // Color.red/green/blue は 3.47 で非推奨のため .r/.g/.b を使用。
    return 0.2126 * chan((c.r * 255.0).round().toDouble()) +
        0.7152 * chan((c.g * 255.0).round().toDouble()) +
        0.0722 * chan((c.b * 255.0).round().toDouble());
  }

  final la = lum(a) + 0.05;
  final lb = lum(b) + 0.05;
  return la > lb ? la / lb : lb / la;
}

void main() {
  group('16a コントラスト比（WCAG AA >= 4.5）', () {
    final cases = [
      ('dark', AppTheme.darkTheme.colorScheme),
      ('light', AppTheme.lightTheme.colorScheme),
    ];

    for (final (name, scheme) in cases) {
      test('$name: primary/onPrimary', () {
        final r = _contrastRatio(scheme.primary, scheme.onPrimary);
        expect(r, greaterThanOrEqualTo(4.5), reason: '$name $r');
      });

      test('$name: surface/onSurface', () {
        final r = _contrastRatio(scheme.surface, scheme.onSurface);
        expect(r, greaterThanOrEqualTo(4.5), reason: '$name $r');
      });

      test('$name: surface/onSurfaceVariant（補助テキスト）', () {
        final r = _contrastRatio(scheme.surface, scheme.onSurfaceVariant);
        expect(r, greaterThanOrEqualTo(4.5), reason: '$name $r');
      });

      test('$name: primary/onPrimaryContainer', () {
        final r = _contrastRatio(
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
        );
        expect(r, greaterThanOrEqualTo(4.5), reason: '$name $r');
      });

      test('$name: error/onError', () {
        final r = _contrastRatio(scheme.error, scheme.onError);
        expect(r, greaterThanOrEqualTo(4.5), reason: '$name $r');
      });

      test('$name: パレットが旧ピンク系ではない', () {
        // 16a: テラコッタ化の確認。hue が red〜orange帯（<40°）で
        // saturation が低すぎず高すぎない温厚な値であること。
        final hsl = HSLColor.fromColor(scheme.primary);
        expect(hsl.hue, lessThan(40), reason: 'テラコッタ帯（赤〜橙）');
        expect(hsl.hue, greaterThan(5), reason: '完全な赤ではなく橙寄り');
        expect(hsl.saturation, inInclusiveRange(0.2, 0.75), reason: '温厚な彩度');
        expect(scheme.primary, isNot(Colors.pinkAccent));
        expect(scheme.primary, isNot(Colors.blueAccent));
      });

      test('$name: surface は温かい無彩色（hue が 20〜50°・低彩度）', () {
        final hsl = HSLColor.fromColor(scheme.surface);
        // note: #FAF6F1 のように極端に明るい彩時間帯は HSL saturation が
        // 約 0.47 まで跳ね上がる（HSL の既知の振る舞い）。「無彩色寄り」の
        // 実感は RGB 空間の最大/最小チャネル差で判定する。
        final rgbSpread = <int>[
          (scheme.surface.r * 255).round(),
          (scheme.surface.g * 255).round(),
          (scheme.surface.b * 255).round(),
        ];
        final spread = rgbSpread.reduce(math.max) - rgbSpread.reduce(math.min);
        expect(spread, lessThan(30), reason: 'RGB チャネル差が小さい（無彩色寄り）');
        expect(hsl.hue, inInclusiveRange(15, 50), reason: '暖色寄り（黄〜橙）');
      });
    }
  });

  group('16a 形状・部品テーマ', () {
    for (final (name, theme) in [
      ('light', AppTheme.lightTheme),
      ('dark', AppTheme.darkTheme),
    ]) {
      test('$name: CardTheme は elevation 0 + 半径 20 + outlineVariant 枠', () {
        final card = theme.cardTheme;
        expect(card.elevation, 0);
        expect(card.color, theme.colorScheme.surfaceContainer);
        final shape = card.shape;
        expect(shape, isA<RoundedRectangleBorder>());
        final rrb = shape as RoundedRectangleBorder;
        expect(
          rrb.borderRadius,
          BorderRadius.circular(20),
          reason: 'カード半径 20px',
        );
        expect(
          rrb.side.color,
          theme.colorScheme.outlineVariant,
          reason: '枠線は outlineVariant',
        );
        expect(rrb.side.width, 1);
      });

      test('$name: Buttons は StadiumBorder（pill）', () {
        for (final buttonShape in [
          theme.filledButtonTheme.style?.shape?.resolve({}),
          theme.outlinedButtonTheme.style?.shape?.resolve({}),
          theme.textButtonTheme.style?.shape?.resolve({}),
        ]) {
          expect(buttonShape, isA<StadiumBorder>());
        }
      });

      test('$name: ChipTheme は StadiumBorder + surfaceContainerHighest', () {
        expect(theme.chipTheme.shape, isA<StadiumBorder>());
        expect(
          theme.chipTheme.backgroundColor,
          theme.colorScheme.surfaceContainerHighest,
        );
      });

      test('$name: BottomSheet の上辺半径は 28', () {
        final shape = theme.bottomSheetTheme.shape;
        expect(shape, isA<RoundedRectangleBorder>());
        final rrb = shape as RoundedRectangleBorder;
        expect(
          rrb.borderRadius.resolve(TextDirection.ltr).topLeft,
          const Radius.circular(28),
        );
        expect(
          rrb.borderRadius.resolve(TextDirection.ltr).bottomLeft,
          Radius.zero,
        );
      });

      test('$name: InputDecoration は filled・枠線なし・focus 時 primary 1.5px', () {
        final input = theme.inputDecorationTheme;
        expect(input.filled, isTrue);
        expect(input.fillColor, theme.colorScheme.surfaceContainerHighest);
        // 通常時は枠線なし（BorderSide.none は width 0・透明と同義）。
        expect(input.enabledBorder?.borderSide, BorderSide.none);
        // focus 時のみ primary 1.5px。
        expect(
          input.focusedBorder?.borderSide.color,
          theme.colorScheme.primary,
        );
        expect(input.focusedBorder?.borderSide.width, 1.5);
        final fb = input.focusedBorder;
        expect(fb, isA<OutlineInputBorder>());
        expect(
          (fb as OutlineInputBorder).borderRadius,
          BorderRadius.circular(16),
        );
      });

      test('$name: AppBar は surface 背景・elevation 0・左寄せ', () {
        final bar = theme.appBarTheme;
        expect(bar.backgroundColor, theme.colorScheme.surface);
        expect(bar.elevation, 0);
        expect(bar.scrolledUnderElevation, 0);
        expect(bar.centerTitle, isFalse);
        expect(
          bar.titleTextStyle?.fontSize,
          20,
          reason: 'タイトルは titleLarge（20/w600）',
        );
        expect(bar.titleTextStyle?.fontWeight, FontWeight.w600);
      });

      test('$name: PageTransitions は全プラットフォーム Fade-Up', () {
        final builders = theme.pageTransitionsTheme.builders;
        for (final platform in TargetPlatform.values) {
          expect(
            builders[platform],
            isA<FadeUpwardsPageTransitionsBuilder>(),
            reason: '$platform',
          );
        }
      });

      test('$name: TextTheme 統一スケール', () {
        final tt = theme.textTheme;
        expect(tt.headlineMedium?.fontSize, 28);
        expect(tt.headlineMedium?.fontWeight, FontWeight.w600);
        expect(tt.headlineMedium?.letterSpacing, -0.5);
        expect(tt.titleLarge?.fontSize, 20);
        expect(tt.titleLarge?.fontWeight, FontWeight.w600);
        expect(tt.bodyLarge?.fontSize, 15);
        expect(tt.bodyLarge?.height, 1.55);
        expect(tt.bodyMedium?.fontSize, 14);
        expect(tt.bodyMedium?.height, 1.5);
        expect(tt.bodySmall?.fontSize, 13);
      });
    }
  });

  group('16a AppSpacing', () {
    test('定数値', () {
      expect(AppSpacing.xs, 4);
      expect(AppSpacing.sm, 8);
      expect(AppSpacing.md, 12);
      expect(AppSpacing.lg, 16);
      expect(AppSpacing.xl, 20);
      expect(AppSpacing.xxl, 32);
      expect(AppSpacing.screenPadding, 20);
      expect(AppSpacing.cardPadding, 20);
      expect(AppSpacing.sectionGap, 32);
      expect(AppSpacing.minListTileHeight, 64);
    });
  });
}
