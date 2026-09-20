import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import 'app_motion.dart';

/// Phase 16d-1: アプリ固有の画面遷移ビルダー。
///
/// [FadeUpwardsPageTransitionsBuilder] を置き換える。違い:
///
/// - **入ってくる画面**: opacity 0→1 ＋ 縦 offset 24px→0 ＋ scale 0.98→1.0。
///   duration = [AppMotion.long] / curve = [AppMotion.emphasized]。
/// - **出ていく画面**: opacity 1→0.92 程度にわずかに沈める（大きく動かさない。
///   「静けさ」のため、背景画面は動かさないのがこのアプリの判断）。
/// - **戻り（pop）**: 逆再生。ただし exit 側は [AppMotion.exit] カーブ。
/// - **Reduce Motion 時**: offset / scale をスキップしフェードのみ。
///   duration は Flutter 側が `disableAnimations` で短縮するのに任せる
///   （`_isReduced` で分岐するが、duration 自体はそのまま渡す）。
///
/// ロジック・データ・API・DB には一切触れない純粋な演出ウィジェット。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  /// 入ってくる画面の縦方向オフセット（px）。
  static const double _enterOffset = 24.0;

  /// 出ていく画面の沈み込み（opacity の下限）。
  static const double _exitOpacity = 0.92;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final isReduced = AppMotion.reduce(context);

    // Reduce Motion: フェードのみ。offset / scale を乗せない。
    if (isReduced) {
      return FadeTransition(opacity: animation, child: child);
    }

    // 入ってくる側: 24px 下から → ふわっと持ち上がりながら拡大して入る。
    final enterOffset = Tween<Offset>(
      begin: const Offset(0, _enterOffset / 100),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: AppMotion.emphasized));

    final enterScale = Tween<double>(
      begin: 0.98,
      end: 1.0,
    ).animate(CurvedAnimation(parent: animation, curve: AppMotion.emphasized));

    // 出ていく側: 大きく動かさず、わずかに不透明度を下げるだけ。
    final exitOpacity = Tween<double>(begin: 1.0, end: _exitOpacity).animate(
      CurvedAnimation(parent: secondaryAnimation, curve: AppMotion.exit),
    );

    return SlideTransition(
      position: enterOffset,
      child: ScaleTransition(
        scale: enterScale,
        child: FadeTransition(
          opacity: animation,
          child: FadeTransition(opacity: exitOpacity, child: child),
        ),
      ),
    );
  }
}
