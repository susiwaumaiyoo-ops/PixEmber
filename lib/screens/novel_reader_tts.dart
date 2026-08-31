// ignore_for_file: invalid_use_of_protected_member
part of 'novel_reader_screen.dart';

/// 小説TTS読み上げの制御（Phase 3）。
///
/// - OS標準TTSエンジンのみ使用（クラウドTTS不使用）
/// - 自動スクロールとは排他（読み上げ開始時に自動スクロールを停止）
/// - 読み上げ再開位置は DB v18 の tts_reading_positions に永続化
///   （端末ローカルの位置情報のため Google Drive バックアップ対象外）
/// - スリープタイマー満了時は TTS も自動停止（_startSleepTimer 側で連携）
extension _ReaderTts on _NovelReaderScreenState {
  /// TTSサービスを遅延生成する（初回読み上げ時にエンジンを初期化）。
  NovelTtsService get _tts =>
      _ttsService ??= NovelTtsService(FlutterTtsEngine());

  /// AppBar/HUD のトグル: 再生→一時停止 / 一時停止→再開 / 停止→開始。
  Future<void> _toggleTts() async {
    if (_isTtsPlaying && !_isTtsPaused) {
      await _tts.pause();
    } else if (_isTtsPaused) {
      // resume() は再生セッション終了まで完了しないため unawaited で呼ぶ
      unawaited(_tts.resume());
    } else {
      await _startTts();
    }
  }

  /// 読み上げを開始する。
  ///
  /// [forcedIndex] が指定されればそのチャンクから（設定変更後の再開用）。
  /// 未指定なら「保存済み再開位置（現在ページ以前の場合のみ）」または
  /// 「現在ページの先頭チャンク」から開始する。
  Future<void> _startTts({int? forcedIndex}) async {
    if (_ttsInitializing) return; // 二重開始防止
    final pages = _textData?.novelPages;
    if (pages == null || pages.isEmpty) {
      _showTtsSnack('本文が読み込まれていません');
      return;
    }
    _ttsInitializing = true;
    try {
      // 自動スクロールとは排他（同時に使わない）
      if (_isAutoScrolling) _stopAutoScroll();

      final chunks = chunkNovelForSpeech(pages, readRuby: _ttsReadRuby);
      if (chunks.isEmpty) {
        _showTtsSnack('読み上げ可能な本文がありません');
        return;
      }
      _ttsChunkTotal = chunks.length;

      var start =
          forcedIndex ?? _findFirstChunkIndexForPage(chunks, _savedPageIndex);
      final resume = _ttsResumeIndex;
      if (forcedIndex == null &&
          resume != null &&
          resume >= 0 &&
          resume < chunks.length) {
        // 保存位置が現在ページより前ならそこから、現在ページより後ろなら現在ページ優先
        if (chunks[resume].pageIndex <= _savedPageIndex) start = resume;
      }
      _ttsResumeIndex = null; // 保存位置は使い切り

      _tts.onStateChanged = _onTtsStateChanged;
      _tts.onChunkStart = _onTtsChunkStart;
      _tts.onAllCompleted = _onTtsAllCompleted;
      _tts.onError = (msg) => _showTtsSnack(msg);
      unawaited(_tts.start(chunks, startIndex: start, rate: _ttsRate));
    } finally {
      _ttsInitializing = false;
    }
  }

  /// 読み上げを完全に停止する（idle へ）。
  Future<void> _stopTts() async {
    _ttsResumeIndex = null;
    await _tts.stop();
    _syncTtsUiState(TtsState.idle);
  }

  /// 別エピソード遷移用の即時停止ヘルパ。
  /// Snack 表示や await を伴わず UI 状態のみリセットする（エンジンは使い続ける）。
  void _stopTtsSync() {
    _ttsResumeIndex = null;
    unawaited(_tts.stop());
    _syncTtsUiState(TtsState.idle);
  }

  /// TTS状態変化をUIへ反映する。
  void _onTtsStateChanged(TtsState state) {
    _syncTtsUiState(state);
  }

  void _syncTtsUiState(TtsState state) {
    _safeSetState(() {
      _isTtsPlaying = state == TtsState.playing || state == TtsState.paused;
      _isTtsPaused = state == TtsState.paused;
      if (state == TtsState.idle || state == TtsState.error) {
        _ttsCurrentIndex = -1;
      }
    });
  }

