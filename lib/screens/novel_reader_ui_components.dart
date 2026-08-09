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
        ],
      ),
    );
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
        '${_seriesNovels.length}|$pageCount';
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

                // 本文テキスト（ルビ記法 [[rb:親 > ルビ]] を文庫本風にパース）
                _parseRubyText(
                  _formatParagraphs(content),
                  textColor,
                  _fontSize,
                  _lineHeight,
                ),

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
                      Text(
                        '$percent% 読了',
                        style: TextStyle(
                          fontSize: 10,
                          color: textColor.withValues(alpha: 0.5),
                        ),
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

  // 段落改行のフォーマット
  String _formatParagraphs(String text) {
    var cleaned = text.replaceAll('[newpage]', '');
    // 空行を適切に圧縮・字下げなどの和文小説特有の成形が必要であればここで処理可能
    return cleaned;
  }

  // Pixiv のルビ記法 [[rb:親文字 > ルビ]] を文庫本風の縦並びルビ表示にパースする。
  // ルビ箇所は WidgetSpan 内の Column（ルビ→親文字）で埋め込み、通常箇所は TextSpan とする。
  Widget _parseRubyText(
    String text,
    Color textColor,
    double fontSize,
    double lineHeight,
  ) {
    final rubyRegex = RegExp(r'\[\[rb:(.+?)\s*>\s*(.+?)\]\]');
    final spans = <InlineSpan>[];
    int lastMatchEnd = 0;
    final rubyFontSize = fontSize * 0.5;

    for (final match in rubyRegex.allMatches(text)) {
      if (match.start > lastMatchEnd) {
        spans.add(
          TextSpan(
            text: text.substring(lastMatchEnd, match.start),
            style: TextStyle(
              fontSize: fontSize,
              height: lineHeight,
              color: textColor,
              fontFamily: _fontFamily,
              letterSpacing: 0.8,
              backgroundColor:
                  _searchQuery.isNotEmpty &&
                      text
                          .substring(lastMatchEnd, match.start)
                          .contains(_searchQuery)
                  ? Colors.yellow.withValues(alpha: 0.6)
                  : null,
            ),
          ),
        );
      }
      final baseText = match.group(1) ?? '';
      final rubyText = match.group(2) ?? '';
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                rubyText,
                style: TextStyle(
                  fontSize: rubyFontSize,
                  height: 1.0,
                  color: textColor,
                  fontFamily: _fontFamily,
                ),
                textAlign: TextAlign.center,
              ),
              Text(
                baseText,
                style: TextStyle(
                  fontSize: fontSize,
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
      lastMatchEnd = match.end;
    }

    // 残りの通常テキスト
    if (lastMatchEnd < text.length) {
      final tail = text.substring(lastMatchEnd);
      final isHit = _searchQuery.isNotEmpty && tail.contains(_searchQuery);
      spans.add(
        TextSpan(
          text: tail,
          style: TextStyle(
            fontSize: fontSize,
            height: lineHeight,
            color: textColor,
            fontFamily: _fontFamily,
            letterSpacing: 0.8,
            backgroundColor: isHit
                ? Colors.yellow.withValues(alpha: 0.6)
                : null,
          ),
        ),
      );
    }

    return RichText(
      text: TextSpan(children: spans),
      textAlign: TextAlign.left,
    );
  }
}
