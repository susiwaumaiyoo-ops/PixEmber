/// 日時フォーマットの共通ユーティリティ。
///
/// 日本ロケール前提で、ISO 8601 などの文字列を人間が読みやすい形式に変換する。
/// イラスト詳細・小説詳細・履歴等で共通利用する。
class DateTimeFormat {
  const DateTimeFormat._();

  /// ISO 8601 などの文字列を "2026/07/08 19:04" 形式に変換する。
  /// 解析できない場合は元の文字列をそのまま返す。
  static String formatReadable(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = _tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    final y = local.year.toString();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y/$m/$d $hh:$mm';
  }

  /// ISO 8601 などの文字列を "2026年7月8日 19:04" 形式に変換する。
  static String formatJapanese(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = _tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    return '${local.year}年${local.month}月${local.day}日 '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  static DateTime? _tryParse(String iso) {
    try {
      return DateTime.parse(iso);
    } catch (_) {
      return null;
    }
  }
}
