import 'home_screen_state.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// フィルター関連メソッドを管理するクラス
class HomeFilterHandler {
  final PixivViewerHomeState state;

  HomeFilterHandler(this.state);

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
  }

  // 小説専用検索フィルターボトムシートの表示
  void showNovelFilterBottomSheet() {
    showModalBottomSheet(
      context: state.uiContext,
      backgroundColor: const Color(0xFF161616),
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
                            color: Colors.grey[700],
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
                            label: 'タイトル',
                            isSelected:
                                state.selectedNovelSearchTarget == 'title',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSearchTarget = 'title';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '説明',
                            isSelected:
                                state.selectedNovelSearchTarget ==
                                'description',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedNovelSearchTarget = 'description';
                              });
                              _saveNovelFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '全てのテキスト',
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
                      _buildFilterSectionTitle('年齢制限'),
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
    showModalBottomSheet(
      context: state.uiContext,
      backgroundColor: const Color(0xFF1A1A1A),
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
                            color: Colors.grey[700],
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
                            label: 'タイトル',
                            isSelected: state.selectedSearchTarget == 'title',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSearchTarget = 'title';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '説明',
                            isSelected:
                                state.selectedSearchTarget == 'description',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSearchTarget = 'description';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'タグ',
                            isSelected: state.selectedSearchTarget == 'tags',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedSearchTarget = 'tags';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // 年齢制限
                      _buildFilterSectionTitle('年齢制限'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '全年齢',
                            isSelected: state.selectedAgeLimit == 'all',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedAgeLimit = 'all';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'R-18',
                            isSelected: state.selectedAgeLimit == 'r18',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedAgeLimit = 'r18';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: 'R-18G',
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

                      // 時間帯
                      _buildFilterSectionTitle('時間帯'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildChoiceChip(
                            label: '24時間',
                            isSelected: state.selectedDuration == 'all',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedDuration = 'all';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '過去24時間',
                            isSelected: state.selectedDuration == '1d',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedDuration = '1d';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '過去7日間',
                            isSelected: state.selectedDuration == '7d',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedDuration = '7d';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                          _buildChoiceChip(
                            label: '過去30日間',
                            isSelected: state.selectedDuration == '30d',
                            onSelected: (bool value) {
                              setModalState(() {
                                state.selectedDuration = '30d';
                              });
                              _saveFilterPrefs();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

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
                      const SizedBox(height: 32),

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
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white,
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
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.white : Colors.grey[400],
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      selected:
          isSelected, // ← ここが `isSelected:` だった。ChoiceChip API では `selected:` が正しい
      selectedColor: Colors.pinkAccent.withValues(alpha: 0.8),
      backgroundColor: const Color(0xFF2E2E2E),
      elevation: isSelected ? 2 : 0,
      pressElevation: 4,
      onSelected: onSelected,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isSelected ? Colors.pinkAccent : Colors.transparent,
          width: 1,
        ),
      ),
    );
  }
}
