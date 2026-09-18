import 'package:flutter/material.dart';

/// デザインシステム基盤（Phase 11b）。
///
/// ライト/ダーク両方の [ThemeData] を提供する。main.dart の MaterialApp が
/// [lightTheme] / [darkTheme] を設定し、[ThemeService] の mode で切り替わる。
///
/// 各画面は原則 `Theme.of(context).colorScheme` / `textTheme` を参照し、
/// 直接色をハードコードしない（レポート §2 / §7-3 の課題）。
class AppTheme {
  AppTheme._();

  /// デザイントーンのシードカラー（既存アプリと同じピンクアクセント）。
  static const Color seedColor = Colors.pinkAccent;

  /// ライトテーマ。
  ///
  /// `ColorScheme.fromSeed` のセマンティックカラーを活用し、
  /// ダーク前提でハードコードされていた `Colors.white38` 等が
  /// ライトモードで不可視になる問題（レポート §7-3）を防ぐ下地となる。
  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    );
    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      useMaterial3: true,
      cardTheme: CardThemeData(color: colorScheme.surfaceContainer),
    );
  }

  /// ダークテーマ（main.dart にハードコードされていた定義を移植）。
  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
      surface: const Color(0xFF121212),
    );
    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFF121212),
      useMaterial3: true,
      cardTheme: const CardThemeData(color: Color(0xFF1E1E1E)),
    );
  }
}
