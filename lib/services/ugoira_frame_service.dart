// うごイラ代表フレーム（感動機能パック Phase E3）。
//
// 設計:
// - うごイラの ZIP をダウンロードし、代表フレーム（最初のフレーム）を
//   メモリ上で展開して Uint8List を返す。
// - 展開はメイン Isolate で行う（既存 UgoiraPlayer と同じ。1作品1回・キャッシュ）。
// - ネットワーク失敗（オフライン等）時は null を返し、UI は既存サムネを維持。
// - 純粋関数 pickRepresentativeFrameFile で「どのフレームを代表にするか」を決定
//   （テスト可能）。

import 'dart:async';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'pixiv_api_service.dart';

/// うごイラ代表フレームサービス（シングルトン・メモリキャッシュ）。
class UgoiraFrameService {
  UgoiraFrameService._internal();
  static final UgoiraFrameService _instance = UgoiraFrameService._internal();
  factory UgoiraFrameService() => _instance;

  final Map<int, Uint8List> _cache = {};

  /// テスト用: キャッシュをクリアする。
  void clearCache() => _cache.clear();

  /// メモリキャッシュから代表フレームを取得（なければ null）。
  Uint8List? getCached(int illustId) => _cache[illustId];

  /// 代表フレーム（静止画）を取得する。失敗時は null。
  Future<Uint8List?> fetchRepresentativeFrame(int illustId) async {
    if (_cache.containsKey(illustId)) return _cache[illustId];
    try {
      final api = PixivApiService();
      final metaResponse = await api.getUgoiraMetadata(illustId);
      final metaData = metaResponse['ugoira_metadata'] ?? {};
      final frames = metaData['frames'] ?? [];
      final zipUrl =
          metaData['zip_urls']?['medium'] ??
          metaData['zip_urls']?['large'] ??
          '';
      if (frames.isEmpty || zipUrl.isEmpty) return null;

      final token = await api.getAccessToken(await api.getRefreshToken());
      final zipRes = await http
          .get(
            Uri.parse(zipUrl),
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
      if (zipRes.statusCode != 200) return null;

      final archive = ZipDecoder().decodeBytes(zipRes.bodyBytes);
      final fileNames = <String>[];
      final bytesByName = <String, Uint8List>{};
      for (final f in archive) {
        if (!f.isFile) continue;
        fileNames.add(f.name);
        bytesByName[f.name] = f.content as Uint8List;
      }
      final picked = pickRepresentativeFrameFile(frames, fileNames);
      if (picked == null) return null;
      final bytes = bytesByName[picked];
      if (bytes == null) return null;
      _cache[illustId] = bytes;
      return bytes;
    } catch (e) {
      debugPrint('うごイラ代表フレーム取得失敗（従来サムネ維持）: $e');
      return null;
    }
  }
}

/// 代表フレームのファイル名を選ぶ（純粋関数・テスト可能）。
///
/// [frames] はうごイラメタの frames リスト（各要素 map: {file, delay}）。
/// [fileNames] は ZIP 内の実ファイル名リスト。
/// デフォルトは最初のフレーム。frames/fileNames が空なら null。
String? pickRepresentativeFrameFile(
  List<dynamic> frames,
  List<String> fileNames,
) {
  if (frames.isEmpty || fileNames.isEmpty) return null;
  final firstFile = frames.first is Map
      ? (frames.first['file'] as String?)
      : null;
  if (firstFile != null && fileNames.contains(firstFile)) return firstFile;
  return fileNames.first;
}
