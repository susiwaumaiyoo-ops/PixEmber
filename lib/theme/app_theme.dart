import 'package:flutter/material.dart';

/// デザインシステム基盤（Phase 11b → 16a 刷新）。
///
/// ライト/ダーク両方の [ThemeData] を提供する。main.dart の MaterialApp が
/// [lightTheme] / [darkTheme] を設定し、[ThemeService] の mode で切り替わる。
///
/// 各画面は原則 `Theme.of(context).colorScheme` / `textTheme` を参照し、
/// 直接色をハードコードしない。
///
/// ## 16a: Warm Earthy Neutral
/// 「純黒＋ピンク」から「温かい無彩色＋テラコッタ」へ差し替え。
/// 画面側のコードは一切触らず、このファイルだけでアプリ全体の雰囲気を変える。
/// （各画面は Phase 12〜14 でトークン参照化済み）
class AppTheme {
  AppTheme._();

  // ==========================================================================
  // Dark ColorScheme（人間指定値 + 導出値）
  // ==========================================================================

  /// ダークカラースキーム。
  ///
  /// 指定値は温かい無彩色のサーフェス群 + テラコッタ/セージ/黄土のアクセント。
  /// container 系は「各色を surface 側に 75% 混ぜた低彩度の面色」を
  /// `Color.lerp(color, surface, 0.75)` 相当で手計算して固定値化している。
  static const ColorScheme _darkScheme = ColorScheme(
    brightness: Brightness.dark,

    // --- サーフェス群（指定値）---
    surface: Color(0xFF1A1714),
    surfaceContainer: Color(0xFF241F1B),
    surfaceContainerHigh: Color(0xFF2E2823),
    surfaceContainerHighest: Color(0xFF3A322C),
    onSurface: Color(0xFFF3ECE4),
    onSurfaceVariant: Color(0xFFB5A899),
    outlineVariant: Color(0xFF4A413A),

    // --- 導出: surfaceDim/Bright ---
    // surfaceDim は surface を 0.95 倍（わずかに暗く）。
    // 0x1A*0.95=24.7→25(0x19), 0x17*0.95=22.8→23(0x17), 0x14*0.95=19→19(0x13)
    surfaceDim: Color(0xFF191713),
    // surfaceBright は surface を 1.15 倍（わずかに明るく）。
    // 0x1A*1.15=29.9→30(0x1E), 0x17*1.15=26.4→26(0x1A), 0x14*1.15=23→23(0x17)
    surfaceBright: Color(0xFF1E1A17),

    // --- 導出: outline（outlineVariant を 1.25 倍で明るく）---
    // 0x4A*1.25=92.5→93(0x5D), 0x41*1.25=81.25→81(0x51), 0x3A*1.25=72.5→73(0x49)
    outline: Color(0xFF5D5149),

    // --- アクセント（指定値）---
    primary: Color(0xFFD9865A),
    onPrimary: Color(0xFF2A1408),
    secondary: Color(0xFF9BA88A),
    onSecondary: Color(0xFF1C2216),
    tertiary: Color(0xFFD4A759),
    onTertiary: Color(0xFF2A1F06),
    error: Color(0xFFE07A6A),
    onError: Color(0xFF2A0E0A),

    // --- 導出: container 群（各色を surface 側に 75% 混合）---
    // primaryContainer: lerp(#D9865A, #1A1714, 0.75)
    //   R:217-0.75*(217-26)=73.8→74(0x4A), G:134-0.75*(134-23)=50.8→51(0x33),
    //   B:90-0.75*(90-20)=37.5→38(0x26)
    primaryContainer: Color(0xFF4A3326),
    // secondaryContainer: lerp(#9BA88A, #1A1714, 0.75)
    //   R:155-0.75*129=58.3→58(0x3A), G:168-0.75*145=59.3→59(0x3B),
    //   B:138-0.75*118=49.5→50(0x32)
    secondaryContainer: Color(0xFF3A3B32),
    // tertiaryContainer: lerp(#D4A759, #1A1714, 0.75)
    //   R:212-0.75*186=72.5→73(0x49), G:167-0.75*144=59→59(0x3B),
    //   B:89-0.75*69=37.3→37(0x25)
    tertiaryContainer: Color(0xFF493B25),
    // errorContainer: lerp(#E07A6A, #1A1714, 0.75)
    //   R:224-0.75*198=75.5→76(0x4C), G:122-0.75*99=47.8→48(0x30),
    //   B:106-0.75*86=41.5→42(0x2A)
    errorContainer: Color(0xFF4C302A),

    // --- 導出: on*Container（各アクセントを明るい方向へ。
    //     暗い面色の上で可読な明色。アクセント色を ~15% 明るくした同系色）---
    onPrimaryContainer: Color(0xFFF5DAC9),
    onSecondaryContainer: Color(0xFFD8E2CB),
    onTertiaryContainer: Color(0xFFF0DCA9),
    onErrorContainer: Color(0xFFF5C6BD),

    // --- 導出: inverse / shadow / scrim / tint ---
    // 反転は surface ↔ onSurface をそのまま入れ替える。
    inverseSurface: Color(0xFFF3ECE4),
    onInverseSurface: Color(0xFF1A1714),
    // inversePrimary は light 側の primary（テラコッタの深い方）。
    inversePrimary: Color(0xFFB8613C),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    // M3 標準: surfaceTint は primary と同色。
    surfaceTint: Color(0xFFD9865A),
  );