  /// 各チャンク読み上げ開始時: ページ追従 + 再開位置の永続化。
  void _onTtsChunkStart(int index, TtsChunk chunk) {
    _ttsCurrentIndex = index;
    // 読み上げページへ PageView を追従させる
    if (mounted && !_isDisposing && chunk.pageIndex != _savedPageIndex) {
      _pageController?.animateToPage(
        chunk.pageIndex,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
    unawaited(
      DatabaseService()
          .saveTtsPosition(
            workId: _currentNovel.id,
            chunkIndex: index,
            pageIndex: chunk.pageIndex,
          )
          .then((_) {})
          .catchError((e) {
            debugPrint('TTS位置の保存に失敗しました（無視）: $e');
          }),
    );
  }

  /// 全チャンク読了時: 再開位置をクリア（次回は最初から）。
  void _onTtsAllCompleted() {
    _syncTtsUiState(TtsState.completed);
    unawaited(
      DatabaseService()
          .deleteTtsPosition(_currentNovel.id)
          .then((_) {})
          .catchError((e) {
            debugPrint('TTS位置の削除に失敗しました（無視）: $e');
          }),
    );
  }

  /// 指定ページの先頭チャンク番号を求める（チャンクはページ順に整列済み）。
  int _findFirstChunkIndexForPage(List<TtsChunk> chunks, int pageIndex) {
    if (chunks.isEmpty) return 0;
    var result = 0;
    for (var i = 0; i < chunks.length; i++) {
      if (chunks[i].pageIndex < pageIndex) {
        result = i + 1;
      } else {
        break;
      }
    }
    return result.clamp(0, chunks.length - 1);
  }

  /// 本文ロード後、保存済みTTS再開位置（DB v18）をロードする。
  Future<void> _loadTtsResumeIndex() async {
    try {
      final row = await DatabaseService().getTtsPosition(_currentNovel.id);
      if (!mounted || _isDisposing || row == null) return;
      final chunkIndex = row['chunk_index'] as int? ?? 0;
      final pageIndex = row['page_index'] as int? ?? 0;
      // 再開位置のページへ表示も移動しておく
      final totalPages = _textData?.novelPages.length ?? 0;
      if (pageIndex != _savedPageIndex &&
          pageIndex >= 0 &&
          pageIndex < totalPages) {
        _savedPageIndex = pageIndex;
        _savedScrollOffset = 0.0;
        _pageController?.jumpToPage(pageIndex);
        _currentPageNotifier.value = pageIndex;
        _updateProgress(pageIndex, 0.0);
      }
      _ttsResumeIndex = chunkIndex;
    } catch (e) {
      debugPrint('TTS再開位置のロードに失敗しました（無視）: $e');
    }
  }

  /// 読み上げ速度変更（下部HUDスライダーから、即時反映）。
  void _onTtsRateChanged(double value) {
    _safeSetState(() => _ttsRate = value);
    unawaited(_tts.setRate(value));
    _savePreferences(); // 速度を永続化
  }

  /// TTS設定ダイアログ（速度・ルビ読み方）。
  Future<void> _showTtsSettingsDialog() async {
    final isDark = _themeMode == 2;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var rate = _ttsRate;
        var readRuby = _ttsReadRuby;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            title: const Text('読み上げ設定'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('速度: x${rate.toStringAsFixed(1)}'),
                Slider(
                  value: rate.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2.0,
                  divisions: 6,
                  activeColor: Colors.pinkAccent,
                  onChanged: (v) => setDialogState(() => rate = v),
                ),
                SwitchListTile(
                  value: readRuby,
                  activeThumbColor: Colors.pinkAccent,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('ルビ（かな）を読み上げ'),
                  subtitle: const Text('OFF なら親文字（漢字）をそのまま読み上げます'),
                  onChanged: (v) => setDialogState(() => readRuby = v),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  final wasPlaying = _isTtsPlaying;
                  final resumeIdx = _ttsCurrentIndex;
                  _safeSetState(() {
                    _ttsRate = rate;
                    _ttsReadRuby = readRuby;
                  });
                  unawaited(_tts.setRate(rate));
                  _savePreferences();
                  // ルビ読み方を変えた場合は読み上げテキストが変わるため、
                  // 再生中なら現在位置から読み直す。
                  if (wasPlaying) {
                    await _stopTts();
                    if (mounted && !_isDisposing) {
                      unawaited(
                        _startTts(forcedIndex: resumeIdx < 0 ? 0 : resumeIdx),
                      );
                    }
                  }
                },
                child: const Text('適用'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showTtsSnack(String message) {
    if (!mounted || _isDisposing) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }
}
