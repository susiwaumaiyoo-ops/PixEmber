import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'database_service.dart';
import '../illust_model.dart';
import '../novel_model.dart';

/// ミュート設定用のデータクラス
class _MuteFilter {
  final List<String> mutedTags;
  final List<int> mutedUserIds;
  final String? aiMuteValue;

  _MuteFilter({
    required this.mutedTags,
    required this.mutedUserIds,
    this.aiMuteValue,
  });
}

class PixivApiService {
  final DatabaseService _dbService = DatabaseService();

  // ... existing code ...

  // ==========================================
  // ミュート（ブラックリスト）動的フィルタリング
  // ==========================================

  /// ミュート設定をメインスレッド側（UI Isolate）で SQLite から取得し、
  /// Isolate に渡しやすい Set に正規化する。
  /// 注意: sqflite は別 Isolate から呼ぶと MethodChannel デッドロック（ANR）になるため、
  /// ここでの取得は必ずメインスレッド側で行う。
  Future<_MuteFilter> _loadMuteFilter() async {
    final mutes = await _dbService.getMutesList();

    final mutedTags = mutes
        .where((m) => m['mute_type'] == 'tag')
        .map((m) => m['value'].toString().toLowerCase())
        .toSet();
    final mutedUserIds = mutes
        .where((m) => m['mute_type'] == 'user')
        .map((m) => int.tryParse(m['value'].toString()))
        .whereType<int>()
        .toSet();

    // AI作品ミュート設定
    // '0': AI以外（AI作品をミュート）
    // '1': AI作品（AI以外をミュート）
    // '2': すべてをミュート
    final aiMuteRecord = mutes.firstWhere(
      (m) => m['mute_type'] == 'ai',
      orElse: () => {},
    );
    final aiMuteValue = aiMuteRecord.isNotEmpty
        ? aiMuteRecord['value'].toString()
        : null;

    return _MuteFilter(
      mutedTags: mutedTags.toList(),
      mutedUserIds: mutedUserIds.toList(),
      aiMuteValue: aiMuteValue,
    );
  }