  // ==========================================================================
  // Light ColorScheme（人間指定値 + 導出値）
  // ==========================================================================

  /// ライトカラースキーム。
  static const ColorScheme _lightScheme = ColorScheme(
    brightness: Brightness.light,

    // --- サーフェス群（指定値）---
    surface: Color(0xFFFAF6F1),
    surfaceContainer: Color(0xFFF2ECE4),
    surfaceContainerHigh: Color(0xFFEAE2D8),
    surfaceContainerHighest: Color(0xFFE0D6CA),
    onSurface: Color(0xFF2A2420),
    onSurfaceVariant: Color(0xFF6E6259),
    outlineVariant: Color(0xFFD6CCC0),

    // --- 導出: surfaceDim/Bright ---
    // surfaceDim は surface を 0.95 倍。
    // 0xFA*0.95=237.5→238(0xEE), 0xF6*0.95=233.7→234(0xEA), 0xF1*0.95=229→229(0xE5)
    surfaceDim: Color(0xFFEEEAE5),
    // surfaceBright は surface を 1.05 倍（上限 255）。
    // 0xFA*1.05=262.5→255, 0xF6*1.05=258.3→255, 0xF1*1.05=253.05→253(0xFD)
    surfaceBright: Color(0xFFFFFDFA),

    // --- 導出: outline（outlineVariant を 0.85 倍で濃く）---
    // 0xD6*0.85=181.9→182(0xB6), 0xCC*0.85=173.4→173(0xAD), 0xC0*0.85=163.2→163(0xA3)
    outline: Color(0xFFB6ADA3),

    // --- アクセント（指定値）---
    primary: Color(0xFFA8562F),
    onPrimary: Color(0xFFFFFFFF),
    secondary: Color(0xFF6F7C5C),
    onSecondary: Color(0xFFFFFFFF),
    tertiary: Color(0xFFA6782E),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFB3402F),
    onError: Color(0xFFFFFFFF),

    // --- 導出: container 群（各色を surface 側に 75% 混合）---
    // primaryContainer: lerp(#A8562F, #FAF6F1, 0.75)
    //   R:168+0.75*87=233.3→233(0xE9), G:86+0.75*165=209.8→210(0xD2),
    //   B:47+0.75*199=196.3→196(0xC4)
    primaryContainer: Color(0xFFE9D2C4),
    // secondaryContainer: lerp(#6F7C5C, #FAF6F1, 0.75)
    //   R:111+0.75*139=215.3→215(0xD7), G:124+0.75*122=215.5→216(0xD8),
    //   B:92+0.75*149=203.8→204(0xCC)
    secondaryContainer: Color(0xFFD7D8CC),
    // tertiaryContainer: lerp(#A6782E, #FAF6F1, 0.75)
    //   R:166+0.75*84=229→229(0xE5), G:120+0.75*126=214.5→215(0xD7),
    //   B:46+0.75*195=192.3→192(0xC0)
    tertiaryContainer: Color(0xFFE5D7C0),
    // errorContainer: lerp(#B3402F, #FAF6F1, 0.75)
    //   R:179+0.75*71=232.3→232(0xE8), G:64+0.75*182=200.5→201(0xC9),
    //   B:47+0.75*194=192.5→193(0xC1)
    errorContainer: Color(0xFFE8C9C1),

