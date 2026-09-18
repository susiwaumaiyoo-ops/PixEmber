import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// アプリ全体のテーマモード（System / Light / Dark）を管理するシングルトン（Phase 11a）。
///
/// 状態管理パッケージは導入せず、既存アーキテクチャ（シングルトン + ValueNotifier）に合わせる。
/// [themeModeNotifier] を main.dart の ValueListenableBuilder がリッスンし、
/// MaterialApp の themeMode に反映する。
class ThemeService {
  ThemeService._internal();

  static final ThemeService _instance = ThemeService._internal();

  factory ThemeService() => _instance;

  /// SharedPreferences に保存するテーマモードのキー。
  static const String prefKey = 'app_theme_mode';

  final ValueNotifier<ThemeMode> _themeModeNotifier = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );

  /// テーマモードの変更をリッスン可能な ValueNotifier。
  ValueNotifier<ThemeMode> get themeModeNotifier => _themeModeNotifier;

  /// 現在のテーマモード。
  ThemeMode get themeMode => _themeModeNotifier.value;

  /// SharedPreferences から保存済みのテーマモードを読み込む。
  ///
  /// main() で runApp 前に一度だけ呼ぶ（初帧からテーマが反映される）。
  /// 不正な値が保存されていた場合は [ThemeMode.system] にフォールバックする。
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _themeModeNotifier.value = parseMode(prefs.getString(prefKey));
    } catch (e) {
      debugPrint('[ThemeService] テーマ設定の読み込みに失敗しました: $e');
    }
  }

  /// テーマモードを変更して永続化する。
  Future<void> setMode(ThemeMode mode) async {
    if (_themeModeNotifier.value == mode) return;
    _themeModeNotifier.value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKey, modeToKey(mode));
    } catch (e) {
      debugPrint('[ThemeService] テーマ設定の保存に失敗しました: $e');
    }
  }

  /// [ThemeMode] を SharedPreferences 保存用の文字列に変換する。
  static String modeToKey(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'system';
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
    }
  }

  /// SharedPreferences 保存用文字列から [ThemeMode] に変換する。
  /// null・空・不正値は [ThemeMode.system] になる。
  static ThemeMode parseMode(String? key) {
    switch (key) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  /// テスト用: シングルトンの状態を初期値（system）に戻す。
  @visibleForTesting
  void resetForTesting() {
    _themeModeNotifier.value = ThemeMode.system;
  }
}
