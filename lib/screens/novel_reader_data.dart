// ignore_for_file: invalid_use_of_protected_member
part of 'novel_reader_screen.dart';

extension _ReaderData on _NovelReaderScreenState {
  // 非同期の初期化シーケンス（.then チェーンを避け、順序制御を安全に行う）
  Future<void> _initSequence() async {
    await _loadPreferences();
    if (!mounted) return;
    await _initAndFetch();
    // あとで読むに登録済みかつ未読なら「読書中」へ自動遷移（last_opened_at 更新）。
    // read_later 未登録の小説は何もしない（余計な自動登録はしない）。
    await _markReadLaterReading();
  }

  /// あとで読む登録済みの未読小説を「読書中」へ自動遷移させる。
  Future<void> _markReadLaterReading() async {
    try {
      final db = DatabaseService();
      final registered = await db.isReadLater(_currentNovel.id);
      if (!registered) return;
      final rows = await db.getReadLaterList();
      final mine = rows.where((r) => r['work_id'] == _currentNovel.id).toList();
      if (mine.isEmpty) return;
      final current = mine.first['status'] as int? ?? 0;
      if (current == 0) {
        await db.updateReadLaterStatus(_currentNovel.id, 1);
      }
    } catch (e) {
      debugPrint('あとで読む自動遷移(読書中)に失敗しました（無視）: $e');
    }
  }

