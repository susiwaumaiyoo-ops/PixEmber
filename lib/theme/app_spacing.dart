/// スペーシング定数（Phase 16a）。
///
/// 16a では **定義のみ**。画面・ウィジェットが `AppSpacing` を参照する
/// 乗り換えは 16b 以降で行う（それまでは各画面の既存 padding がそのまま動く）。
///
/// 基本ステップは 4px グリッド（xs=4 → xxl=32）。画面外周とカード内側は
/// 20px、セッション間の大きな隙間は 32px で統一する。
class AppSpacing {
  AppSpacing._();

  /// 基本ステップ（4px グリッド）。
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 32;

  /// 画面外周のパディング。
  static const double screenPadding = 20;

  /// カード内側のパディング。
  static const double cardPadding = 20;

  /// セクション間の大きな隙間。
  static const double sectionGap = 32;

  /// ListTile 系の最小高さ（タッチターゲット確保）。
  static const double minListTileHeight = 64;
}
