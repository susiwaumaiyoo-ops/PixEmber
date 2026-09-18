import 'home_screen_state.dart';
import '../services/search_preset_service.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// フィルター関連メソッドを管理するクラス
class HomeFilterHandler {
  final PixivViewerHomeState state;

  HomeFilterHandler(this.state);

  /// 起動時にフィルター設定を SharedPreferences から復元する。
  /// 既存フィルター（filter_*）と Phase 2 新設フィルター
  /// （filter_bookmark_num_min/max / filter_use_start_date /
  /// filter_start_date / filter_use_end_date / filter_end_date）を含む。
  Future<void> loadFilterPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 新設フィルタのみ復元（既存の filter_* は従来どおりデフォルト値維持）
      final minBm = prefs.getString('filter_bookmark_num_min');
      if (minBm != null && minBm.isNotEmpty) {
        state.minBookmarkNumController.text = minBm;
      }
      final maxBm = prefs.getString('filter_bookmark_num_max');
      if (maxBm != null && maxBm.isNotEmpty) {
        state.maxBookmarkNumController.text = maxBm;
      }
      final useStart = prefs.getBool('filter_use_start_date') ?? false;
      final startRaw = prefs.getString('filter_start_date');
      if (useStart && startRaw != null) {
        final d = DateTime.tryParse(startRaw);
        if (d != null) {
          state.startDateTime = d;
          state.useStartDate = true;
        }
      }
      final useEnd = prefs.getBool('filter_use_end_date') ?? false;
      final endRaw = prefs.getString('filter_end_date');
      if (useEnd && endRaw != null) {
        final d = DateTime.tryParse(endRaw);
        if (d != null) {
          state.endDateTime = d;
          state.useEndDate = true;
        }
      }
    } catch (e) {
      debugPrint('フィルター設定読み込みエラー: $e');
    }
  }

  /// Phase 2 新設フィルター（期間・日付範囲・ブックマーク数範囲）を保存する。
  /// 公開メソッド: 日付ピッカーからの直接呼び出しにも使う。
  Future<void> persistFilterPrefs() => _saveCommonFilterPrefs();

  /// Phase 2 新設フィルターの保存（イラスト・小説シート共通キー）。
  Future<void> _saveCommonFilterPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final minBm = state.minBookmarkNumController.text.trim();
      final maxBm = state.maxBookmarkNumController.text.trim();
      await prefs.setString('filter_bookmark_num_min', minBm);
      await prefs.setString('filter_bookmark_num_max', maxBm);
      await prefs.setBool('filter_use_start_date', state.useStartDate);
      await prefs.setString(
        'filter_start_date',
        state.startDateTime?.toIso8601String() ?? '',
      );
      await prefs.setBool('filter_use_end_date', state.useEndDate);
      await prefs.setString(
        'filter_end_date',
        state.endDateTime?.toIso8601String() ?? '',
      );
    } catch (e) {
      debugPrint('共通フィルター設定保存エラー: $e');
    }
  }

  /// 新設フィルター状態をリセットする（UI リセットボタン用）。
  void resetCommonFilterState() {
    state.minBookmarkNumController.clear();
    state.maxBookmarkNumController.clear();
    state.useStartDate = false;
    state.useEndDate = false;
    state.startDateTime = null;
    state.endDateTime = null;
  }

  // 一般フィルター設定を保存
  Future<void> _saveFilterPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('filter_search_target', state.selectedSearchTarget);
      await prefs.setString('filter_sort', state.selectedSort);
      await prefs.setString('filter_work_type', state.selectedWorkType);
      await prefs.setString('filter_age_limit', state.selectedAgeLimit);
      await prefs.setString('filter_duration', state.selectedDuration);
      await prefs.setInt('filter_bookmark', state.selectedBookmarkFilter);
    } catch (e) {
      debugPrint('フィルター設定保存エラー: $e');
    }
    await _saveCommonFilterPrefs();
  }

  Future<void> _saveNovelFilterPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('novel_filter_ai', state.selectedNovelAiFilter);
      await prefs.setBool('novel_filter_series_only', state.novelSeriesOnly);
      await prefs.setStringList(
        'novel_filter_exclude_tags',
        state.novelExcludeTags,
      );
      await prefs.setString('novel_filter_density', state.novelDensityMode);
      await prefs.setString(
        'novel_filter_search_target',
        state.selectedNovelSearchTarget,
      );
      await prefs.setString(
        'novel_filter_age_limit',
        state.selectedNovelAgeLimit,
      );
      await prefs.setInt(
        'novel_filter_bookmark',
        state.selectedNovelBookmarkFilter,
      );
      await prefs.setString(
        'novel_filter_text_length',
        state.selectedNovelTextLengthLimit,
      );
      if (state.minTextLengthController?.text != null) {
        await prefs.setString(
          'novel_filter_min_text',
          state.minTextLengthController!.text,
        );
      }
      if (state.maxTextLengthController?.text != null) {
        await prefs.setString(
          'novel_filter_max_text',
          state.maxTextLengthController!.text,
        );
      }
      await prefs.setString(
        'novel_filter_series_text_length',
        state.selectedNovelSeriesTextLengthLimit,
      );
      if (state.minSeriesTextLengthController?.text != null) {
        await prefs.setString(
          'novel_filter_series_min_text',
          state.minSeriesTextLengthController!.text,
        );
      }
      if (state.maxSeriesTextLengthController?.text != null) {
        await prefs.setString(
          'novel_filter_series_max_text',
          state.maxSeriesTextLengthController!.text,
        );
      }
    } catch (e) {
      debugPrint('小説フィルター設定の保存に失敗: $e');
    }
    await _saveCommonFilterPrefs();
  }

  // ===== Phase N1: 検索プリセット =====

  /// 現在の検索条件をプリセット用の filter_json として取得。
  Map<String, dynamic> capturePresetFilters() {
    return {
      'illust': {
        'searchTarget': state.selectedSearchTarget,
        'workType': state.selectedWorkType,
        'ageLimit': state.selectedAgeLimit,
        'duration': state.selectedDuration,
        'bookmarkFilter': state.selectedBookmarkFilter,
        'aiFilter': state.selectedIllustAiFilter,
        'minBookmarkText': state.minBookmarkController.text.trim(),
      },
      'novel': {
        'searchTarget': state.selectedNovelSearchTarget,
        'ageLimit': state.selectedNovelAgeLimit,
        'bookmarkFilter': state.selectedNovelBookmarkFilter,
        'textLengthLimit': state.selectedNovelTextLengthLimit,
        'minText': state.minTextLengthController?.text.trim() ?? '',
        'maxText': state.maxTextLengthController?.text.trim() ?? '',
        'seriesTextLengthLimit': state.selectedNovelSeriesTextLengthLimit,
        'seriesMinText': state.minSeriesTextLengthController?.text.trim() ?? '',
        'seriesMaxText': state.maxSeriesTextLengthController?.text.trim() ?? '',
        'aiFilter': state.selectedNovelAiFilter,
        'seriesOnly': state.novelSeriesOnly,
        'excludeTags': state.novelExcludeTags,
        'density': state.novelDensityMode,
      },
      'common': {
        'bmNumMin': state.minBookmarkNumController.text.trim(),
        'bmNumMax': state.maxBookmarkNumController.text.trim(),
        'useStartDate': state.useStartDate,
        'startDate': state.startDateTime?.toIso8601String(),
        'useEndDate': state.useEndDate,
        'endDate': state.endDateTime?.toIso8601String(),
      },
    };
  }

  /// 名前入力ダイアログを表示し、現在の条件をプリセットとして保存。
  Future<void> saveCurrentAsPreset(
    BuildContext context, {
    required String category,
  }) async {
    final keyword = state.searchController.text.trim();
    final defaultName = keyword.isEmpty
        ? (category == 'novel' ? '小説の検索' : 'イラストの検索')
        : keyword;
    final nameController = TextEditingController(text: defaultName);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プリセットとして保存'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'プリセット名'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final rawName = nameController.text.trim();
    nameController.dispose();
    if (confirmed != true || !context.mounted) return;
    final saveName = rawName.isEmpty ? defaultName : rawName;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SearchPresetService().save(
        name: saveName,
        category: category,
        keyword: keyword,
        filterJson: capturePresetFilters(),
        keywordMode: state.selectedKeywordMode,
        excludeKeyword: state.excludeKeywordController.text.trim(),
      );
      if (!context.mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text('プリセット「$saveName」を保存しました')),
      );
    } catch (e) {
      debugPrint('検索プリセットの保存に失敗: $e');
      if (!context.mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('プリセットの保存に失敗しました')));
    }
  }

  /// プリセットのフィルター条件を現在の状態に適用。
  void applyPresetFilters(SearchPreset preset) {
    final f = preset.filterJson;
    final illust = (f['illust'] as Map? ?? const <String, dynamic>{}).map(
      (k, v) => MapEntry(k.toString(), v),
    );
    final novel = (f['novel'] as Map? ?? const <String, dynamic>{}).map(
      (k, v) => MapEntry(k.toString(), v),
    );
    final common = (f['common'] as Map? ?? const <String, dynamic>{}).map(
      (k, v) => MapEntry(k.toString(), v),
    );

    state.selectedKeywordMode = preset.keywordMode;
    state.excludeKeywordController.text = preset.excludeKeyword;

    // イラスト
    state.selectedSearchTarget =
        (illust['searchTarget'] as String?) ?? state.selectedSearchTarget;
    state.selectedWorkType =
        (illust['workType'] as String?) ?? state.selectedWorkType;
    state.selectedAgeLimit =
        (illust['ageLimit'] as String?) ?? state.selectedAgeLimit;
    state.selectedDuration =
        (illust['duration'] as String?) ?? state.selectedDuration;
    state.selectedBookmarkFilter =
        (illust['bookmarkFilter'] as int?) ?? state.selectedBookmarkFilter;
    state.selectedIllustAiFilter =
        (illust['aiFilter'] as String?) ?? state.selectedIllustAiFilter;
    state.minBookmarkController.text =
        (illust['minBookmarkText'] as String?) ?? '';

    // 小説
    state.selectedNovelSearchTarget =
        (novel['searchTarget'] as String?) ?? state.selectedNovelSearchTarget;
    state.selectedNovelAgeLimit =
        (novel['ageLimit'] as String?) ?? state.selectedNovelAgeLimit;
    state.selectedNovelBookmarkFilter =
        (novel['bookmarkFilter'] as int?) ?? state.selectedNovelBookmarkFilter;
    state.selectedNovelTextLengthLimit =
        (novel['textLengthLimit'] as String?) ??
        state.selectedNovelTextLengthLimit;
    final minText = novel['minText'] as String?;
    final maxText = novel['maxText'] as String?;
    if (state.selectedNovelTextLengthLimit == 'custom') {
      if (minText != null && minText.isNotEmpty) {
        state.minTextLengthController ??= TextEditingController();
        state.minTextLengthController!.text = minText;
      }
      if (maxText != null && maxText.isNotEmpty) {
        state.maxTextLengthController ??= TextEditingController();
        state.maxTextLengthController!.text = maxText;
      }
    } else {
      state.minTextLengthController?.clear();
      state.maxTextLengthController?.clear();
    }
    state.selectedNovelSeriesTextLengthLimit =
        (novel['seriesTextLengthLimit'] as String?) ??
        state.selectedNovelSeriesTextLengthLimit;
    final seriesMin = novel['seriesMinText'] as String?;
    final seriesMax = novel['seriesMaxText'] as String?;
    if (state.selectedNovelSeriesTextLengthLimit == 'custom') {
      if (seriesMin != null && seriesMin.isNotEmpty) {
        state.minSeriesTextLengthController ??= TextEditingController();
        state.minSeriesTextLengthController!.text = seriesMin;
      }
      if (seriesMax != null && seriesMax.isNotEmpty) {
        state.maxSeriesTextLengthController ??= TextEditingController();
        state.maxSeriesTextLengthController!.text = seriesMax;
      }
    } else {
      state.minSeriesTextLengthController?.clear();
      state.maxSeriesTextLengthController?.clear();
    }
    state.selectedNovelAiFilter =
        (novel['aiFilter'] as String?) ?? state.selectedNovelAiFilter;
    state.novelSeriesOnly =
        (novel['seriesOnly'] as bool?) ?? state.novelSeriesOnly;
    final excludeTags = novel['excludeTags'];
    if (excludeTags is List) {
      state.novelExcludeTags
        ..clear()
        ..addAll(excludeTags.whereType<String>());
    }
    state.novelDensityMode =
        (novel['density'] as String?) ?? state.novelDensityMode;

    // 共通
    state.minBookmarkNumController.text = (common['bmNumMin'] as String?) ?? '';
    state.maxBookmarkNumController.text = (common['bmNumMax'] as String?) ?? '';
    state.useStartDate = (common['useStartDate'] as bool?) ?? false;
    state.startDateTime = _parsePresetDate(common['startDate']);
    state.useEndDate = (common['useEndDate'] as bool?) ?? false;
    state.endDateTime = _parsePresetDate(common['endDate']);
  }

  DateTime? _parsePresetDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  /// Phase 2 共通セクション（期間 / 日付範囲 / ブックマーク数範囲）。
  /// イラスト・小説の両シートで同一の UI を使う。
  /// [setModalState] はモダルの再描画用。
  Widget _buildCommonFilterSection(
    void Function(void Function()) setModalState,
  ) {
    final colorScheme = Theme.of(state.uiContext).colorScheme;
    // 日付範囲が有効なら duration を無視するため、その旨を補足表示する
    final dateRangeActive =
        state.useStartDate && state.startDateTime != null ||
        state.useEndDate && state.endDateTime != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFilterSectionTitle('期間'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildChoiceChip(
              label: 'すべて',
              isSelected: state.selectedDuration == 'all',
              onSelected: (bool value) {
                setModalState(() {
                  state.selectedDuration = 'all';
                });
                _saveFilterPrefs();
              },
            ),
            _buildChoiceChip(
              label: '1日以内',
              isSelected: state.selectedDuration == '1d',
              onSelected: (bool value) {
                setModalState(() {
                  state.selectedDuration = '1d';
                });
                _saveFilterPrefs();
              },
            ),
            _buildChoiceChip(
              label: '1週間以内',
              isSelected: state.selectedDuration == '7d',
              onSelected: (bool value) {
                setModalState(() {
                  state.selectedDuration = '7d';
                });
                _saveFilterPrefs();
              },
            ),
            _buildChoiceChip(
              label: '1ヶ月以内',
              isSelected: state.selectedDuration == '30d',
              onSelected: (bool value) {
                setModalState(() {
                  state.selectedDuration = '30d';
                });
                _saveFilterPrefs();
              },
            ),
            _buildChoiceChip(
              label: '半年以内',
              isSelected: state.selectedDuration == '180d',
              onSelected: (bool value) {
                setModalState(() {
                  state.selectedDuration = '180d';
                });
                _saveFilterPrefs();
              },
            ),
            _buildChoiceChip(
              label: '1年以内',
              isSelected: state.selectedDuration == '365d',
              onSelected: (bool value) {
                setModalState(() {
                  state.selectedDuration = '365d';
                });
                _saveFilterPrefs();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          dateRangeActive
              ? '※ 日付範囲が設定されているため、期間は無視されます'
              : 'API の duration パラメータとして送信されます',
          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
        ),
        const SizedBox(height: 24),

        _buildFilterSectionTitle('日付範囲（任意）'),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: state.pickStartDate,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                  state.useStartDate && state.startDateTime != null
                      ? _formatFilterDate(state.startDateTime!)
                      : '開始日を選択',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: state.pickEndDate,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                  state.useEndDate && state.endDateTime != null
                      ? _formatFilterDate(state.endDateTime!)
                      : '終了日を選択',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (state.useStartDate || state.useEndDate)
              TextButton(
                onPressed: () {
                  setModalState(() {
                    state.useStartDate = false;
                    state.useEndDate = false;
                    state.startDateTime = null;
                    state.endDateTime = null;
                  });
                  _saveFilterPrefs();
                },
                child: const Text('クリア', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        const SizedBox(height: 24),

        _buildFilterSectionTitle('ブックマーク数範囲（任意）'),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: state.minBookmarkNumController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '最小',
                  hintText: '例: 1000',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => _saveFilterPrefs(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: state.maxBookmarkNumController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '最大',
                  hintText: '例: 5000',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => _saveFilterPrefs(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '従来の「Nusers入り」フィルターとは別の数値範囲指定です（API パラメータ bookmark_num_min / bookmark_num_max）',
          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
        ),
      ],
    );
  }

  String _formatFilterDate(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  // 小説専用検索フィルターボトムシートの表示
  void showNovelFilterBottomSheet() {
    final colorScheme = Theme.of(state.uiContext).colorScheme;
    showModalBottomSheet(
      context: state.uiContext,
      backgroundColor: colorScheme.surfaceContainerHigh,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.85,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 5,
                          decoration: BoxDecoration(
                            color: colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // 検索ターゲット
                      _buildFilterSectionTitle('検索ターゲット'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: 'タグ（部分一致）',
                            isSelected:
                                state.selectedNovelSearchTarget ==
                                'partial_match_for_tags',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSearchTarget =
                                    'partial_match_for_tags';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'タグ（完全一致）',
                            isSelected:
                                state.selectedNovelSearchTarget ==
                                'exact_match_for_tags',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSearchTarget =
                                    'exact_match_for_tags';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'タグ・タイトル・説明',
                            isSelected:
                                state.selectedNovelSearchTarget ==
                                'title_and_caption',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSearchTarget =
                                    'title_and_caption';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          // 本文検索は小説のみ有効
                          _buildChoiceChip(
                            label: '本文',
                            isSelected:
                                state.selectedNovelSearchTarget == 'text',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSearchTarget = 'text';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '全てのテキスト（タグ+本文）',
                            isSelected:
                                state.selectedNovelSearchTarget == 'all_text',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSearchTarget = 'all_text';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 年齢制限
                      _buildFilterSectionTitle('年齢制限（x_restrict で絞り込み）'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '全年齢',
                            isSelected: state.selectedNovelAgeLimit == 'all',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelAgeLimit = 'all';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'R-18',
                            isSelected: state.selectedNovelAgeLimit == 'r18',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelAgeLimit = 'r18';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'R-18G',
                            isSelected: state.selectedNovelAgeLimit == 'r18g',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelAgeLimit = 'r18g';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // Phase 2: 共通フィルター（期間 / 日付範囲 / ブクマ数範囲）
                      _buildCommonFilterSection(setModalState),
                      const SizedBox(height: 24),

                      // ソート順
                      _buildFilterSectionTitle('ソート順'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '関連度',
                            isSelected: state.selectedSort == 'relevant',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSort = 'relevant';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '新着',
                            isSelected: state.selectedSort == 'date_desc',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSort = 'date_desc';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '古い',
                            isSelected: state.selectedSort == 'date_asc',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSort = 'date_asc';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // ブックマークフィルター
                      _buildFilterSectionTitle('ブックマークフィルター'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: 'ブックマークなし',
                            isSelected: state.selectedNovelBookmarkFilter == 0,
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelBookmarkFilter = 0;
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'ブックマークあり',
                            isSelected: state.selectedNovelBookmarkFilter > 0,
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelBookmarkFilter = 100;
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'マイブックマーク',
                            isSelected: state.selectedNovelBookmarkFilter == -1,
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelBookmarkFilter = -1;
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 文字数フィルター
                      _buildFilterSectionTitle('文字数フィルター'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '短い',
                            isSelected:
                                state.selectedNovelTextLengthLimit == 'short',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelTextLengthLimit = 'short';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '中くらい',
                            isSelected:
                                state.selectedNovelTextLengthLimit == 'medium',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelTextLengthLimit = 'medium';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '長い',
                            isSelected:
                                state.selectedNovelTextLengthLimit == 'long',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelTextLengthLimit = 'long';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'カスタム',
                            isSelected:
                                state.selectedNovelTextLengthLimit == 'custom',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelTextLengthLimit = 'custom';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      if (state.selectedNovelTextLengthLimit == 'custom') ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: state.minTextLengthController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '最小文字数',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (value) {
                                  _saveNovelFilterPrefs();
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextField(
                                controller: state.maxTextLengthController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '最大文字数',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (value) {
                                  _saveNovelFilterPrefs();
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),

                      // シリーズ文字数フィルター
                      _buildFilterSectionTitle('シリーズ文字数フィルター'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '短い',
                            isSelected:
                                state.selectedNovelSeriesTextLengthLimit ==
                                'short',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSeriesTextLengthLimit =
                                    'short';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '中くらい',
                            isSelected:
                                state.selectedNovelSeriesTextLengthLimit ==
                                'medium',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSeriesTextLengthLimit =
                                    'medium';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '長い',
                            isSelected:
                                state.selectedNovelSeriesTextLengthLimit ==
                                'long',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSeriesTextLengthLimit =
                                    'long';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'すべて',
                            isSelected:
                                state.selectedNovelSeriesTextLengthLimit ==
                                'all',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSeriesTextLengthLimit =
                                    'all';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      if (state.selectedNovelSeriesTextLengthLimit ==
                          'custom') ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: state.minSeriesTextLengthController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '最小文字数',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (value) {
                                  _saveNovelFilterPrefs();
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextField(
                                controller: state.maxSeriesTextLengthController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '最大文字数',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (value) {
                                  _saveNovelFilterPrefs();
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 32),

                      // プリセット保存ボタン（Phase N1）
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.bookmark_add, size: 18),
                          label: const Text('プリセットとして保存'),
                          onPressed: () =>
                              saveCurrentAsPreset(context, category: 'novel'),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 適用ボタン
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            state.fetchData();
                          },
                          child: const Text('適用'),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // フィルターボトムシートの表示
  void showFilterBottomSheet() {
    final colorScheme = Theme.of(state.uiContext).colorScheme;
    showModalBottomSheet(
      context: state.uiContext,
      backgroundColor: colorScheme.surfaceContainerHigh,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.85,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 5,
                          decoration: BoxDecoration(
                            color: colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // キーワード結合モード（AND / OR）と除外キーワード（NOT）
                      _buildFilterSectionTitle('キーワード条件'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: 'AND（すべて含む）',
                            isSelected: state.selectedKeywordMode == 'and',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedKeywordMode = 'and';
                              });
                            },
                          ),
                          _buildChoiceChip(
                            label: 'OR（いずれか含む）',
                            isSelected: state.selectedKeywordMode == 'or',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedKeywordMode = 'or';
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: state.excludeKeywordController,
                        decoration: const InputDecoration(
                          labelText: '除外キーワード（NOT・スペース区切り）',
                          hintText: '例: 腐向け ネタ',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // 検索ターゲット
                      _buildFilterSectionTitle('検索ターゲット'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          // pixiv App-API の search_target 有効値のみを選択させる
                          _buildChoiceChip(
                            label: 'タグ（部分一致）',
                            isSelected:
                                state.selectedSearchTarget ==
                                'partial_match_for_tags',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSearchTarget =
                                    'partial_match_for_tags';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'タグ（完全一致）',
                            isSelected:
                                state.selectedSearchTarget ==
                                'exact_match_for_tags',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSearchTarget =
                                    'exact_match_for_tags';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'タグ・タイトル・説明',
                            isSelected:
                                state.selectedSearchTarget ==
                                'title_and_caption',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSearchTarget =
                                    'title_and_caption';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 年齢制限
                      _buildFilterSectionTitle('年齢制限（x_restrict で絞り込み）'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '全年齢のみ',
                            isSelected: state.selectedAgeLimit == 'all',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedAgeLimit = 'all';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'R-18を含む',
                            isSelected: state.selectedAgeLimit == 'include_r18',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedAgeLimit = 'include_r18';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'R-18のみ',
                            isSelected: state.selectedAgeLimit == 'r18',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedAgeLimit = 'r18';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'R-18Gを含む',
                            isSelected: state.selectedAgeLimit == 'r18g',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedAgeLimit = 'r18g';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // AIフィルター（アプリ内ローカル適用）
                      _buildFilterSectionTitle('AIフィルター'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: 'すべて',
                            isSelected: state.selectedIllustAiFilter == 'all',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedIllustAiFilter = 'all';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'AI以外',
                            isSelected: state.selectedIllustAiFilter == 'hide',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedIllustAiFilter = 'hide';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'AIのみ',
                            isSelected: state.selectedIllustAiFilter == 'only',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedIllustAiFilter = 'only';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 最小ブックマーク数
                      _buildFilterSectionTitle('最小ブックマーク数'),
                      Row(
                        children: [
                          SizedBox(
                            width: 140,
                            child: TextField(
                              controller: state.minBookmarkController,
                              keyboardType: TextInputType.number,
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 13,
                              ),
                              decoration: InputDecoration(
                                hintText: '例: 1000',
                                hintStyle: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                                filled: true,
                                fillColor: colorScheme.surfaceContainerHighest,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '以上',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 作品タイプ
                      _buildFilterSectionTitle('作品タイプ'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '漫画',
                            isSelected: state.selectedWorkType == 'manga',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedWorkType = 'manga';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'イラスト',
                            isSelected:
                                state.selectedWorkType == 'illustration',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedWorkType = 'illustration';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'なし',
                            isSelected: state.selectedWorkType == 'none',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedWorkType = 'none';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // NOTE: 従来の「時間帯」セクションは Phase 2 の共通セクション
                      // （期間 / 日付範囲 / ブクマ数範囲、下部の _buildCommonFilterSection）
                      // に統合されたため削除した。

                      // ソート順
                      _buildFilterSectionTitle('ソート順'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '関連度順',
                            isSelected: state.selectedSort == 'relevant',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSort = 'relevant';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '新着順',
                            isSelected: state.selectedSort == 'date_desc',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSort = 'date_desc';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '古い順',
                            isSelected: state.selectedSort == 'date_asc',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSort = 'date_asc';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // ブックマークフィルター
                      _buildFilterSectionTitle('ブックマークフィルター'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: 'ブックマークなし',
                            isSelected: state.selectedBookmarkFilter == 0,
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedBookmarkFilter = 0;
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'ブックマークあり',
                            isSelected: state.selectedBookmarkFilter > 0,
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedBookmarkFilter = 100;
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'マイブックマーク',
                            isSelected: state.selectedBookmarkFilter == -1,
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedBookmarkFilter = -1;
                              });
                              _saveFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      // Phase 2: 共通フィルター（期間 / 日付範囲 / ブクマ数範囲）
                      _buildCommonFilterSection(setModalState),
                      const SizedBox(height: 32),

                      // リセットボタン
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: colorScheme.primary),
                          ),
                          onPressed: () {
                            setModalState(() {
                              state.selectedSearchTarget =
                                  'partial_match_for_tags';
                              state.selectedWorkType = 'all';
                              state.selectedAgeLimit = 'all';
                              state.selectedDuration = 'all';
                              state.selectedSort = 'date_desc';
                              state.selectedBookmarkFilter = 0;
                              state.selectedIllustAiFilter = 'all';
                              state.minBookmarkController.clear();
                              // Phase 2: 共通フィルターもリセット
                              resetCommonFilterState();
                            });
                            persistFilterPrefs();
                          },
                          child: Text(
                            'フィルターをリセット',
                            style: TextStyle(color: colorScheme.primary),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // プリセット保存ボタン（Phase N1）
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.bookmark_add, size: 18),
                          label: const Text('プリセットとして保存'),
                          onPressed: () =>
                              saveCurrentAsPreset(context, category: 'illust'),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 適用ボタン
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            state.fetchData();
                          },
                          child: const Text('適用'),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // ボトムシートセクションタイトルビルダー
  Widget _buildFilterSectionTitle(String title) {
    final colorScheme = Theme.of(state.uiContext).colorScheme;
    return Text(
      title,
      style: TextStyle(
        color: colorScheme.onSurface,
        fontWeight: FontWeight.bold,
        fontSize: 13,
      ),
    );
  }

  // ChoiceChipのカスタムスタイルビルダー
  Widget _buildChoiceChip({
    required String label,
    required bool isSelected,
    required ValueChanged<bool> onSelected,
  }) {
    final colorScheme = Theme.of(state.uiContext).colorScheme;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: isSelected
              ? colorScheme.onPrimary
              : colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      selected:
          isSelected, // ← ここが `isSelected:` だった。ChoiceChip API では `selected:` が正しい
      selectedColor: colorScheme.primary.withValues(alpha: 0.35),
      backgroundColor: colorScheme.surfaceContainerHighest,
      elevation: isSelected ? 2 : 0,
      pressElevation: 4,
      onSelected: onSelected,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isSelected
              ? colorScheme.primary.withValues(alpha: 0.6)
              : Colors.transparent,
          width: 1,
        ),
      ),
    );
  }
}
