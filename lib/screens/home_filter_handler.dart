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
                      _buildFilterSectionTitle('年齢制限'),
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
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                              decoration: InputDecoration(
                                hintText: '例: 1000',
                                hintStyle: TextStyle(
                                  color: Colors.grey[500],
                                  fontSize: 13,
                                ),
                                filled: true,
                                fillColor: const Color(0xFF2E2E2E),
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
                              color: Colors.grey[400],
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

                      // リセットボタン
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.pinkAccent),
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
                            });
                          },
                          child: const Text(
                            'フィルターをリセット',
                            style: TextStyle(color: Colors.pinkAccent),
                          ),
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
