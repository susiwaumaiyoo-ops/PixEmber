import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

/// Phase 16d-1: アプリ固有の画面遷移ビルダー。
///
/// 17f: 実機フィードバック「遷移が少し重い」を受けて**シンプルなクロスフェード**
/// に変更した。16d-1 の縦 offset + scale + フェードの複合演出はやめた。
///
/// - **入ってくる画面**: opacity 0→1。duration = [AppMotion.medium]（240ms）。
/// - **出ていく画面**: opacity 1→0。背景画面も同じ速度でフェードアウトする。
/// - **戻り（pop）**: 逆再生。
/// - **Reduce Motion 時**: 同じフェードのみを維持（元々フェードだけなので
///   分岐が不要になった）。duration は Flutter 側が `disableAnimations` で
///   短縮するのに任せる。
///
/// ロジック・データ・API・DB には一切触れない純粋な演出ウィジェット。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 17f: クロスフェードのみ。Slide / Scale / offset は使わない。
    // 入ってくる画面と出ていく画面をそれぞれフェードで重ねる。
    return FadeTransition(
      opacity: animation,
      child: FadeTransition(
        opacity: ReverseAnimation(secondaryAnimation),
        child: child,
      ),
    );
  }
}