  // 永続化された設定（文字サイズやテーマなど）のロード
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _fontSize = prefs.getDouble('novel_pref_font_size') ?? 18.0;
        _lineHeight = prefs.getDouble('novel_pref_line_height') ?? 1.8;
        _leftPadding = prefs.getDouble('novel_pref_left_padding') ?? 24.0;
        _rightPadding = prefs.getDouble('novel_pref_right_padding') ?? 24.0;
        _themeMode = prefs.getInt('novel_pref_theme_mode') ?? 1;
        _fontFamily = prefs.getString('novel_pref_font_family') ?? 'serif';
        _scrollSpeed = prefs.getDouble('novel_pref_scroll_speed') ?? 3.0;
        _ttsRate = prefs.getDouble('novel_pref_tts_rate') ?? 1.0;
        _ttsReadRuby = prefs.getBool('novel_pref_tts_read_ruby') ?? false;
        final rubyModeStr = prefs.getString('novel_pref_ruby_mode') ?? 'show';
        _rubyMode = RubyDisplayMode.values.firstWhere(
          (mode) => mode.name == rubyModeStr,
          orElse: () => RubyDisplayMode.show,
        );
      });
    } catch (e) {
      debugPrint('環境設定の読み込みに失敗しました: $e');
    }
  }

  // 設定の保存
  Future<void> _savePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      await prefs.setDouble('novel_pref_font_size', _fontSize);
      await prefs.setDouble('novel_pref_line_height', _lineHeight);
      await prefs.setDouble('novel_pref_left_padding', _leftPadding);
      await prefs.setDouble('novel_pref_right_padding', _rightPadding);
      await prefs.setInt('novel_pref_theme_mode', _themeMode);
      await prefs.setString('novel_pref_font_family', _fontFamily);
      await prefs.setDouble('novel_pref_scroll_speed', _scrollSpeed);
      await prefs.setDouble('novel_pref_tts_rate', _ttsRate);
      await prefs.setBool('novel_pref_tts_read_ruby', _ttsReadRuby);
      await prefs.setString('novel_pref_ruby_mode', _rubyMode.name);
    } catch (e) {
      debugPrint('環境設定の保存に失敗しました: $e');
    }
  }

  Future<void> _initAndFetch() async {
    _stopAutoScroll();
    if (!mounted) return;
    _safeSetState(() {
      _isLoading = true;
      _errorMessage = null;
      _textData = null;
    });

    // しおりのロード
    await _loadBookmark();
    // 本文の取得
    await _fetchNovelText();
    // 履歴登録
    _recordHistory();
    // シリーズ一覧の取得（未取得の場合、または別シリーズに移動した場合）
    // 無効なシリーズID（0 や null）の場合は不要なAPI通信エラー(400)を防ぐため呼び出さない
    if (_currentNovel.series != null && _currentNovel.series!.id != 0) {
      _fetchSeriesNovels();
    }
  }

  // 別エピソードへのシームレス遷移
  void _jumpToNovel(Novel targetNovel) {
    _stopAutoScroll();
    _stopTtsSync(); // 別エピソード遷移時はTTS読み上げも停止
    _ttsResumeIndex = null;
    _pageController?.dispose();
    for (var controller in _scrollControllers) {
      controller.dispose();
    }
    _scrollControllers = [];

    _safeSetState(() {
      _currentNovel = targetNovel;
      _savedPageIndex = 0;
      _savedScrollOffset = 0.0;
      _cachedPages = null; // 別エピソードへ遷移するため本文キャッシュを無効化
    });
    _initAndFetch();
  }

  Future<void> _recordHistory() async {
    try {
      final db = DatabaseService();
      await db.insertOrUpdateHistory(
        workId: _currentNovel.id,
        title: _currentNovel.title,
        authorName: _currentNovel.author.name,
        previewUrl: _currentNovel.coverUrl,
        type: 'novel',
      );
    } catch (e) {
      debugPrint("⚠️ [History Save Error] 履歴の保存に失敗しました（処理は続行します）: $e");
    }
  }

  Future<void> _loadBookmark() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      _savedPageIndex = prefs.getInt('novel_page_${_currentNovel.id}') ?? 0;
      _savedScrollOffset =
          prefs.getDouble('novel_offset_${_currentNovel.id}') ?? 0.0;
    } catch (e) {
      debugPrint('しおりのロードに失敗しました: $e');
    }
  }

  Future<void> _saveBookmark(int pageIndex, double offset) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      await prefs.setInt('novel_page_${_currentNovel.id}', pageIndex);
      await prefs.setDouble('novel_offset_${_currentNovel.id}', offset);

      // 進捗率の計算
      final totalPages = _textData?.novelPages.length ?? 1;
      double pageProgress = 0.0;
      if (_scrollControllers.isNotEmpty &&
          pageIndex < _scrollControllers.length) {
        final controller = _scrollControllers[pageIndex];
        if (controller.hasClients && controller.position.maxScrollExtent > 0) {
          final maxExtent = controller.position.maxScrollExtent;
          final pixels = controller.position.pixels.clamp(0.0, maxExtent);
          pageProgress = pixels / maxExtent;
        }
      }

      double progress = ((pageIndex + pageProgress) / totalPages) * 100.0;
      progress = progress.clamp(0.0, 100.0);

      await prefs.setDouble('novel_progress_${_currentNovel.id}', progress);
      await prefs.setInt('novel_total_pages_${_currentNovel.id}', totalPages);
      await prefs.setString(
        'novel_title_${_currentNovel.id}',
        _currentNovel.title,
      );
      await prefs.setString(
        'novel_author_${_currentNovel.id}',
        _currentNovel.author.name,
      );
      await prefs.setInt(
        'novel_last_read_${_currentNovel.id}',
        DateTime.now().millisecondsSinceEpoch,
      );
      // しおり一覧のカード表示に必要な最小メタデータを保存側でも揃える
      await prefs.setString(
        'novel_cover_${_currentNovel.id}',
        _currentNovel.coverUrl,
      );
      await prefs.setInt(
        'novel_page_count_${_currentNovel.id}',
        _currentNovel.pageCount,
      );
      await prefs.setInt(
        'novel_text_length_${_currentNovel.id}',
        _currentNovel.textLength,
      );
      await prefs.setInt(
        'novel_saved_at_${_currentNovel.id}',
        DateTime.now().millisecondsSinceEpoch,
      );
      // 完全な Novel メタデータは DB に一本化して保存する
      await DatabaseService().saveNovel(_currentNovel);

      // 履歴一覧に追加
      final List<String> bookmarkedIds =
          prefs.getStringList('novel_bookmark_ids') ?? [];
      final String idStr = _currentNovel.id.toString();
      if (!bookmarkedIds.contains(idStr)) {
        bookmarkedIds.add(idStr);
        await prefs.setStringList('novel_bookmark_ids', bookmarkedIds);
      }
    } catch (e) {
      debugPrint('しおりの保存に失敗しました: $e');
    }
  }

  // 現在の表示位置（ページ＋スクロールオフセット）からしおりを永続化するヘルパ
  Future<void> _saveCurrentBookmark() async {
    if (!mounted) return;
    final page = _pageController?.hasClients == true
        ? _pageController!.page?.round() ?? _savedPageIndex
        : _savedPageIndex;
    final offset =
        (page < _scrollControllers.length &&
            _scrollControllers[page].hasClients)
        ? _scrollControllers[page].position.pixels
        : _savedScrollOffset;
    await _saveBookmark(page, offset);
  }

  void _setupScrollControllers(int count) {
    for (var controller in _scrollControllers) {
      controller.dispose();
    }
    _scrollControllers = List.generate(count, (index) => ScrollController());

    for (int i = 0; i < _scrollControllers.length; i++) {
      _scrollControllers[i].addListener(() {
        // 👈 破棄中、またはすでにマウントされていない場合は即時終了
        if (_isDisposing || !mounted) return;

        final currentPage = _pageController?.hasClients == true
            ? _pageController!.page?.round() ?? 0
            : _savedPageIndex;
        // スクロール中はメモリ上の変数のみ更新し、I/O（SharedPreferences書き込み）は行わない
        // （秒間数十回のディスク書き込みによるカクつきを完全に防止）
        if (currentPage == i) {
          _savedScrollOffset = _scrollControllers[i].position.pixels;
          _savedPageIndex = i;
          _updateProgress(i, _savedScrollOffset);
        }
      });
    }
  }

  // 現在のページ＋ページ内スクロール位置から読書進捗（0.0〜1.0）を算出して通知する
  void _updateProgress(int page, double offset) {
    final totalPages = _textData?.novelPages.length ?? 1;
    if (totalPages <= 0) return;
    double fraction = 0.0;
    if (page < _scrollControllers.length) {
      final c = _scrollControllers[page];
      if (c.hasClients && c.position.maxScrollExtent > 0) {
        fraction =
            (c.position.pixels.clamp(0.0, c.position.maxScrollExtent) /
                    c.position.maxScrollExtent)
                .clamp(0.0, 1.0);
      }
    }
    final progress = ((page + fraction) / totalPages).clamp(0.0, 1.0);
    _progressNotifier.value = progress;

    // あとで読む登録済み作品の場合、進捗率と最終位置を保存（再開・進捗表示用）。
    _saveReadLaterProgress(page, progress);

    // あとで読む登録済み作品が本文末尾（進捗 100%）に到達したら「読了」へ自動遷移。
    if (progress >= 0.999) {
      _markReadLaterFinished();
    }
  }

  /// あとで読む登録済み作品の読書進捗・最終位置を読書中に保存する。
  /// 頻度は「1%以上変化したとき」のみに絞りDB書き込みを抑える。
  void _saveReadLaterProgress(int page, double progress) {
    final id = _currentNovel.id;
    _lastSavedReadLaterProgress ??= -1.0;
    final changedPct = ((progress - _lastSavedReadLaterProgress!) * 100).abs();
    if (changedPct < 1.0) return;
    _lastSavedReadLaterProgress = progress;
    unawaited(
      DatabaseService()
          .isReadLater(id)
          .then((registered) async {
            if (!registered) return;
            final db = DatabaseService();
            await db.updateReadLaterProgress(id, progress);
            await db.updateReadLaterPosition(
              id,
              page,
              _savedScrollOffset.round(),
            );
          })
          .catchError((e) {
            debugPrint('あとで読む進捗保存に失敗しました（無視）: $e');
          }),
    );
  }

  /// あとで読む登録済み作品を「読了」へ自動遷移させる（最終ページ到達時）。
  /// 連続発火を防ぐため、既に読了済みなら何もしない。
  Future<void> _markReadLaterFinished() async {
    try {
      final db = DatabaseService();
      final registered = await db.isReadLater(_currentNovel.id);
      if (!registered) return;
      final rows = await db.getReadLaterList();
      final mine = rows.where((r) => r['work_id'] == _currentNovel.id).toList();
      if (mine.isEmpty) return;
      final current = mine.first['status'] as int? ?? 0;
      if (current != 2) {
        await db.updateReadLaterStatus(_currentNovel.id, 2);
      }
    } catch (e) {
      debugPrint('あとで読む自動遷移(読了)に失敗しました（無視）: $e');
    }
  }

  Future<void> _fetchNovelText() async {
    debugPrint('📍 [DEBUG Reader] _fetchNovelText 開始');
    try {
      final api = PixivApiService();
      debugPrint(
        '📍 [DEBUG Reader] _fetchNovelText API呼び出し直前: ${_currentNovel.id}',
      );
      final textData = await api.getNovelText(_currentNovel.id);
      debugPrint('📍 [DEBUG Reader] _fetchNovelText API呼び出し成功');

      // オフライン再読のためローカルにキャッシュ
      await _saveNovelTextToDb(textData);

      if (mounted) _applyTextData(textData);
    } catch (e) {
      // 通信失敗（オフライン等）→ キャッシュから復元を試みる
      try {
        final cached = await _loadNovelTextFromDb();
        if (cached != null && mounted) {
          debugPrint('📍 [DEBUG Reader] オフラインキャッシュから復元');
          _applyTextData(cached);
          return;
        }
      } catch (_) {
        // キャッシュも失敗 → そのままエラー表示
      }
      if (mounted) {
        _safeSetState(() {
          _errorMessage = '小説本文の取得に失敗しました: $e';
          _isLoading = false;
        });
      }
    }
  }

  // 取得した本文を状態へ反映する（API / キャッシュの両経路で共通利用）
  void _applyTextData(NovelTextData textData) {
    _safeSetState(() {
      _textData = textData;
      _isLoading = false;

      final totalPages = _textData?.novelPages.length ?? 1;
      if (_savedPageIndex >= totalPages) {
        _savedPageIndex = 0;
        _savedScrollOffset = 0.0;
      }

      _pageController = PageController(initialPage: _savedPageIndex);
      _currentPageNotifier.value = _savedPageIndex;
      _setupScrollControllers(totalPages);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_savedPageIndex < _scrollControllers.length) {
        final controller = _scrollControllers[_savedPageIndex];
        if (controller.hasClients) {
          controller.jumpTo(_savedScrollOffset);
        }
      }
      _updateProgress(_savedPageIndex, _savedScrollOffset);
      // TTS再開位置（DB v18）を非同期でロード（結果は _ttsResumeIndex に保持）
      _loadTtsResumeIndex();
    });
  }

  Future<void> _saveNovelTextToDb(NovelTextData data) async {
    try {
      await DatabaseService().saveNovelText(
        workId: data.id,
        title: _currentNovel.title,
        authorName: _currentNovel.author.name,
        text: data.novelText,
        pagesJson: jsonEncode(data.novelPages),
        illustrationsJson: data.illustrations.isEmpty
            ? null
            : jsonEncode(data.illustrations),
      );

      // ベクトル生成・保存（バックグラウンドで実行、失敗してもUIをブロックしない）
      // AIモデル未ダウンロード時はスキップ（裏処理なのでユーザー動作をブロックしない）
      try {
        if (await RuriModelManager().isModelPresent()) {
          final embeddingService = EmbeddingService();
          final textForEmbedding = buildNovelDocumentText(
            _currentNovel,
            bodyText: data.novelText,
          );
          final embedding = await embeddingService.encodeDocument(
            textForEmbedding,
          );
          await DatabaseService().saveNovelEmbedding(
            workId: data.id,
            embedding: embedding,
          );
          // フィーリング検索用メタデータを novels テーブルに保存
          await DatabaseService().saveNovel(_currentNovel);
        }
      } catch (e) {
        debugPrint('ベクトル生成・保存に失敗しました（無視して続行）: $e');
      }
    } catch (e) {
      debugPrint('小説本文のキャッシュに失敗しました: $e');
    }
  }

  Future<NovelTextData?> _loadNovelTextFromDb() async {
    try {
      final row = await DatabaseService().getNovelText(_currentNovel.id);
      if (row == null) return null;
      final pages = List<String>.from(
        jsonDecode(row['pages_json'] as String) as List,
      );
      final illustrations = <String, String>{};
      final rawIllustrations = row['illustrations_json'] as String?;
      if (rawIllustrations != null && rawIllustrations.isNotEmpty) {
        final decoded = jsonDecode(rawIllustrations);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value != null) {
              illustrations[key.toString()] = value.toString();
            }
          });
        }
      }
      return NovelTextData(
        id: _currentNovel.id,
        novelText: row['text'] as String,
        novelPages: pages,
        illustrations: illustrations,
      );
    } catch (e) {
      debugPrint('小説本文キャッシュの読み込みに失敗しました: $e');
      return null;
    }
  }

  Future<void> _fetchSeriesNovels() async {
    debugPrint('📍 [DEBUG Reader] _fetchSeriesNovels 開始');
    final series = _currentNovel.series;
    if (series == null) return;

    _safeSetState(() {
      _isLoadingSeries = true;
    });

    try {
      final api = PixivApiService();
      debugPrint(
        '📍 [DEBUG Reader] _fetchSeriesNovels API呼び出し直前: ${series.id}',
      );
      final list = await api.getNovelSeries(series.id);
      debugPrint('📍 [DEBUG Reader] _fetchSeriesNovels API呼び出し成功');

      if (!mounted) return;
      _safeSetState(() {
        _seriesNovels = list;
        _isLoadingSeries = false;
      });
    } catch (e) {
      debugPrint('シリーズ一覧取得エラー: $e');
      // 画面が Pop 途中の場合は defunct エラーを防ぐため生存確認を最優先で行う
      if (!mounted) return;
      _safeSetState(() => _isLoadingSeries = false);
    }
  }
}
