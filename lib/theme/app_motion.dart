import 'package:flutter/material.dart';

/// モーションデザイントークン（Phase 16d-1）。
///
/// PixEmber の「動き」を 1 箇所で定義する。原則:
///
/// - 静かで短い（160〜320ms）。派手さより「気持ちよさ」
/// - 減速カーブ（easeOutCubic / emphasizedDecelerate 系）を基本
/// - 横移動より縦・フェード・わずかな拡縮
/// - **OS の Reduce Motion 設定を尊重**（全演出を一括で無効化できる）
///
/// 値は 16d 開始時点の仮説。実機で調整する前提だが、
/// **Sub の中で勝手に変えない**（変える場合は一旦停止して報告する）。
class AppMotion {
  AppMotion._();

  // ==========================================================================
  // Duration
  // ==========================================================================

  /// 応答・チップ（160ms）。
  static const short = Duration(milliseconds: 160);

  /// 遷移・登場（240ms）。
  static const medium = Duration(milliseconds: 240);

  /// 詳細へ入る・完了（320ms）。
  ///
  /// これより長い演出は Phase 16d では認めない（禁止事項）。
  static const long = Duration(milliseconds: 320);

  // ==========================================================================
  // Curve
  // ==========================================================================

  /// 入ってくるとき（減速）。
  static const enter = Curves.easeOutCubic;

  /// 出ていくとき（加速）。
  static const exit = Curves.easeInCubic;

  /// M3 の emphasizedDecelerate に相当する強調減速カーブ。
  ///
  /// 詳細画面への进入など、ひと際目立たせたい減速に使う。
  /// M3 の値（0.05, 0.7, 0.1, 1.0）をそのまま持ってきた。
  static const emphasized = Cubic(0.05, 0.7, 0.1, 1.0);

  // ==========================================================================
  // Reduce Motion
  // ==========================================================================

  /// OS の「アニメーションを減らす」が有効か。
  ///
  /// [MediaQuery.maybeDisableAnimationsOf] は [MediaQuery] が無い
  /// （テストで context が素の場合など）は null を返すので false に倒す。
  static bool reduce(BuildContext context) {
    return MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  /// [d] を Reduce Motion 考慮で返す。
  ///
  /// Reduce Motion の場合は [Duration.zero] になり、
  /// 呼び出し側は「アニメーションしない」のと同じ挙動になる。
  static Duration of(BuildContext context, Duration d) {
    return reduce(context) ? Duration.zero : d;
  }
}
