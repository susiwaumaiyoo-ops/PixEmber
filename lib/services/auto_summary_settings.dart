// Phase 9-B: バックグラウンド自動要約の設定（永続化モデル）。
//
// SharedPreferences に保存する不変スナップショット。UI はこのモデルを
// `copyWith` で更新し `save()` で永続化する。既定値は安全側:
//  - enabled 既定 false（ユーザーの明示操作なしで自動で有効化しない）
//  - chargeOnly / wifiOnly 既定 true（バッテリー駆動時の自動実行を避ける）
import 'package:shared_preferences/shared_preferences.dart';

/// 自動要約の実行条件・巡回設定。
class AutoSummarySettings {
  const AutoSummarySettings({
    this.enabled = false,
    this.tags = const [],
    this.chargeOnly = true,
    this.wifiOnly = true,
    this.maxPerSession = defaultMaxPerSession,
    this.cooldownSeconds = defaultCooldownSeconds,
    this.temperatureLimitCelsius = defaultTemperatureLimitCelsius,
    this.keepScreenOn = true,
    this.lastRunAtMillis = 0,
    this.totalProcessed = 0,
  });

  // ---- 永続化キー ----
  static const String keyEnabled = 'auto_summary_enabled';
  static const String keyTags = 'auto_summary_tags';
  static const String keyChargeOnly = 'auto_summary_charge_only';
  static const String keyWifiOnly = 'auto_summary_wifi_only';
  static const String keyMaxPerSession = 'auto_summary_max_per_session';
  static const String keyCooldown = 'auto_summary_cooldown_seconds';
  static const String keyTempLimit = 'auto_summary_temp_limit';
  static const String keyKeepScreenOn = 'auto_summary_keep_screen_on';
  static const String keyLastRunAt = 'auto_summary_last_run_at';
  static const String keyTotalProcessed = 'auto_summary_total_processed';

  // ---- 既定値 ----
  static const int defaultMaxPerSession = 20;
  static const int defaultCooldownSeconds = 15;
  static const double defaultTemperatureLimitCelsius = 42.0;
  static const List<int> maxChoices = [5, 10, 20, 50, 100];
  static const List<int> cooldownChoices = [5, 10, 15, 30, 60];
  static const List<double> tempChoices = [38, 40, 42, 45];

  /// 自動要約を有効にするか（既定 false）。ユーザーの明示操作でのみ true になる。
  final bool enabled;

  /// 対象タグリスト（ラウンドロビンで巡回）。
  final List<String> tags;

  /// 充電中のみ実行（既定 true・強く推奨）。
  final bool chargeOnly;

  /// WiFi接続時のみ実行（既定 true）。
  final bool wifiOnly;

  /// 1セッションあたりの最大件数（既定 20）。
  final int maxPerSession;

  /// 作品間のクールダウン秒数（既定 15、端末冷却）。
  final int cooldownSeconds;

  /// 温度閾値（℃）。超過で自動一時停止（既定 42）。
  final double temperatureLimitCelsius;

  /// 推論中 KeepScreenOn を有効にするか。
  /// true=画面ON維持（高速・バッテリー消費大）
  /// false=画面OFF許可（省電力・速度低下あり）
  final bool keepScreenOn;

  /// 最終実行日時（epoch millis、0=未実行）。
  final int lastRunAtMillis;

  /// 累計処理済み件数。
  final int totalProcessed;

  /// 実行可能な条件が揃っているか（タグが1つ以上）。
  bool get canRun => enabled && tags.isNotEmpty;

  AutoSummarySettings copyWith({
    bool? enabled,
    List<String>? tags,
    bool? chargeOnly,
    bool? wifiOnly,
    int? maxPerSession,
    int? cooldownSeconds,
    double? temperatureLimitCelsius,
    bool? keepScreenOn,
    int? lastRunAtMillis,
    int? totalProcessed,
  }) {
    return AutoSummarySettings(
      enabled: enabled ?? this.enabled,
      tags: tags ?? this.tags,
      chargeOnly: chargeOnly ?? this.chargeOnly,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      maxPerSession: maxPerSession ?? this.maxPerSession,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
      temperatureLimitCelsius:
          temperatureLimitCelsius ?? this.temperatureLimitCelsius,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      lastRunAtMillis: lastRunAtMillis ?? this.lastRunAtMillis,
      totalProcessed: totalProcessed ?? this.totalProcessed,
    );
  }

  /// 保存された設定を読む（不正値・未登録は既定に戻す）。
  static Future<AutoSummarySettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawTags = prefs.getStringList(keyTags) ?? const <String>[];
      final tags = rawTags.map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
      final max = prefs.getInt(keyMaxPerSession) ?? defaultMaxPerSession;
      final cd = prefs.getInt(keyCooldown) ?? defaultCooldownSeconds;
      final temp = double.tryParse(prefs.getString(keyTempLimit) ?? '') ??
          defaultTemperatureLimitCelsius;
      return AutoSummarySettings(
        enabled: prefs.getBool(keyEnabled) ?? false,
        tags: tags,
        chargeOnly: prefs.getBool(keyChargeOnly) ?? true,
        wifiOnly: prefs.getBool(keyWifiOnly) ?? true,
        maxPerSession: maxChoices.contains(max) ? max : defaultMaxPerSession,
        cooldownSeconds:
            cooldownChoices.contains(cd) ? cd : defaultCooldownSeconds,
        temperatureLimitCelsius: temp,
        keepScreenOn: prefs.getBool(keyKeepScreenOn) ?? true,
        lastRunAtMillis: prefs.getInt(keyLastRunAt) ?? 0,
        totalProcessed: prefs.getInt(keyTotalProcessed) ?? 0,
      );
    } catch (_) {
      return const AutoSummarySettings();
    }
  }

  /// 現在の設定を SharedPreferences に保存する。
  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyEnabled, enabled);
      await prefs.setStringList(keyTags, tags);
      await prefs.setBool(keyChargeOnly, chargeOnly);
      await prefs.setBool(keyWifiOnly, wifiOnly);
      await prefs.setInt(keyMaxPerSession, maxPerSession);
      await prefs.setInt(keyCooldown, cooldownSeconds);
      await prefs.setString(keyTempLimit, '$temperatureLimitCelsius');
      await prefs.setBool(keyKeepScreenOn, keepScreenOn);
      await prefs.setInt(keyLastRunAt, lastRunAtMillis);
      await prefs.setInt(keyTotalProcessed, totalProcessed);
    } catch (_) {
      // 保存失敗は握りつぶす（次回ロードで既定に戻る）。
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AutoSummarySettings &&
      other.enabled == enabled &&
      other.chargeOnly == chargeOnly &&
      other.wifiOnly == wifiOnly &&
      other.maxPerSession == maxPerSession &&
      other.cooldownSeconds == cooldownSeconds &&
      other.temperatureLimitCelsius == temperatureLimitCelsius &&
      other.keepScreenOn == keepScreenOn &&
      other.lastRunAtMillis == lastRunAtMillis &&
      other.totalProcessed == totalProcessed &&
      _listEquals(other.tags, tags);

  @override
  int get hashCode => Object.hash(
        enabled,
        chargeOnly,
        wifiOnly,
        maxPerSession,
        cooldownSeconds,
        temperatureLimitCelsius,
        keepScreenOn,
        lastRunAtMillis,
        totalProcessed,
        Object.hashAll(tags),
      );

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