  /// イラストリストに対するミュートの動的適用（メインスレッド側・レガシー）
  Future<List<Illust>> filterIllusts(
    List<dynamic> illustsJsonList, {
    String? xRestrict,
    String? workType,
  }) async {
    final mutes = await _dbService.getMutesList();

    final mutedTags = mutes
        .where((m) => m['mute_type'] == 'tag')
        .map((m) => m['value'].toString().toLowerCase())
        .toSet();
    final mutedUserIds = mutes
        .where((m) => m['mute_type'] == 'user')
        .map((m) => int.tryParse(m['value'].toString()))
        .whereType<int>()
        .toSet();

    final aiMuteRecord = mutes.firstWhere(
      (m) => m['mute_type'] == 'ai',
      orElse: () => {},
    );
    final aiMuteValue = aiMuteRecord.isNotEmpty
        ? aiMuteRecord['value'].toString()
        : null;

    final List<Illust> filtered = [];

    for (var item in illustsJsonList) {
      try {
        final Map<String, dynamic> itemMap = item as Map<String, dynamic>;

        // 0. 年齢制限（x_restrict）フィルタリング
        final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
        if (xRestrict != null) {
          final String xLower = xRestrict.toLowerCase();
          if (xLower == 'safe' && xRestrictVal > 0) {
            continue; // safe（全年齢）が指定されている場合、R-18(1)/R-18G(2)を除外
          } else if (xLower == 'r18' && xRestrictVal == 0) {
            continue; // r18が指定されている場合、全年齢(0)を除外
          }
        }

        // 1. ユーザーIDミュート
        final int userId = itemMap['user']?['id'] as int? ?? 0;
        if (mutedUserIds.contains(userId)) {
          continue;
        }

        // 2. タグミュート
        final tagsObj = itemMap['tags'] as List<dynamic>? ?? [];
        bool hasMutedTag = false;
        for (var t in tagsObj) {
          final tMap = t as Map<String, dynamic>?;
          final tName = (tMap?['name'] as String? ?? '').toLowerCase();
          final tTranslated = (tMap?['translated_name'] as String? ?? '')
              .toLowerCase();

          if (mutedTags.any(
            (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
          )) {
            hasMutedTag = true;
            break;
          }
        }
        if (hasMutedTag) {
          continue;
        }

        // 3. AI作品ミュート
        // 小説の構造: novel_ai_type == 2 がAI作品
        final int aiType = itemMap['novel_ai_type'] as int? ?? 0;
        final bool isAiWork = aiType == 2;
        if (aiMuteValue != null) {
          if (aiMuteValue == '1' && isAiWork) {
            continue;
          } else if (aiMuteValue == '0' && !isAiWork) {
            continue;
          } else if (aiMuteValue == '2') {
            continue;
          }
        }

        final illust = Illust.fromJson(itemMap);
        filtered.add(illust);
      } catch (e, stack) {
        // 個別パースエラーはスルー（デバッグログを出力）
        final idStr = (item is Map && item['id'] != null)
            ? item['id'].toString()
            : 'unknown';
        debugPrint('[API][PARSE ERROR] Illust id=$idStr, error=$e');
        debugPrint(stack.toString());
      }
    }

    debugPrint(
      '[API] filterIllusts: input=${illustsJsonList.length}, output=${filtered.length}',
    );
    return filtered;
  }

  /// 小説リストに対するミュートの動的適用
  Future<List<Novel>> filterNovels(
    List<dynamic> novelsJsonList, {
    String? xRestrict,
  }) async {
    final mutes = await _dbService.getMutesList();

    final mutedTags = mutes
        .where((m) => m['mute_type'] == 'tag')
        .map((m) => m['value'].toString().toLowerCase())
        .toSet();
    final mutedUserIds = mutes
        .where((m) => m['mute_type'] == 'user')
        .map((m) => int.tryParse(m['value'].toString()))
        .whereType<int>()
        .toSet();

    final aiMuteRecord = mutes.firstWhere(
      (m) => m['mute_type'] == 'ai',
      orElse: () => {},
    );
    final aiMuteValue = aiMuteRecord.isNotEmpty
        ? aiMuteRecord['value'].toString()
        : null;

    final List<Novel> filtered = [];

    for (var item in novelsJsonList) {
      try {
        final Map<String, dynamic> itemMap = item as Map<String, dynamic>;

        // 0. 年齢制限（x_restrict）フィルタリング
        final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
        if (xRestrict != null) {
          final String xLower = xRestrict.toLowerCase();
          if (xLower == 'safe' && xRestrictVal > 0) {
            continue; // safe（全年齢）が指定されている場合、R-18(1)/R-18G(2)を除外
          } else if (xLower == 'r18' && xRestrictVal == 0) {
            continue; // r18が指定されている場合、全年齢(0)を除外
          }
        }

        // 1. ユーザーIDミュート
        final int userId = itemMap['user']?['id'] as int? ?? 0;
        if (mutedUserIds.contains(userId)) {
          continue;
        }

        // 2. タグミュート
        final tagsObj = itemMap['tags'] as List<dynamic>? ?? [];
        bool hasMutedTag = false;
        for (var t in tagsObj) {
          final tMap = t as Map<String, dynamic>?;
          final tName = (tMap?['name'] as String? ?? '').toLowerCase();
          final tTranslated = (tMap?['translated_name'] as String? ?? '')
              .toLowerCase();

          if (mutedTags.any(
            (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
          )) {
            hasMutedTag = true;
            break;
          }
        }
        if (hasMutedTag) {
          continue;
        }

        // 3. AI作品ミュート
        // 小説の構造: novel_ai_type == 2 がAI作品
        final int aiType = itemMap['novel_ai_type'] as int? ?? 0;
        final bool isAiWork = aiType == 2;
        if (aiMuteValue != null) {
          if (aiMuteValue == '1' && isAiWork) {
            continue;
          } else if (aiMuteValue == '0' && !isAiWork) {
            continue;
          } else if (aiMuteValue == '2') {
            continue;
          }
        }

        final novel = Novel.fromJson(itemMap);
        filtered.add(novel);
      } catch (e, stack) {
        // 個別パースエラーはスルー（デバッグログを出力）
        final idStr = (item is Map && item['id'] != null)
            ? item['id'].toString()
            : 'unknown';
        debugPrint('[API][PARSE ERROR] Novel id=$idStr, error=$e');
        debugPrint(stack.toString());
      }
    }

    debugPrint(
      '[API] filterNovels: input=${novelsJsonList.length}, output=${filtered.length}',
    );
    return filtered;
  }

  /// イラストのミュート適用＋モデル変換を Isolate で実行するためのエントリ。
  /// ミュート設定はメインスレッド側で事前取得（_loadMuteFilter）し、
  /// Isolate.run 内では DB アクセスを行わずメモリ上のフィルタのみ実行。
  /// Isolate.run は StandardMessageCodec を使うためカスタムクラスを
  /// 送受信できない（Isolate 内では Map のみ扱い、fromJson はメイン側で
  /// 1 回だけ行う）。これで fromJson→toJson→fromJson の重複シリアライズを排除。
  Future<List<Illust>> filterIllustsIsolated(
    List<dynamic> illustsJsonList, {
    String? xRestrict,
    String? workType,
  }) async {
    final mutes = await _loadMuteFilter();

    // メインスレッドで JSON デコードを済ませ、Isolate に渡すのは
    // シリアライズ可能な Map のみにする。
    final List<Map<String, dynamic>> maps = await Isolate.run(() {
      final List<Map<String, dynamic>> result = [];
      for (var item in illustsJsonList) {
        try {
          final Map<String, dynamic> itemMap = item as Map<String, dynamic>;
          result.add(itemMap);
        } catch (e) {
          debugPrint('[API][PARSE ERROR] Isolated Illust id=unknown, error=$e');
        }
      }
      return result;
    });

    final filteredMaps = _filterIllustsInIsolate(
      maps,
      mutes,
      xRestrict,
      workType,
    );
    return filteredMaps.map((m) => Illust.fromJson(m)).toList();
  }

  /// Isolate 内で実行されるフィルタリングロジック
  List<Map<String, dynamic>> _filterIllustsInIsolate(
    List<Map<String, dynamic>> maps,
    _MuteFilter mutes,
    String? xRestrict,
    String? workType,
  ) {
    final List<Map<String, dynamic>> filtered = [];

    for (var itemMap in maps) {
      // 0. 年齢制限（x_restrict）フィルタリング
      final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
      if (xRestrict != null) {
        final String xLower = xRestrict.toLowerCase();
        if (xLower == 'safe' && xRestrictVal > 0) {
          continue; // safe（全年齢）が指定されている場合、R-18(1)/R-18G(2)を除外
        } else if (xLower == 'r18' && xRestrictVal == 0) {
          continue; // r18が指定されている場合、全年齢(0)を除外
        }
      }

      // 1. ユーザーIDミュート
      final int userId = itemMap['user']?['id'] as int? ?? 0;
      if (mutes.mutedUserIds.contains(userId)) {
        continue;
      }

      // 2. タグミュート
      final tagsObj = itemMap['tags'] as List<dynamic>? ?? [];
      bool hasMutedTag = false;
      for (var t in tagsObj) {
        final tMap = t as Map<String, dynamic>?;
        final tName = (tMap?['name'] as String? ?? '').toLowerCase();
        final tTranslated = (tMap?['translated_name'] as String? ?? '')
            .toLowerCase();

        if (mutes.mutedTags.any(
          (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
        )) {
          hasMutedTag = true;
          break;
        }
      }
      if (hasMutedTag) {
        continue;
      }

      // 3. AI作品ミュート
      final int aiType = itemMap['novel_ai_type'] as int? ?? 0;
      final bool isAiWork = aiType == 2;
      if (mutes.aiMuteValue != null) {
        if (mutes.aiMuteValue == '1' && isAiWork) {
          continue;
        } else if (mutes.aiMuteValue == '0' && !isAiWork) {
          continue;
        } else if (mutes.aiMuteValue == '2') {
          continue;
        }
      }

      filtered.add(itemMap);
    }

    return filtered;
  }

  /// 小説のミュート適用＋モデル変換を Isolate で実行するためのエントリ。
  /// ミュート設定はメインスレッド側で事前取得（_loadMuteFilter）し、
  /// Isolate.run 内では DB アクセスを行わずメモリ上のフィルタのみ実行。
  Future<List<Novel>> filterNovelsIsolated(
    List<dynamic> novelsJsonList, {
    String? xRestrict,
  }) async {
    final mutes = await _loadMuteFilter();

    // メインスレッドで JSON デコードを済ませ、Isolate に渡すのは
    // シリアライズ可能な Map のみにする。
    final List<Map<String, dynamic>> maps = await Isolate.run(() {
      final List<Map<String, dynamic>> result = [];
      for (var item in novelsJsonList) {
        try {
          final Map<String, dynamic> itemMap = item as Map<String, dynamic>;
          result.add(itemMap);
        } catch (e) {
          debugPrint('[API][PARSE ERROR] Isolated Novel id=unknown, error=$e');
        }
      }
      return result;
    });

    final filteredMaps = _filterNovelsInIsolate(maps, mutes, xRestrict);
    return filteredMaps.map((m) => Novel.fromJson(m)).toList();
  }

  /// Isolate 内で実行されるフィルタリングロジック
  List<Map<String, dynamic>> _filterNovelsInIsolate(
    List<Map<String, dynamic>> maps,
    _MuteFilter mutes,
    String? xRestrict,
  ) {
    final List<Map<String, dynamic>> filtered = [];

    for (var itemMap in maps) {
      // 0. 年齢制限（x_restrict）フィルタリング
      final int xRestrictVal = itemMap['x_restrict'] as int? ?? 0;
      if (xRestrict != null) {
        final String xLower = xRestrict.toLowerCase();
        if (xLower == 'safe' && xRestrictVal > 0) {
          continue; // safe（全年齢）が指定されている場合、R-18(1)/R-18G(2)を除外
        } else if (xLower == 'r18' && xRestrictVal == 0) {
          continue; // r18が指定されている場合、全年齢(0)を除外
        }
      }

      // 1. ユーザーIDミュート
      final int userId = itemMap['user']?['id'] as int? ?? 0;
      if (mutes.mutedUserIds.contains(userId)) {
        continue;
      }

      // 2. タグミュート
      final tagsObj = itemMap['tags'] as List<dynamic>? ?? [];
      bool hasMutedTag = false;
      for (var t in tagsObj) {
        final tMap = t as Map<String, dynamic>?;
        final tName = (tMap?['name'] as String? ?? '').toLowerCase();
        final tTranslated = (tMap?['translated_name'] as String? ?? '')
            .toLowerCase();

        if (mutes.mutedTags.any(
          (mTag) => tName.contains(mTag) || tTranslated.contains(mTag),
        )) {
          hasMutedTag = true;
          break;
        }
      }
      if (hasMutedTag) {
        continue;
      }

      // 3. AI作品ミュート
      final int aiType = itemMap['novel_ai_type'] as int? ?? 0;
      final bool isAiWork = aiType == 2;
      if (mutes.aiMuteValue != null) {
        if (mutes.aiMuteValue == '1' && isAiWork) {
          continue;
        } else if (mutes.aiMuteValue == '0' && !isAiWork) {
          continue;
        } else if (mutes.aiMuteValue == '2') {
          continue;
        }
      }

      filtered.add(itemMap);
    }

    return filtered;
  }
}