    // --- 導出: on*Container（各アクセントを 25% 暗く。
    //     明るい面色の上で可読な濃色）---
    // onPrimaryContainer: #A8562F*0.75 → 126(0x7E), 64.5→65(0x41), 35.3→35(0x23)
    onPrimaryContainer: Color(0xFF7E4123),
    // onSecondaryContainer: #6F7C5C*0.75 → 83.3→83(0x53), 93→93(0x5D), 69→69(0x45)
    onSecondaryContainer: Color(0xFF535D45),
    // onTertiaryContainer: #A6782E*0.68 → 113(0x71), 82(0x52), 31(0x1F)
    //   ※ 16b-2d: 0.75 倍（#7D5A23）だと tertiaryContainer とのコントラスト比が
    //     4.41 となり WCAG AA(4.5) を下回る。0.68 倍まで濃くして 5.06 を確保。
    //     warning バナー（AppStatusBanner）の本文色として使用。
    onTertiaryContainer: Color(0xFF71521F),
    // onErrorContainer: #B3402F*0.75 → 134.3→134(0x86), 48→48(0x30), 35.3→35(0x23)
    onErrorContainer: Color(0xFF863023),

    // --- 導出: inverse / shadow / scrim / tint ---
    inverseSurface: Color(0xFF2A2420),
    onInverseSurface: Color(0xFFFAF6F1),
    // inversePrimary は dark 偭の primary（テラコッタの明るい方）。
    inversePrimary: Color(0xFFD9865A),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    surfaceTint: Color(0xFFA8562F),
  );

  // ==========================================================================
  // Typography（16a: 統一タイポグラフィスケール）
  // ==========================================================================
  //
  // color は指定せず ThemeData 側で colorScheme.onSurface を当てる
  // （ThemeData が defaultTextTheme との merge で補完する）。
  // fontFamily は 16a では既定フォントのまま（フォント追加は別フェーズ）。
  static const TextTheme _textTheme = TextTheme(
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.5,
    ),
    titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 15, height: 1.55),
    bodyMedium: TextStyle(fontSize: 14, height: 1.5),
    bodySmall: TextStyle(fontSize: 13),
  );

  // ==========================================================================
  // Shape / 部品テーマ
  // ==========================================================================

  static const double _cardRadius = 20;
  static const double _sheetTopRadius = 28;
  static const double _fieldRadius = 16;

  /// ライトテーマ。
  static ThemeData get lightTheme => _build(_lightScheme);

  /// ダークテーマ。
  static ThemeData get darkTheme => _build(_darkScheme);

  static ThemeData _build(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: _textTheme,

      // --- AppBar: 背面は surface・フラット・左寄せ ---
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: _textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
        ),
      ),

      // --- Card: フラット（elevation 0）+ outlineVariant の細枠 + 20px ---
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_cardRadius),
          side: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),

      // --- BottomSheet: 上辺だけ 28px ---
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(_sheetTopRadius),
          ),
        ),
      ),

      // --- Buttons: すべて pill（StadiumBorder）---
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: const StadiumBorder()),
      ),

      // --- Chip: pill・背景 surfaceContainerHighest・選択時 primary 15% 面 ---
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        backgroundColor: scheme.surfaceContainerHighest,
        side: BorderSide(color: scheme.outlineVariant, width: 1),
        labelStyle: _textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
        selectedColor: _mixPrimarySurface(scheme, 0.15),
        checkmarkColor: scheme.primary,
      ),

      // --- Input: filled・枠線なし・focus 時のみ primary 1.5px ---
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        hintStyle: _textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),

      // --- Motion: 全プラットフォーム Fade-Up で統一 ---
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),

      // --- 分割線・スナックバー等の補助色 ---
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark
            ? scheme.surfaceContainerHigh
            : scheme.onSurface,
        contentTextStyle: _textTheme.bodyMedium?.copyWith(
          color: isDark ? scheme.onSurface : scheme.surface,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
    );
  }

  /// primary と surface の混色（選択 chip の 15% 面など）。
  ///
  /// 16a では chip の selectedColor のみで使用。`Color.lerp` は const で
  /// 扱えないため、16a の固定レシオ（t=0.15）を手計算してコンパイル時に
  /// 解決するのではなく、実行時に 1 回だけ計算してキャッシュする。
  static Color _mixPrimarySurface(ColorScheme scheme, double t) {
    return Color.lerp(scheme.primary, scheme.surface, t)!;
  }
}
