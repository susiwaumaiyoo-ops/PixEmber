import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../theme/app_motion.dart';

/// 完了演出: 円が 0 -> 1 に強調カーブで広がり、遅延してチェックマークが引かれる。
///
/// Phase 16d-4。`AppMotion.long` (320ms) が上限。Reduce Motion 設定時は
/// アニメーションせず最終状態を即表示する（[AppMotion.reduce] 経由）。
///
/// 「一度だけ」制御は親の既存 State と bool 1 つで行う: [visible] が
/// false -> true に変化したときだけ 1 回再生し、親が false に戻さない限り
/// 再発動しない。初回 build から [visible] が true の場合は次フレームで
/// 発動する（didUpdateWidget が初回 build で呼ばれないため）。
class AppSuccessCheck extends StatefulWidget {
  const AppSuccessCheck({
    super.key,
    this.size = 48,
    this.visible = false,
    this.onCompleted,
    this.haptic = false,
  });

  /// 表示サイズ（直径）。既定 48。
  final double size;

  /// true に変化したときに 1 度だけ再生する。
  final bool visible;

  /// 演出の完了（チェックマークまで描き終わった）時に呼ばれる。
  final VoidCallback? onCompleted;

  /// 完了時の触覚フィードバック。既定は無効（完了演出は静か）。
  final bool haptic;

  @override
  State<AppSuccessCheck> createState() => _AppSuccessCheckState();
}

class _AppSuccessCheckState extends State<AppSuccessCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _circleScale;
  late final Animation<double> _checkProgress;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: AppMotion.long, vsync: this);
    // 円は強調寄りの減速カーブで 0 -> 1 へ広がる。
    _circleScale = CurvedAnimation(
      parent: _controller,
      curve: AppMotion.emphasized,
    );
    // チェックマークは円の登場の後半から引き始める。
    _checkProgress = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.55, 1.0, curve: AppMotion.enter),
      ),
    );
    _controller.addStatusListener(_onStatus);
    if (widget.visible) {
      // 初回 build から visible の場合は次フレームで発動させる。
      SchedulerBinding.instance.addPostFrameCallback((_) => _play());
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (widget.haptic) HapticFeedback.selectionClick();
    widget.onCompleted?.call();
  }

  void _play() {
    if (!mounted) return;
    if (AppMotion.reduce(context)) {
      // Reduce Motion: アニメーションせず最終状態を即表示する。
      _controller.value = 1.0;
    } else {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void didUpdateWidget(covariant AppSuccessCheck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) _play();
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final d = widget.size;
    return SizedBox(
      width: d,
      height: d,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _SuccessPainter(
              circleScale: _circleScale.value,
              checkProgress: _checkProgress.value,
              circleColor: colorScheme.primary,
              checkColor: colorScheme.onPrimary,
            ),
          );
        },
      ),
    );
  }
}

class _SuccessPainter extends CustomPainter {
  const _SuccessPainter({
    required this.circleScale,
    required this.checkProgress,
    required this.circleColor,
    required this.checkColor,
  });

  final double circleScale;
  final double checkProgress;
  final Color circleColor;
  final Color checkColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    if (circleScale > 0) {
      canvas.drawCircle(
        center,
        radius * circleScale,
        Paint()
          ..color = circleColor
          ..style = PaintingStyle.fill,
      );
    }

    if (checkProgress > 0) {
      final p1 = Offset(center.dx - radius * 0.5, center.dy + radius * 0.05);
      final p2 = Offset(center.dx - radius * 0.12, center.dy + radius * 0.45);
      final p3 = Offset(center.dx + radius * 0.55, center.dy - radius * 0.45);

      final seg1 = (p2 - p1).distance;
      final seg2 = (p3 - p2).distance;
      final target = (seg1 + seg2) * checkProgress;

      final path = Path()..moveTo(p1.dx, p1.dy);
      if (target <= seg1) {
        final t = seg1 == 0 ? 0.0 : target / seg1;
        path.lineTo(p1.dx + (p2.dx - p1.dx) * t, p1.dy + (p2.dy - p1.dy) * t);
      } else {
        path.lineTo(p2.dx, p2.dy);
        final rest = target - seg1;
        final t = seg2 == 0 ? 0.0 : (rest / seg2).clamp(0.0, 1.0);
        path.lineTo(p2.dx + (p3.dx - p2.dx) * t, p2.dy + (p3.dy - p2.dy) * t);
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = checkColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 0.28
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SuccessPainter old) =>
      old.circleScale != circleScale ||
      old.checkProgress != checkProgress ||
      old.circleColor != circleColor ||
      old.checkColor != checkColor;
}
