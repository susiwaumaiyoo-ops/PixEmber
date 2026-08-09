// ignore_for_file: invalid_use_of_protected_member
part of 'novel_reader_screen.dart';

extension _ReaderUiHandler on _NovelReaderScreenState {
  // 自動スクロールの制御
  void _toggleAutoScroll() {
    if (_isAutoScrolling) {
      _stopAutoScroll();
    } else {
      _startAutoScroll();
    }
  }

  void _startAutoScroll() {
    _stopAutoScroll();
    _safeSetState(() {
      _isAutoScrolling = true;
      _showHUD = false; // 自動スクロール開始時はHUDを閉じて読書に没頭させる
    });
    _safeNotifyHud(_showHUD);

    // 自動スクロール開始時にしおりを永続化
    _saveCurrentBookmark();

    // 50ミリ秒ごとにわずかにスクロールさせるタイマー
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 50), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel(); // 👈 画面が破棄されていたらタイマーをキャンセルして即座に終了
        return;
      }
      if (_pageController == null) return;
      final currentPage = _pageController!.hasClients
          ? _pageController!.page?.round() ?? 0
          : _savedPageIndex;

      if (currentPage < _scrollControllers.length) {
        final controller = _scrollControllers[currentPage];
        if (controller.hasClients) {
          final maxExtent = controller.position.maxScrollExtent;
          final currentPixels = controller.position.pixels;

          if (currentPixels >= maxExtent - 1.0) {
            // ページの末尾に達した
            _stopAutoScroll();
            final totalPages = _textData?.novelPages.length ?? 1;
            if (currentPage < totalPages - 1) {
              // 次のページへ遷移
              _pageController?.nextPage(
                duration: const Duration(milliseconds: 800),
                curve: Curves.easeInOut,
              );
              // 1.5秒待ってから自動スクロールを再起動 (余韻をもたせる)
              Future.delayed(const Duration(milliseconds: 1500), () {
                if (mounted && !_isAutoScrolling && _pageController != null) {
                  final newPage = _pageController!.page?.round() ?? 0;
                  if (newPage > currentPage) {
                    _startAutoScroll();
                  }
                }
              });
            }
          } else {
            // スピードに応じたスクロール (1〜10の速度に対応)
            // 50msなので、速度3であれば 1.5ピクセルずつ動かす
            final delta = _scrollSpeed * 0.4;
            controller.jumpTo((currentPixels + delta).clamp(0.0, maxExtent));
          }
        }
      }
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    if (mounted) {
      _safeSetState(() {
        _isAutoScrolling = false;
      });
    }
    // 自動スクロール停止時にしおりを永続化
    _saveCurrentBookmark();
  }

  // ===== ページ内検索 =====
  void _runSearch(String query) {
    final q = query.trim();
    setState(() {
      _searchQuery = q;
      _searchPageMatches = [];
      _searchMatchIndex = -1;
    });
    if (q.isEmpty) return;
    final pages = _textData?.novelPages ?? [];
    final matches = <int>[];
    for (int i = 0; i < pages.length; i++) {
      if (pages[i].contains(q)) {
        matches.add(i);
      }
    }
    setState(() {
      _searchPageMatches = matches;
      if (matches.isNotEmpty) {
        _searchMatchIndex = 0;
        _jumpToSearchResult(0);
      }
    });
  }

  void _jumpToSearchResult(int resultIndex) {
    if (_searchPageMatches.isEmpty) return;
    final page =
        _searchPageMatches[resultIndex.clamp(0, _searchPageMatches.length - 1)];
    if (_pageController != null && _pageController!.hasClients) {
      _pageController!.animateToPage(
        page,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    } else {
      _savedPageIndex = page;
    }
    // 検索結果へジャンプ後は自動スクロールを止める
    if (_isAutoScrolling) _stopAutoScroll();
  }

  void _goToNextSearchMatch() {
    if (_searchPageMatches.isEmpty) return;
    final next = (_searchMatchIndex + 1) % _searchPageMatches.length;
    setState(() => _searchMatchIndex = next);
    _jumpToSearchResult(next);
  }

  void _goToPrevSearchMatch() {
    if (_searchPageMatches.isEmpty) return;
    final prev =
        (_searchMatchIndex - 1 + _searchPageMatches.length) %
        _searchPageMatches.length;
    setState(() => _searchMatchIndex = prev);
    _jumpToSearchResult(prev);
  }

  // ===== スリープタイマー =====
  void _startSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _safeSetState(() {
      _sleepMinutes = minutes;
      _sleepRemainingSeconds = minutes * 60;
    });
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _sleepRemainingSeconds -= 1;
      if (_sleepRemainingSeconds <= 0) {
        timer.cancel();
        _sleepTimer = null;
        _safeSetState(() => _sleepMinutes = null);
        // 時間になったら自動スクロールを停止して通知
        if (_isAutoScrolling) _stopAutoScroll();
        _showSleepTimerExpiredSnack();
      } else {
        _safeSetState(() {});
      }
    });
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _safeSetState(() {
      _sleepMinutes = null;
      _sleepRemainingSeconds = 0;
    });
  }

  void _showSleepTimerExpiredSnack() {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('スリープタイマーが終了しました（自動スクロールを停止）'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  String _formatSleepRemaining() {
    final m = _sleepRemainingSeconds ~/ 60;
    final s = _sleepRemainingSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _showSleepTimerDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF222222),
          title: const Text(
            'スリープタイマー',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_sleepMinutes != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '残り時間: ${_formatSleepRemaining()}',
                    style: const TextStyle(
                      color: Colors.pinkAccent,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [5, 10, 15, 30, 45, 60].map((min) {
                  final selected = _sleepMinutes == min;
                  return ChoiceChip(
                    label: Text('$min分'),
                    selected: selected,
                    selectedColor: Colors.pinkAccent,
                    labelStyle: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                    ),
                    onSelected: (_) {
                      _startSleepTimer(min);
                      Navigator.pop(context);
                    },
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            if (_sleepMinutes != null)
              TextButton(
                onPressed: () {
                  _cancelSleepTimer();
                  Navigator.pop(context);
                },
                child: const Text('キャンセル'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  // 検索バーの表示/非表示を切り替え
  void _toggleSearchBar() {
    setState(() {
      _showSearchBar = !_showSearchBar;
      if (!_showSearchBar) {
        _searchQuery = '';
        _searchPageMatches = [];
        _searchMatchIndex = -1;
      }
    });
  }

  // 背景色テーマ定義
  Color _getBgColor() {
    switch (_themeMode) {
      case 0:
        return const Color(0xFFFAFAFA); // ホワイト
      case 1:
        return const Color(0xFFF5EEDC); // セピア（読書用紙風）
      case 2:
      default:
        return const Color(0xFF121212); // 漆黒
    }
  }

  // 文字色定義
  Color _getTextColor() {
    switch (_themeMode) {
      case 0:
        return const Color(0xFF1E1E1E);
      case 1:
        return const Color(0xFF4A341A); // 深い焦げ茶
      case 2:
      default:
        return const Color(0xFFE0E0E0); // ライトグレー
    }
  }

  Novel? _getPreviousNovel() {
    if (_seriesNovels.isEmpty) return null;
    final currentIndex = _seriesNovels.indexWhere(
      (n) => n.id == _currentNovel.id,
    );
    if (currentIndex > 0) {
      return _seriesNovels[currentIndex - 1];
    }
    return null;
  }

  Novel? _getNextNovel() {
    if (_seriesNovels.isEmpty) return null;
    final currentIndex = _seriesNovels.indexWhere(
      (n) => n.id == _currentNovel.id,
    );
    if (currentIndex != -1 && currentIndex < _seriesNovels.length - 1) {
      return _seriesNovels[currentIndex + 1];
    }
    return null;
  }

  // 環境設定HUD（ボトム調整パネル）の表示
  void _showCustomizationHUD() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _themeMode == 2 ? const Color(0xFF1F1F1F) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isDark = _themeMode == 2;
            final sheetTextColor = isDark ? Colors.white : Colors.black87;

            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '読書環境カスタマイズ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: sheetTextColor,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),

                    // 背景テーマ切り替え
                    Text(
                      '背景テーマ',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildThemeButton(
                          0,
                          'ホワイト',
                          const Color(0xFFFAFAFA),
                          Colors.black,
                          setSheetState,
                        ),
                        const SizedBox(width: 10),
                        _buildThemeButton(
                          1,
                          'セピア紙',
                          const Color(0xFFF5EEDC),
                          const Color(0xFF4A341A),
                          setSheetState,
                        ),
                        const SizedBox(width: 10),
                        _buildThemeButton(
                          2,
                          '漆黒極夜',
                          const Color(0xFF121212),
                          Colors.white70,
                          setSheetState,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // フォント書体
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'フォント書体',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SegmentedButton<String>(
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: 'serif',
                              label: Text(
                                '明朝体',
                                style: TextStyle(
                                  fontFamily: 'serif',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            ButtonSegment(
                              value: 'sans-serif',
                              label: Text(
                                'ゴシック',
                                style: TextStyle(
                                  fontFamily: 'sans-serif',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            ButtonSegment(
                              value: 'monospace',
                              label: Text(
                                '等幅',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                          selected: {_fontFamily},
                          onSelectionChanged: (newSelection) {
                            _safeSetState(() {
                              _fontFamily = newSelection.first;
                              _cachedPages = null; // 本文キャッシュを無効化
                            });
                            setSheetState(() {});
                            _savePreferences();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // 文字サイズ
                    _buildSliderRow(
                      label: '文字サイズ',
                      value: _fontSize,
                      min: 12.0,
                      max: 28.0,
                      displayValue: '${_fontSize.round()} pt',
                      onChanged: (val) {
                        _safeSetState(() {
                          _fontSize = val;
                          _cachedPages = null; // 本文キャッシュを無効化
                        });
                        setSheetState(() {});
                        _savePreferences();
                      },
                    ),

                    // 行間
                    _buildSliderRow(
                      label: '行間マージン',
                      value: _lineHeight,
                      min: 1.4,
                      max: 2.6,
                      displayValue: _lineHeight.toStringAsFixed(1),
                      onChanged: (val) {
                        _safeSetState(() {
                          _lineHeight = val;
                          _cachedPages = null; // 本文キャッシュを無効化
                        });
                        setSheetState(() {});
                        _savePreferences();
                      },
                    ),

                    // 左マージン
                    _buildSliderRow(
                      label: '左マージン',
                      value: _leftPadding,
                      min: 12.0,
                      max: 400.0,
                      displayValue: '${_leftPadding.round()} px',
                      onChanged: (val) {
                        _safeSetState(() {
                          _leftPadding = val;
                          _cachedPages = null; // 本文キャッシュを無効化
                        });
                        setSheetState(() {});
                        _savePreferences();
                      },
                    ),
                    const SizedBox(height: 16),
                    // 右マージン
                    _buildSliderRow(
                      label: '右マージン',
                      value: _rightPadding,
                      min: 12.0,
                      max: 400.0,
                      displayValue: '${_rightPadding.round()} px',
                      onChanged: (val) {
                        _safeSetState(() {
                          _rightPadding = val;
                          _cachedPages = null; // 本文キャッシュを無効化
                        });
                        setSheetState(() {});
                        _savePreferences();
                      },
                    ),

                    // 自動スクロール速度（自動スクロール中にも使える）
                    _buildSliderRow(
                      label: '自動スクロール速度',
                      value: _scrollSpeed,
                      min: 1.0,
                      max: 10.0,
                      displayValue: 'Lv ${_scrollSpeed.toStringAsFixed(1)}',
                      onChanged: (val) {
                        _safeSetState(() {
                          _scrollSpeed = val;
                        });
                        setSheetState(() {});
                        _savePreferences();
                        // 動作中の場合は自動更新される
                      },
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildThemeButton(
    int mode,
    String label,
    Color bg,
    Color text,
    StateSetter setSheetState,
  ) {
    final isSelected = _themeMode == mode;
    return Expanded(
      child: InkWell(
        onTap: () {
          _safeSetState(() {
            _themeMode = mode;
            _cachedPages = null; // 本文キャッシュを無効化
          });
          setSheetState(() {});
          _savePreferences();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? Colors.pinkAccent
                  : Colors.grey.withValues(alpha: 0.3),
              width: isSelected ? 2.5 : 1.0,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.pinkAccent.withValues(alpha: 0.2),
                      blurRadius: 4,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: text,
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
  }) {
    final isDark = _themeMode == 2;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white70 : Colors.black87,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                displayValue,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.pinkAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            activeColor: Colors.pinkAccent,
            inactiveColor: Colors.grey.withValues(alpha: 0.3),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
