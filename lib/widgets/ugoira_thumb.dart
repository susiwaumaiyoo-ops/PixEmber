// うごイラ代表フレームサムネイル（感動機能パック Phase E3）。
//
// うごイラの場合、アニメーションの1フレーム静止画をサムネイルに使う。
// 代表フレーム取得に失敗（オフライン等）した場合は既存の [fallbackUrl] を
// 表示し、機能がない時と同じ見た目を保つ（空状態・失敗時フォールバック）。

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/ugoira_frame_service.dart';
import 'pixiv_image.dart';

class UgoiraThumb extends StatefulWidget {
  final int illustId;
  final String? fallbackUrl;
  final BoxFit fit;

  const UgoiraThumb({
    super.key,
    required this.illustId,
    this.fallbackUrl,
    this.fit = BoxFit.cover,
  });

  @override
  State<UgoiraThumb> createState() => _UgoiraThumbState();
}

class _UgoiraThumbState extends State<UgoiraThumb> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = UgoiraFrameService().getCached(widget.illustId);
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }
    final bytes = await UgoiraFrameService().fetchRepresentativeFrame(
      widget.illustId,
    );
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(_bytes!, fit: widget.fit, gaplessPlayback: true),
          _badge(),
        ],
      );
    }
    // 取得中または失敗: 既存サムネをフォールバック表示。
    return Stack(
      fit: StackFit.expand,
      children: [_fallback(), if (!_loading) _badge()],
    );
  }

  Widget _fallback() {
    if (widget.fallbackUrl == null || widget.fallbackUrl!.isEmpty) {
      return Container(color: Colors.black26);
    }
    return PixivImage(
      url: widget.fallbackUrl!,
      fit: widget.fit,
      isThumbnail: true,
      cacheWidth: 300,
      errorWidget: Container(color: Colors.black26),
    );
  }

  Widget _badge() {
    return Positioned(
      top: 6,
      right: 6,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'うご',
          style: TextStyle(color: Colors.white, fontSize: 10),
        ),
      ),
    );
  }
}
