part of 'novel_reader_screen.dart';

extension _ReaderUiComponents on _NovelReaderScreenState {
  // 検索バーUI
  Widget _buildSearchBar(bool isDark) {
    final textColor = isDark ? Colors.white70 : Colors.black54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: isDark ? Colors.black87 : Colors.white,
      child: Row(
        children: [
          Icon(Icons.search, size: 20, color: textColor),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black87,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                hintText: '本文内を検索',
                hintStyle: TextStyle(color: textColor),
                border: InputBorder.none,
              ),
              onChanged: _runSearch,
              onSubmitted: (_) => _goToNextSearchMatch(),
            ),
          ),
          if (_searchPageMatches.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '${_searchMatchIndex + 1}/${_searchPageMatches.length}',
                style: TextStyle(color: textColor, fontSize: 12),
              ),
            ),
          IconButton(
            icon: Icon(Icons.arrow_upward, size: 18, color: textColor),
            onPressed: _goToPrevSearchMatch,
            tooltip: '前の候補',
          ),
          IconButton(
            icon: Icon(Icons.arrow_downward, size: 18, color: textColor),
            onPressed: _goToNextSearchMatch,
            tooltip: '次の候補',
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: textColor),
            onPressed: _toggleSearchBar,
            tooltip: '閉じる',
          ),
        ],
      ),
    );
  }

  // 下部HUDコントロールバー
  Widget _buildBottomHUD(bool isDark) {
    final totalPages = _textData?.novelPages.length ?? 1;
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: 12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 5,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ページ番号は ValueNotifier で局所更新（setState回避で本文の再レイアウトを防止）
          ValueListenableBuilder<int>(
            valueListenable: _currentPageNotifier,
            builder: (context, pageIndex, _) {
              final currentPage = pageIndex + 1;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'エピソード進捗',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                      Text(
                        '$currentPage / $totalPages ページ',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.pinkAccent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 簡易スライダーでページジャンプ
                  if (totalPages > 1)
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                      ),
                      child: Slider(
                        value: currentPage.toDouble().clamp(
                          1.0,
                          totalPages.toDouble(),
                        ),
                        min: 1.0,
                        max: totalPages.toDouble(),
                        activeColor: Colors.pinkAccent,
                        inactiveColor: Colors.grey.withValues(alpha: 0.3),
                        onChanged: (val) {
                          final targetPage = val.round() - 1;
                          _pageController?.jumpToPage(targetPage);
                          _currentPageNotifier.value =
                              targetPage; // setState回避で局所更新
                        },
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),

          // 自動スクロール簡易トグル + 速度調整インジケーター
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // クイック自動スクロールスイッチ
              InkWell(
                onTap: _toggleAutoScroll,
                child: Row(
                  children: [
                    Icon(
                      _isAutoScrolling ? Icons.pause : Icons.play_arrow,
                      color: Colors.pinkAccent,
                      size: 18,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isAutoScrolling ? 'スクロール停止' : '自動スクロール',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.pinkAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              // 簡易カスタマイズボタン
              TextButton.icon(
                onPressed: _showCustomizationHUD,
                icon: const Icon(
                  Icons.tune,
                  size: 16,
                  color: Colors.pinkAccent,
                ),
                label: const Text(
                  'クイック設定',
                  style: TextStyle(fontSize: 12, color: Colors.pinkAccent),
                ),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),

          // TTS読み上げコントロール（Phase 3: 再生中のみ表示）
          if (_isTtsPlaying) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                // 一時停止 / 再開
                IconButton(
                  icon: Icon(
                    _isTtsPaused ? Icons.play_arrow : Icons.pause,
                    color: Colors.pinkAccent,
                  ),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _toggleTts,
                  tooltip: _isTtsPaused ? '読み上げを再開' : '読み上げを一時停止',
                ),
                // 停止
                IconButton(
                  icon: const Icon(Icons.stop, color: Colors.pinkAccent),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _stopTts,
                  tooltip: '読み上げを停止',
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isTtsPaused
                            ? '一時停止中（チャンプ ${_ttsCurrentIndex + 1}/$_ttsChunkTotal）'
                            : '読み上げ中（チャンプ ${_ttsCurrentIndex + 1}/$_ttsChunkTotal）',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                      // 読み上げ速度調整（0.5x - 2.0x）
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 10,
                          ),
                        ),
                        child: Slider(
                          value: _ttsRate.clamp(0.5, 2.0),
                          min: 0.5,
                          max: 2.0,
                          divisions: 6,
                          label: 'x${_ttsRate.toStringAsFixed(1)}',
                          activeColor: Colors.pinkAccent,
                          inactiveColor: Colors.grey.withValues(alpha: 0.3),
                          onChanged: _onTtsRateChanged,
                        ),
                      ),
                    ],
                  ),
                ),
                // 読み上げ設定（速度・ルビ読み方）
                IconButton(
                  icon: Icon(
                    Icons.settings,
                    size: 20,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _showTtsSettingsDialog,
                  tooltip: '読み上げ設定',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 「あと約XX分」ラベルを生成する（Phase A）。
  /// 文字数不明時は空文字（表示しない）。進捗は 0.0〜1.0。
  String _remainingTimeLabel(double progress) {
    var totalChars = _currentNovel.textLength;
    if (totalChars <= 0 && _textData != null) {
      totalChars = _textData!.novelPages.fold<int>(
        0,
        (sum, p) => sum + p.length,
      );
    }
    if (totalChars <= 0) return '';
    final remaining = (totalChars * (1.0 - progress.clamp(0.0, 1.0))).round();
    final minutes = estimateRemainingMinutes(remaining, _readerCpm);
    if (minutes <= 0) return 'まもなく読了';
    return 'あと約$minutes分';
  }

  // 本文目次（TOC）の各ページラベルを生成（各ページの先頭行を抜粋）
  List<String> _buildTocLabels() {
    final pages = _textData?.novelPages ?? [];
    return pages.asMap().entries.map((e) {
      final firstLine = e.value
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '');
      final label = firstLine.length > 22
          ? '${firstLine.substring(0, 22)}…'
          : firstLine;
      return label.isEmpty ? 'ページ ${e.key + 1}' : label;
    }).toList();
  }

  // 本文目次 Drawer コンテンツ
  Widget _buildNovelTocDrawer(bool isDark) {
    final sheetTextColor = isDark ? Colors.white : Colors.black87;
    final labels = _buildTocLabels();

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                const Icon(Icons.menu_book, color: Colors.pinkAccent),
                const SizedBox(width: 8),
                Text(
                  '本文目次',
                  style: TextStyle(
                    color: sheetTextColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.grey),
          Expanded(
            child: labels.isEmpty
                ? Center(
                    child: Text(
                      '目次がありません。',
                      style: TextStyle(
                        color: sheetTextColor.withValues(alpha: 0.6),
                      ),
                    ),
                  )
                : ValueListenableBuilder<int>(
                    valueListenable: _currentPageNotifier,
                    builder: (context, currentPage, _) {
                      return ListView.builder(
                        itemCount: labels.length,
                        itemBuilder: (context, index) {
                          final isCurrent = index == currentPage;
                          return ListTile(
                            dense: true,
                            selected: isCurrent,
                            selectedTileColor: Colors.pinkAccent.withValues(
                              alpha: 0.15,
                            ),
                            leading: Text(
                              '${index + 1}',
                              style: TextStyle(
                                color: isCurrent
                                    ? Colors.pinkAccent
                                    : sheetTextColor.withValues(alpha: 0.5),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            title: Text(
                              labels[index],
                              style: TextStyle(
                                color: sheetTextColor,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _pageController?.jumpToPage(index);
                            },
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // シリーズ目次 Drawer コンテンツ
  Widget _buildSeriesDrawerContent(bool isDark) {
    final sheetTextColor = isDark ? Colors.white : Colors.black87;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.auto_stories,
                      color: Colors.pinkAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _currentNovel.series?.title ?? 'シリーズ目次',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: sheetTextColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '連載エピソード一覧',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.grey),
          Expanded(
            child: _isLoadingSeries
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.pinkAccent),
                  )
                : _seriesNovels.isEmpty
                ? const Center(
                    child: Text(
                      'シリーズのエピソードが\n見つかりませんでした。',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _seriesNovels.length,
                    itemBuilder: (context, idx) {
                      final item = _seriesNovels[idx];
                      final isCurrent = item.id == _currentNovel.id;

                      return InkWell(
                        onTap: () {
                          Navigator.pop(context); // Drawerを閉じる
                          _jumpToNovel(item);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          color: isCurrent
                              ? Colors.pinkAccent.withValues(alpha: 0.1)
                              : Colors.transparent,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // 話数インデックス
                              Container(
                                width: 24,
                                alignment: Alignment.center,
                                child: Text(
                                  '${idx + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: isCurrent
                                        ? Colors.pinkAccent
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // エピソードタイトル
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: isCurrent
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: isCurrent
                                            ? Colors.pinkAccent
                                            : sheetTextColor,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (item.caption.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        item.caption,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.grey[600],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (isCurrent) ...[
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.menu_book,
                                  color: Colors.pinkAccent,
                                  size: 16,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // 小説本文をページ単位で表示
  Widget _buildNovelPages(Color textColor) {
    final pages = _textData?.novelPages ?? [];
    debugPrint('📍 [DEBUG Reader] ループ開始: pages.length = ${pages.length}');

    if (pages.isEmpty) {
      final text = _textData?.novelText ?? '本文がありません。';
      return _buildPageContent(text, textColor, 0, 1);
    }

    // スワイプバック等で build が毎フレーム呼ばれても全文を再構築しないようキャッシュする。
    // 本文/テーマ/フォント/シリーズ等の「内容に影響する状態」が変わったときだけ再構築する。
    final signature = _pagesSignature(textColor, pages.length);
    if (_cachedPages == null || _cachedPagesSignature != signature) {
      _cachedPages = List.generate(pages.length, (i) {
        return _buildPageContent(pages[i], textColor, i, pages.length);
      });
      _cachedPagesSignature = signature;
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: pages.length,
      // 1ページのみのときは横スワイプを無効化し、左端のシステム「戻る」ジェスチャーを
      // PageView が奪わないようにする（これが swipe-back 時の back-invoke ループ/ANR の根因）
      physics: pages.length <= 1 ? const NeverScrollableScrollPhysics() : null,
      onPageChanged: (index) {
        _savedPageIndex = index;
        _savedScrollOffset = 0.0;
        _currentPageNotifier.value = index; // 局所的にHUDのみ更新（setState回避）
        _updateProgress(index, 0.0);
        _saveBookmark(index, 0.0); // ページ切り替わり時のみ永続化
      },
      itemBuilder: (context, index) {
        debugPrint('📍 [DEBUG Reader] ループ中: index = $index / ${pages.length}');
        return _cachedPages![index];
      },
    );
  }

  // ページ本文キャッシュの妥当性を判定する署名（内容に影響する状態のみを含める）
  String _pagesSignature(Color textColor, int pageCount) {
    return '$textColor|$_themeMode|$_fontSize|$_lineHeight|'
        '$_leftPadding|$_rightPadding|$_fontFamily|'
        '${_currentNovel.id}|${_currentNovel.title}|${_currentNovel.author.name}|'
        '${_seriesNovels.length}|$pageCount|'
        '${_rubyMode.name}|$_searchQuery|$_illustrationsSignature';
  }

  // 挿絵 URL マップの署名（未解決 → 解決済みの変化でキャッシュを再構築させる）。
  String get _illustrationsSignature {
    final map = _textData?.illustrations ?? const {};
    if (map.isEmpty) return 'none';
    return '${map.length}:${map.keys.join('|').hashCode}';
  }

  // 各ページのコンテンツ描画
  Widget _buildPageContent(
    String content,
    Color textColor,
    int pageIndex,
    int totalPages,
  ) {
    final ScrollController? sController =
        _scrollControllers.isNotEmpty && pageIndex < _scrollControllers.length
        ? _scrollControllers[pageIndex]
        : null;

    final prevNovel = _getPreviousNovel();
    final nextNovel = _getNextNovel();
    final hasSeriesControl = _currentNovel.series != null;

    return Column(
      children: [
        // 1. ページヘッダー（没頭モード中は透明化 / HUD状態はローカル通知で切り替え）
        ValueListenableBuilder<bool>(
          valueListenable: _showHUDNotifier,
          builder: (context, showHUD, _) {
            return AnimatedOpacity(
              opacity: showHUD ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: Padding(
                padding: EdgeInsets.only(
                  top: kToolbarHeight + MediaQuery.of(context).padding.top + 10,
                  left: 20,
                  right: 20,
                  bottom: 10,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _currentNovel.author.name,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                    ),
                    Text(
                      '${pageIndex + 1} / $totalPages ページ',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),

        // 2. 本文スクロール領域
        Expanded(
          child: SingleChildScrollView(
            controller: sController,
            padding: EdgeInsets.fromLTRB(_leftPadding, 12, _rightPadding, 160),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 最初のページのみ小説の表題・作者名を表示
                if (pageIndex == 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    _currentNovel.title,
                    style: TextStyle(
                      fontSize: _fontSize + 6.0,
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                      color: textColor,
                      fontFamily: _fontFamily,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '著者：${_currentNovel.author.name}',
                    style: TextStyle(
                      fontSize: _fontSize - 2.0,
                      color: textColor.withValues(alpha: 0.8),
                      fontFamily: _fontFamily,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 36),
                  const Divider(color: Colors.grey, thickness: 0.5),
                  const SizedBox(height: 30),
                ],

                // 本文（段落列描画 + ルビ行送り拡張 + 挿絵ブロック / Phase 1 案B''）
                _buildPageBody(content, textColor),

                // 最終ページの場合のみ、シリーズ用ナビゲーションUIを表示
                if (pageIndex == totalPages - 1 && hasSeriesControl) ...[
                  const SizedBox(height: 60),
                  const Divider(color: Colors.grey, thickness: 0.5),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      '――― シリーズ小説ナビゲーション ―――',
                      style: TextStyle(
                        fontSize: 12,
                        color: textColor.withValues(alpha: 0.5),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // 前の話
                      ElevatedButton.icon(
                        onPressed: prevNovel != null
                            ? () => _jumpToNovel(prevNovel)
                            : null,
                        icon: const Icon(Icons.arrow_back, size: 16),
                        label: const Text('前の話'),
                        style: ElevatedButton.styleFrom(
                          foregroundColor: _themeMode == 0
                              ? Colors.black87
                              : Colors.white,
                          backgroundColor: _themeMode == 0
                              ? Colors.grey[200]
                              : Colors.grey[800],
                          disabledForegroundColor: Colors.grey.withValues(
                            alpha: 0.3,
                          ),
                          disabledBackgroundColor: Colors.grey.withValues(
                            alpha: 0.1,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // 目次
                      ElevatedButton.icon(
                        onPressed: () {
                          // Drawerを安全に開くためのキー経由アクセス
                          _scaffoldKey.currentState?.openEndDrawer();
                        },
                        icon: const Icon(Icons.format_list_bulleted, size: 16),
                        label: const Text('目次一覧'),
                        style: ElevatedButton.styleFrom(
                          foregroundColor: Colors.pinkAccent,
                          backgroundColor: _themeMode == 0
                              ? Colors.pink[50]
                              : const Color(0xFF2C1C24),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // 次の話
                      ElevatedButton.icon(
                        onPressed: nextNovel != null
                            ? () => _jumpToNovel(nextNovel)
                            : null,
                        icon: const Icon(Icons.arrow_forward, size: 16),
                        label: const Text('次の話'),
                        style: ElevatedButton.styleFrom(
                          foregroundColor: _themeMode == 0
                              ? Colors.black87
                              : Colors.white,
                          backgroundColor: _themeMode == 0
                              ? Colors.grey[200]
                              : Colors.grey[800],
                          disabledForegroundColor: Colors.grey.withValues(
                            alpha: 0.3,
                          ),
                          disabledBackgroundColor: Colors.grey.withValues(
                            alpha: 0.1,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 30),
                ],
              ],
            ),
          ),
        ),

        // 3. 読書進捗バー（常時表示：どこまで読んだかを読書中に確認可能）
        ValueListenableBuilder<double>(
          valueListenable: _progressNotifier,
          builder: (context, progress, _) {
            final totalPages = _textData?.novelPages.length ?? 1;
            final currentPage = _currentPageNotifier.value;
            final percent = (progress * 100).round();
            return Padding(
              padding: EdgeInsets.only(
                bottom: 6 + MediaQuery.of(context).padding.bottom,
                left: 20,
                right: 20,
              ),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: textColor.withValues(alpha: 0.15),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _themeMode == 1 ? Colors.pinkAccent : Colors.tealAccent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$percent% 読了',
                            style: TextStyle(
                              fontSize: 10,
                              color: textColor.withValues(alpha: 0.5),
                            ),
                          ),
                          // 残りの読了予測（Phase A / 設定でON/OFF）
                          if (_showReadingTime &&
                              _remainingTimeLabel(progress).isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              _remainingTimeLabel(progress),
                              style: TextStyle(
                                fontSize: 10,
                                color: textColor.withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                          // 現在位置の感情色（Phase C / 設定でON/OFF）
                          if (_showEmotionColor)
                            ValueListenableBuilder<
                              ({Color color, String label})?
                            >(
                              valueListenable: _emotionColorNotifier,
                              builder: (context, emotion, _) {
                                if (emotion == null) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: emotion.color,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '現在: ${emotion.label}',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: textColor.withValues(
                                            alpha: 0.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                      Text(
                        '${currentPage + 1} / $totalPages ページ',
                        style: TextStyle(
                          fontSize: 10,
                          color: textColor.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),

        // 4. ページフッター（没頭モード中は透明化 / HUD状態はローカル通知で切り替え）
        ValueListenableBuilder<bool>(
          valueListenable: _showHUDNotifier,
          builder: (context, showHUD, _) {
            return AnimatedOpacity(
              opacity: showHUD ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: 12 + MediaQuery.of(context).padding.bottom,
                  top: 8,
                  left: 20,
                  right: 20,
                ),
                child: Center(
                  child: Text(
                    'タップしてメニューをトグル',
                    style: TextStyle(
                      fontSize: 10,
                      color: textColor.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // ===== 本文描画（Phase 1: 段落列化 + 案B'' 行送り拡張 + 挿絵ブロック）=====

  // 1 ページ分の本文を NovelBlock 列へパースし、段落列 + 挿絵ブロックとして描画する。
  Widget _buildPageBody(String content, Color textColor) {
    final blocks = NovelParser.parsePage(content);
    final children = <Widget>[];
    var uploadedIndex = 0;
    for (final block in blocks) {
      switch (block) {
        case PageBreakBlock():
          // ページ分割は getNovelText 済みのため本文描画では無視する
          break;
        case UploadedImageBlock(:final localId):
          children.add(
            _buildUploadedImageBlock(localId, uploadedIndex++, textColor),
          );
        case PixivImageBlock():
          children.add(_buildPixivImageBlock(block, textColor));
        case ParagraphBlock():
          children.add(_buildParagraphBlock(block, textColor));
      }
    }
    if (children.isEmpty) {
      children.add(_buildParagraphBlock(const ParagraphBlock([]), textColor));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  // 1 段落を描画する。ルビ段落（show モード時）のみ行送りを拡張する（案B''）。
  Widget _buildParagraphBlock(ParagraphBlock block, Color textColor) {
    final isRubyParagraph = _rubyMode == RubyDisplayMode.show && block.hasRuby;
    final heightRatio = isRubyParagraph
        ? NovelParser.rubyLineHeightRatio(_fontSize, _lineHeight)
        : _lineHeight;
    // 空段落は半角スペース 1 個で行送りを保持する（空 RichText は高さゼロになるため）
    final runs = block.runs.isEmpty
        ? const <InlineRun>[PlainText(' ')]
        : NovelParser.collapseRunsForDisplay(block.runs, _rubyMode);

    final spans = <InlineSpan>[];
    for (final run in runs) {
      switch (run) {
        case PlainText(:final text):
          spans.add(
            TextSpan(
              text: text,
              style: _paragraphTextStyle(
                textColor,
                heightRatio,
                highlight: text,
              ),
            ),
          );
        case RubyInline(:final base, :final ruby):
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    ruby,
                    style: TextStyle(
                      fontSize: _fontSize * 0.5,
                      height: 1.0,
                      color: textColor,
                      fontFamily: _fontFamily,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  Text(
                    base,
                    style: TextStyle(
                      fontSize: _fontSize,
                      height: 1.0,
                      color: textColor,
                      fontFamily: _fontFamily,
                      letterSpacing: 0.8,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
      }
    }

    return RichText(
      text: TextSpan(children: spans),
      textAlign: TextAlign.left,
    );
  }

  // 段落テキスト用の共通 TextStyle（行送り拡張 + 検索ハイライトを含む）。
  TextStyle _paragraphTextStyle(
    Color textColor,
    double heightRatio, {
    String? highlight,
  }) {
    final isHit =
        highlight != null &&
        _searchQuery.isNotEmpty &&
        highlight.contains(_searchQuery);
    return TextStyle(
      fontSize: _fontSize,
      height: heightRatio,
      color: textColor,
      fontFamily: _fontFamily,
      letterSpacing: 0.8,
      backgroundColor: isHit ? Colors.yellow.withValues(alpha: 0.6) : null,
    );
  }

  // ===== 挿絵ブロック（Phase 1 設計書 §5）=====

  // 挿絵画像の最大表示高さ（縦長画像が画面を埋め尽くさないよう shortestSide の 3/4）。
  double get _illustrationMaxHeight =>
      MediaQuery.of(context).size.shortestSide * 3 / 4;

  // [uploadedimage:ID]（textEmbeddedImages 由来・Phase 0 確定キー）。
  Widget _buildUploadedImageBlock(
    String localId,
    int indexInPage,
    Color textColor,
  ) {
    final url = _textData?.illustrations[localId];
    final tag = '[uploadedimage:$localId]';
    if (url == null || url.isEmpty) {
      return _buildIllustrationPlaceholder(
        tag: tag,
        textColor: textColor,
        isLoading: false,
        onTap: _retryIllustrations,
      );
    }
    return Padding(
      key: ValueKey('uploaded_${localId}_$indexInPage'),
      padding: EdgeInsets.zero,
      child: _buildNovelIllustrationImage(
        url: url,
        tag: tag,
        textColor: textColor,
      ),
    );
  }

  // [pixivimage:ID] / [pixivimage:ID-page]。
  // 解決順: DB illustrations → メモリ LRU → getIllustById（FutureBuilder）。
  Widget _buildPixivImageBlock(PixivImageBlock block, Color textColor) {
    final cacheKey = 'pixiv:${block.illustId}:${block.page ?? 0}';
    final pageTag = block.page == null ? '' : '-${block.page}';
    final tag = '[pixivimage:${block.illustId}$pageTag]';

    final cachedUrl = _textData?.illustrations[cacheKey];
    if (cachedUrl != null && cachedUrl.isNotEmpty) {
      return _buildNovelIllustrationImage(
        url: cachedUrl,
        tag: tag,
        textColor: textColor,
      );
    }

    final memoIllust = _illustMemoryCache[block.illustId];
    if (memoIllust != null) {
      final url = _originalUrlForIllust(memoIllust, block.page);
      if (url != null && url.isNotEmpty) {
        return _buildNovelIllustrationImage(
          url: url,
          tag: tag,
          textColor: textColor,
        );
      }
    }

    return FutureBuilder<Illust?>(
      key: ValueKey('pixiv_${block.illustId}_${block.page ?? 0}'),
      future: _resolveIllustForPixivImage(block.illustId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildIllustrationPlaceholder(
            tag: tag,
            textColor: textColor,
            isLoading: true,
            onTap: null,
          );
        }
        final url = snapshot.data == null
            ? null
            : _originalUrlForIllust(snapshot.data!, block.page);
        if (url == null || url.isEmpty) {
          return _buildIllustrationPlaceholder(
            tag: tag,
            textColor: textColor,
            isLoading: false,
            onTap: () => _retryPixivImage(block),
          );
        }
        return _buildNovelIllustrationImage(
          url: url,
          tag: tag,
          textColor: textColor,
        );
      },
    );
  }

  // 解決済み Illust から pixivimage の original URL を決める
  // （0 始まり page・page 越過時は 1 始まり再解釈・表紙 fallback）。
  String? _originalUrlForIllust(Illust illust, int? requestedPage) {
    return NovelParser.resolvePixivImageUrl(
      coverOriginal: illust.urls.original,
      metaPageOriginals: [for (final p in illust.metaPages) p.original],
      requestedPage: requestedPage,
    );
  }

  // getIllustById による illust 解決（メモリ LRU 上限 20 + 進行中リクエストの重複排除）。
  Future<Illust?> _resolveIllustForPixivImage(int illustId) {
    final memo = _illustMemoryCache[illustId];
    if (memo != null) {
      // LRU 更新（remove → insert）
      _illustMemoryCache.remove(illustId);
      _illustMemoryCache[illustId] = memo;
      return SynchronousFuture(memo);
    }
    final inFlight = _illustResolveInFlight[illustId];
    if (inFlight != null) return inFlight;

    final future = PixivApiService()
        .getIllustById(illustId)
        .then<Illust?>((illust) {
          // LRU 登録（上限 20・最も古いものから追い出す）
          _illustMemoryCache.remove(illustId);
          _illustMemoryCache[illustId] = illust;
          while (_illustMemoryCache.length > 20) {
            _illustMemoryCache.remove(_illustMemoryCache.keys.first);
          }
          return illust;
        })
        .catchError((Object e) {
          debugPrint('挿絵の illust 解決に失敗しました (id=$illustId): $e');
          return null;
        });
    _illustResolveInFlight[illustId] = future;
    return future.whenComplete(() => _illustResolveInFlight.remove(illustId));
  }

  // 挿絵画像本体（タップ: 全画面表示 / 長押し: タグをスナック表示）。
  Widget _buildNovelIllustrationImage({
    required String url,
    required String tag,
    required Color textColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GestureDetector(
        onTap: () => _openNovelIllustrationViewer(url),
        onLongPress: () => _showIllustrationSnack(tag),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: _illustrationMaxHeight),
          child: Center(
            child: PixivImage(
              url: url,
              fit: BoxFit.contain,
              errorWidget: _buildIllustrationPlaceholder(
                tag: tag,
                textColor: textColor,
                isLoading: false,
                onTap: _retryIllustrations,
              ),
              placeholder: _buildIllustrationPlaceholder(
                tag: tag,
                textColor: textColor,
                isLoading: true,
                onTap: null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 挿絵プレースホルダー（未解決 / ローディング / エラー共通。設計書 §5.4）。
  Widget _buildIllustrationPlaceholder({
    required String tag,
    required Color textColor,
    required bool isLoading,
    required VoidCallback? onTap,
  }) {
    final child = Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withValues(alpha: 0.15)),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLoading)
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            Icon(
              Icons.image_outlined,
              size: 36,
              color: textColor.withValues(alpha: 0.4),
            ),
          const SizedBox(height: 8),
          Text(
            '挿絵',
            style: TextStyle(
              fontSize: 12,
              color: textColor.withValues(alpha: 0.6),
            ),
          ),
          if (!isLoading) ...[
            const SizedBox(height: 2),
            Text(
              '$tag\nタップして再読み込み',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: textColor.withValues(alpha: 0.4),
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return child;
    return GestureDetector(onTap: onTap, child: child);
  }

  void _showIllustrationSnack(String tag) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(tag), duration: const Duration(seconds: 2)),
      );
  }

  // uploadedimage の再取得（getNovelText 再取得で illustrations マップを更新）。
  Future<void> _retryIllustrations() async {
    try {
      final textData = await PixivApiService().getNovelText(_currentNovel.id);
      if (textData.illustrations.isEmpty) return;
      _safeSetState(() {
        final merged = Map<String, String>.from(
          _textData?.illustrations ?? const {},
        );
        merged.addAll(textData.illustrations);
        _textData = (_textData ?? textData).copyWith(illustrations: merged);
        // 挿絵解決状態が変わったため本文キャッシュを無効化
        _cachedPages = null;
      });
    } catch (e) {
      debugPrint('挿絵の再取得に失敗しました: $e');
    }
  }

  // pixivimage 1 枚の再解決（キャッシュ破棄 → 再解決 → 結果を illustrations にも記録）。
  Future<void> _retryPixivImage(PixivImageBlock block) async {
    _illustMemoryCache.remove(block.illustId);
    _illustResolveInFlight.remove(block.illustId);
    final illust = await _resolveIllustForPixivImage(block.illustId);
    final url = illust == null
        ? null
        : _originalUrlForIllust(illust, block.page);
    if (url == null || url.isEmpty) return;
    _safeSetState(() {
      final merged = Map<String, String>.from(
        _textData?.illustrations ?? const {},
      );
      merged['pixiv:${block.illustId}:${block.page ?? 0}'] = url;
      _textData = _textData?.copyWith(illustrations: merged);
      _cachedPages = null;
    });
  }

  // 挿絵の全画面表示（既存 FullScreenImagePage を再利用）。
  void _openNovelIllustrationViewer(String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FullScreenImagePage(images: [PageImage(page: 1, original: url)]),
      ),
    );
  }
}
