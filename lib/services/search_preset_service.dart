// 検索プリセットサービス（非AI機能パック Phase N1）。
//
// よく使う詳細な検索条件（キーワード + フィルタ設定）をプリセットとして
// 保存し、1タップで復元して即検索できる。
// ストレージ: SharedPreferences（JSON リスト、キー search_presets_v1）。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 保持するプリセットの最大数（仕様: 20〜30 件）。
const int kSearchPresetMax = 30;

/// 検索プリセット。
class SearchPreset {
  const SearchPreset({
    required this.id,
    required this.name,
    required this.category,
    required this.keyword,
    required this.filterJson,
    this.keywordMode = 'and',
    this.excludeKeyword = '',
    required this.createdAt,
    required this.updatedAt,
    this.lastUsedAt,
  });

  final String id;

  /// プリセット名（ユーザー入力。既定はキーワード）。
  final String name;

  /// 対象タブ: 'illust' | 'novel'。
  final String category;

  /// 検索キーワード。
  final String keyword;

  /// フィルタ条件スナップショット（イラスト / 小説 / 共通）。
  final Map<String, dynamic> filterJson;

  /// キーワード結合モード: 'and' | 'or'。
  final String keywordMode;

  /// 除外キーワード（スペース区切り）。
  final String excludeKeyword;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUsedAt;

  SearchPreset copyWith({
    String? name,
    String? category,
    String? keyword,
    Map<String, dynamic>? filterJson,
    String? keywordMode,
    String? excludeKeyword,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
  }) {
    return SearchPreset(
      id: id,
      name: name ?? this.name,
      category: category ?? this.category,
      keyword: keyword ?? this.keyword,
      filterJson: filterJson ?? this.filterJson,
      keywordMode: keywordMode ?? this.keywordMode,
      excludeKeyword: excludeKeyword ?? this.excludeKeyword,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'keyword': keyword,
    'filter_json': filterJson,
    'keyword_mode': keywordMode,
    'exclude_keyword': excludeKeyword,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'last_used_at': lastUsedAt?.toIso8601String(),
  };

  /// 寛容な解析: 欠落フィールドは既定値を使う（旧データ互換）。
  factory SearchPreset.fromJson(Map<String, dynamic> json) {
    final filterRaw = json['filter_json'];
    Map<String, dynamic> filterJson;
    if (filterRaw is Map<String, dynamic>) {
      filterJson = filterRaw;
    } else if (filterRaw is Map) {
      filterJson = filterRaw.map((k, v) => MapEntry(k.toString(), v));
    } else {
      filterJson = const {};
    }
    return SearchPreset(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      category: (json['category'] as String?) == 'novel' ? 'novel' : 'illust',
      keyword: (json['keyword'] as String?) ?? '',
      filterJson: filterJson,
      keywordMode: (json['keyword_mode'] as String?) == 'or' ? 'or' : 'and',
      excludeKeyword: (json['exclude_keyword'] as String?) ?? '',
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at']),
      lastUsedAt: json['last_used_at'] == null
          ? null
          : DateTime.tryParse((json['last_used_at'] as String?) ?? ''),
    );
  }

  static DateTime _parseDate(Object? value) =>
      value is String && value.isNotEmpty
      ? (DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0))
      : DateTime.fromMillisecondsSinceEpoch(0);
}

/// 最終使用（なければ更新時刻）の新しい順にソート。
List<SearchPreset> sortPresetsByUse(List<SearchPreset> presets) {
  final list = List<SearchPreset>.of(presets);
  list.sort((a, b) {
    final ta = a.lastUsedAt ?? a.updatedAt;
    final tb = b.lastUsedAt ?? b.updatedAt;
    return tb.compareTo(ta);
  });
  return list;
}

/// 重複排除（同名 + 同カテゴリ + 同キーワード → 最新を更新して保持）+ 件数上限。
List<SearchPreset> normalizePresets(
  List<SearchPreset> presets, {
  int maxItems = kSearchPresetMax,
}) {
  final byKey = <String, SearchPreset>{};
  for (final p in sortPresetsByUse(presets)) {
    byKey.putIfAbsent('${p.category}|${p.name}|${p.keyword}', () => p);
  }
  final list = byKey.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  if (list.length > maxItems) {
    return list.sublist(0, maxItems);
  }
  return list;
}

/// リストを JSON 文字列化する。
String encodePresets(List<SearchPreset> presets) =>
    jsonEncode([for (final p in presets) p.toJson()]);

/// 寛容な解析: 不正・旧形式でも空リストを返す（クラッシュしない）。
List<SearchPreset> decodePresets(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final result = <SearchPreset>[];
  for (final e in decoded) {
    final map = e is Map<String, dynamic>
        ? e
        : (e is Map ? e.map((k, v) => MapEntry(k.toString(), v)) : null);
    if (map == null) continue;
    final p = SearchPreset.fromJson(map);
    if (p.id.isNotEmpty) result.add(p);
  }
  return result;
}

/// プリセット格納サービス（SharedPreferences）。
class SearchPresetService {
  static const String storageKey = 'search_presets_v1';

  Future<List<SearchPreset>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return decodePresets(prefs.getString(storageKey));
  }

  Future<void> _persist(List<SearchPreset> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, encodePresets(list));
  }

  /// 新規保存。同名・同カテゴリ・同キーワードなら更新扱い。
  Future<SearchPreset> save({
    required String name,
    required String category,
    required String keyword,
    required Map<String, dynamic> filterJson,
    String keywordMode = 'and',
    String excludeKeyword = '',
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final cat = category == 'novel' ? 'novel' : 'illust';
    var list = await load();
    final idx = list.indexWhere(
      (p) => p.category == cat && p.name == name && p.keyword == keyword,
    );
    late final SearchPreset preset;
    if (idx >= 0) {
      preset = list[idx].copyWith(
        filterJson: filterJson,
        keywordMode: keywordMode,
        excludeKeyword: excludeKeyword,
        updatedAt: t,
      );
      list = List<SearchPreset>.of(list)..[idx] = preset;
    } else {
      preset = SearchPreset(
        id: 'ps_${t.microsecondsSinceEpoch}',
        name: name,
        category: cat,
        keyword: keyword,
        filterJson: filterJson,
        keywordMode: keywordMode,
        excludeKeyword: excludeKeyword,
        createdAt: t,
        updatedAt: t,
      );
      list = [...list, preset];
    }
    await _persist(normalizePresets(list));
    return preset;
  }

  /// 名前変更（空名は無視）。
  Future<void> rename(String id, String newName, {DateTime? now}) async {
    final name = newName.trim();
    if (name.isEmpty) return;
    final t = now ?? DateTime.now();
    final list = await load();
    await _persist(
      normalizePresets([
        for (final p in list)
          if (p.id == id) p.copyWith(name: name, updatedAt: t) else p,
      ]),
    );
  }

  Future<void> delete(String id) async {
    final list = await load();
    await _persist(
      normalizePresets([
        for (final p in list)
          if (p.id != id) p,
      ]),
    );
  }

  /// 最終使用時刻の記録。
  Future<void> markUsed(String id, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final list = await load();
    await _persist([
      for (final p in list)
        if (p.id == id) p.copyWith(lastUsedAt: t) else p,
    ]);
  }
}
