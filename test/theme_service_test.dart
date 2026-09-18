// Phase 11a: ThemeService（テーマモードの永続化と ValueNotifier 通知）の単体テスト。
// 外部通信なし。SharedPreferences の Mock を使用する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_viewer/services/theme_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeService().resetForTesting();
  });

  group('初期状態', () {
    test('デフォルトは ThemeMode.system', () {
      expect(ThemeService().themeMode, ThemeMode.system);
    });

    test('シングルトンである（複数の生成が同一インスタンスを返す）', () {
      expect(identical(ThemeService(), ThemeService()), isTrue);
    });

    test('themeModeNotifier が初期値を通知する', () {
      expect(ThemeService().themeModeNotifier.value, ThemeMode.system);
    });
  });

  group('init（読み込み）', () {
    test('light を読み込む', () async {
      SharedPreferences.setMockInitialValues({ThemeService.prefKey: 'light'});
      await ThemeService().init();
      expect(ThemeService().themeMode, ThemeMode.light);
    });

    test('dark を読み込む', () async {
      SharedPreferences.setMockInitialValues({ThemeService.prefKey: 'dark'});
      await ThemeService().init();
      expect(ThemeService().themeMode, ThemeMode.dark);
    });

    test('system を読み込む', () async {
      SharedPreferences.setMockInitialValues({ThemeService.prefKey: 'system'});
      await ThemeService().init();
      expect(ThemeService().themeMode, ThemeMode.system);
    });

    test('キーがない場合は system にフォールバックする', () async {
      await ThemeService().init();
      expect(ThemeService().themeMode, ThemeMode.system);
    });

    test('不正な値は system にフォールバックする', () async {
      SharedPreferences.setMockInitialValues({ThemeService.prefKey: 'olive'});
      await ThemeService().init();
      expect(ThemeService().themeMode, ThemeMode.system);
    });
  });

  group('setMode（書き込み）', () {
    test('dark を保存して通知する', () async {
      await ThemeService().setMode(ThemeMode.dark);
      expect(ThemeService().themeMode, ThemeMode.dark);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ThemeService.prefKey), 'dark');
    });

    test('light を保存して通知する', () async {
      await ThemeService().setMode(ThemeMode.light);
      expect(ThemeService().themeMode, ThemeMode.light);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ThemeService.prefKey), 'light');
    });

    test('system を保存して通知する', () async {
      await ThemeService().setMode(ThemeMode.dark);
      await ThemeService().setMode(ThemeMode.system);
      expect(ThemeService().themeMode, ThemeMode.system);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ThemeService.prefKey), 'system');
    });

    test('同じ値の再設定では通知しない', () async {
      var notifications = 0;
      ThemeService().themeModeNotifier.addListener(() => notifications++);
      await ThemeService().setMode(ThemeMode.system);
      expect(notifications, 0);
    });

    test('notifier が変更をリスナーへ通知する', () async {
      ThemeMode? observed;
      ThemeService().themeModeNotifier.addListener(() {
        observed = ThemeService().themeMode;
      });
      await ThemeService().setMode(ThemeMode.light);
      expect(observed, ThemeMode.light);
    });
  });

  group('変換ヘルパー', () {
    test('modeToKey が双方向に変換できる', () {
      expect(ThemeService.modeToKey(ThemeMode.system), 'system');
      expect(ThemeService.modeToKey(ThemeMode.light), 'light');
      expect(ThemeService.modeToKey(ThemeMode.dark), 'dark');
      expect(ThemeService.parseMode('system'), ThemeMode.system);
      expect(ThemeService.parseMode('light'), ThemeMode.light);
      expect(ThemeService.parseMode('dark'), ThemeMode.dark);
    });

    test('parseMode が null・空・不正値を system にする', () {
      expect(ThemeService.parseMode(null), ThemeMode.system);
      expect(ThemeService.parseMode(''), ThemeMode.system);
      expect(ThemeService.parseMode('unknown'), ThemeMode.system);
    });
  });
}
