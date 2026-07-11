import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import '../services/pixiv_api_service.dart';

class UgoiraPlayer extends StatefulWidget {
  final int illustId;

  const UgoiraPlayer({super.key, required this.illustId});

  @override
  State<UgoiraPlayer> createState() => _UgoiraPlayerState();
}

class _UgoiraPlayerState extends State<UgoiraPlayer> {
  bool _isLoading = true;
  String? _error;
  List<dynamic> _frames = [];
  Map<String, Uint8List> _frameImages = {};
  int _currentFrameIndex = 0;
  bool _isPlaying = true;
  Timer? _timer;
  double _loadProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _loadUgoira();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadUgoira() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
        _loadProgress = 0.1;
      });

      // 1. メタデータの取得（PixivApiService経由に移行）
      final api = PixivApiService();
      final metaResponse = await api.getUgoiraMetadata(widget.illustId);

      final metaData = metaResponse['ugoira_metadata'] ?? {};
      _frames = metaData['frames'] ?? [];
      final String originalZipUrl =
          metaData['zip_urls']?['medium'] ??
          metaData['zip_urls']?['large'] ??
          '';

      if (_frames.isEmpty || originalZipUrl.isEmpty) {
        throw Exception('うごイラ情報が空です。');
      }

      if (!mounted) return;
      setState(() => _loadProgress = 0.3);

      // 2. ZIPファイルのダウンロード（Pixivの制限を回避するためPixivのヘッダーを付与してダウンロード）
      final token = await api.getAccessToken(await api.getRefreshToken());
      final zipRes = await http
          .get(
            Uri.parse(originalZipUrl),
            headers: {
              'User-Agent': 'PixivAndroidApp/6.71.1 (Android 11; Pixel 5)',
              'App-OS': 'android',
              'App-OS-Version': '11',
              'App-Version': '6.71.1',
              'Accept-Language': 'ja-JP',
              'Authorization': 'Bearer $token',
              'Referer': 'https://app-api.pixiv.net/',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (zipRes.statusCode != 200) {
        throw Exception('うごイラZIPのダウンロードに失敗しました: ${zipRes.statusCode}');
      }

      if (!mounted) return;
      setState(() => _loadProgress = 0.6);

      // 3. メモリ上でのZIP解凍 (archive)
      final Archive archive = ZipDecoder().decodeBytes(zipRes.bodyBytes);
      final Map<String, Uint8List> tempImages = {};

      for (final ArchiveFile file in archive) {
        if (file.isFile) {
          tempImages[file.name] = file.content as Uint8List;
        }
      }

      if (!mounted) return;
      setState(() => _loadProgress = 0.9);

      if (mounted) {
        setState(() {
          _frameImages = tempImages;
          _isLoading = false;
          _loadProgress = 1.0;
        });
        _playAnimation();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _playAnimation() {
    _timer?.cancel();
    if (!_isPlaying || _frames.isEmpty || _frameImages.isEmpty) return;

    final currentFrame = _frames[_currentFrameIndex];
    final int delay = currentFrame['delay'] ?? 100;

    _timer = Timer(Duration(milliseconds: delay), () {
      if (!mounted) return;
      setState(() {
        _currentFrameIndex = (_currentFrameIndex + 1) % _frames.length;
      });
      _playAnimation();
    });
  }

  void _togglePlay() {
    setState(() {
      _isPlaying = !_isPlaying;
    });
    if (_isPlaying) {
      _playAnimation();
    } else {
      _timer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        height: 350,
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.pinkAccent),
              const SizedBox(height: 16),
              Text(
                'うごイラ展開中... ${(_loadProgress * 100).toInt()}%',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Container(
        height: 300,
        color: Colors.grey[950],
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.pinkAccent,
                  size: 40,
                ),
                const SizedBox(height: 12),
                Text(
                  'うごイラの読み込みに失敗しました。\n$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _loadUgoira,
                  icon: const Icon(Icons.refresh),
                  label: const Text('再読み込み'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final currentFrame = _frames[_currentFrameIndex];
    final String fileName = currentFrame['file'] ?? '';
    final frameData = _frameImages[fileName];

    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 350,
              color: Colors.black,
              alignment: Alignment.center,
              child: frameData != null
                  ? Image.memory(frameData, fit: BoxFit.contain)
                  : const Center(
                      child: Icon(Icons.broken_image, color: Colors.grey),
                    ),
            ),
            // 再生一時停止オーバーレイ
            Positioned(
              bottom: 12,
              right: 12,
              child: FloatingActionButton.small(
                onPressed: _togglePlay,
                backgroundColor: Colors.black.withValues(alpha: 0.7),
                foregroundColor: Colors.white,
                child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              ),
            ),
          ],
        ),
        // 再生インジケータ / シークバー
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            children: [
              Text(
                '${_currentFrameIndex + 1} / ${_frames.length}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: Slider(
                  value: _currentFrameIndex.toDouble(),
                  min: 0,
                  max: (_frames.length - 1).toDouble().clamp(
                    0.0,
                    double.infinity,
                  ),
                  activeColor: Colors.pinkAccent,
                  inactiveColor: Colors.grey[800],
                  onChanged: (val) {
                    _timer?.cancel();
                    setState(() {
                      _currentFrameIndex = val.toInt();
                      _isPlaying = false;
                    });
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
