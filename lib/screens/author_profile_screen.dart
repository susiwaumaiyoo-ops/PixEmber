import 'package:flutter/material.dart';
import '../illust_model.dart';
import '../widgets/pixiv_image.dart';
import '../novel_model.dart';
import '../services/pixiv_api_service.dart';
import 'illust_detail_screen.dart';
import 'novel_detail_screen.dart';

class AuthorProfileScreen extends StatefulWidget {
  final int userId;

  const AuthorProfileScreen({super.key, required this.userId});

  @override
  State<AuthorProfileScreen> createState() => _AuthorProfileScreenState();
}

class _AuthorProfileScreenState extends State<AuthorProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoadingUser = true;
  bool _isLoadingIllusts = false;
  bool _isLoadingNovels = false;
  bool _isLoadingMoreIllusts = false;
  bool _isLoadingMoreNovels = false;

  Map<String, dynamic>? _userDetail;
  List<Illust> _illusts = [];
  List<Novel> _novels = [];

  int? _nextIllustOffset;
  int? _nextNovelOffset;

  final ScrollController _illustScrollController = ScrollController();
  final ScrollController _novelScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabChange);

    _illustScrollController.addListener(() {
      if (_illustScrollController.position.pixels >=
          _illustScrollController.position.maxScrollExtent - 200) {
        _fetchMoreIllusts();
      }
    });

    _novelScrollController.addListener(() {
      if (_novelScrollController.position.pixels >=
          _novelScrollController.position.maxScrollExtent - 200) {
        _fetchMoreNovels();
      }
    });

    _fetchInitialData();
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _illustScrollController.dispose();
    _novelScrollController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (_tabController.index == 1 && _novels.isEmpty && !_isLoadingNovels) {
      _fetchInitialNovels();
    }
  }

  // 初期データ（作者詳細とイラスト1ページ目）を取得
  Future<void> _fetchInitialData() async {
    setState(() {
      _isLoadingUser = true;
      _isLoadingIllusts = true;
    });

    // ユーザー情報とイラスト一覧を個別に取得し、どちらかが失敗しても
    // もう片方は画面に反映する（真っ白防止）
    final api = PixivApiService();
    Map<String, dynamic>? detailData;
    List<Illust> listIllusts = [];
    try {
      detailData = await api.getUserDetail(widget.userId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('ユーザー情報の取得に失敗: $e')));
      }
    }
    try {
      listIllusts = await api.getUserIllusts(widget.userId, offset: 0);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('イラスト一覧の取得に失敗: $e')));
      }
    }

    if (mounted) {
      setState(() {
        _userDetail = detailData;
        _illusts = listIllusts;
        _nextIllustOffset = listIllusts
            .length; // offset increment by elements counts as basic logic
        _isLoadingUser = false;
        _isLoadingIllusts = false;
      });
    }
  }

  // 小説の初期データを取得
  Future<void> _fetchInitialNovels() async {
    setState(() {
      _isLoadingNovels = true;
    });

    try {
      final api = PixivApiService();
      final listNovels = await api.getUserNovels(widget.userId, offset: 0);
      if (!mounted) return;
      setState(() {
        _novels = listNovels;
        _nextNovelOffset = listNovels.length;
        _isLoadingNovels = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingNovels = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラーが発生しました: $e')));
      }
    }
  }

  // イラスト追加読み込み
  Future<void> _fetchMoreIllusts() async {
    if (_nextIllustOffset == null || _isLoadingMoreIllusts) return;

    setState(() {
      _isLoadingMoreIllusts = true;
    });

    try {
      final api = PixivApiService();
      final newItems = await api.getUserIllusts(
        widget.userId,
        offset: _nextIllustOffset!,
      );
      if (!mounted) return;

      setState(() {
        _illusts.addAll(newItems);
        _nextIllustOffset = _nextIllustOffset! + newItems.length;
        _isLoadingMoreIllusts = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingMoreIllusts = false;
      });
    }
  }

  // 小説追加読み込み
  Future<void> _fetchMoreNovels() async {
    if (_nextNovelOffset == null || _isLoadingMoreNovels) return;

    setState(() {
      _isLoadingMoreNovels = true;
    });

    try {
      final api = PixivApiService();
      final newItems = await api.getUserNovels(
        widget.userId,
        offset: _nextNovelOffset!,
      );
      if (!mounted) return;

      setState(() {
        _novels.addAll(newItems);
        _nextNovelOffset = _nextNovelOffset! + newItems.length;
        _isLoadingMoreNovels = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingMoreNovels = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: Text(
          _userDetail != null ? _userDetail!['name'] ?? '作者プロフィール' : '作者プロフィール',
        ),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: _isLoadingUser && _userDetail == null
          ? const Center(
              child: CircularProgressIndicator(color: Colors.pinkAccent),
            )
          : Column(
              children: [
                // 1. 作者プロフィールヘッダー
                _buildHeader(),

                // 2. タブバー
                TabBar(
                  controller: _tabController,
                  indicatorColor: Colors.pinkAccent,
                  labelColor: Colors.pinkAccent,
                  unselectedLabelColor: Colors.grey,
                  tabs: const [
                    Tab(text: 'イラスト・マンガ'),
                    Tab(text: '小説'),
                  ],
                ),

                // 3. タブビュー
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [_buildIllustsTab(), _buildNovelsTab()],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildHeader() {
    if (_userDetail == null) return const SizedBox.shrink();

    final avatar = _userDetail!['avatar'];
    final comment = _userDetail!['comment'] ?? '';
    final followers = _userDetail!['total_follower'] ?? 0;
    final totalIllusts = _userDetail!['total_illusts'] ?? 0;
    final totalNovels = _userDetail!['total_novels'] ?? 0;

    return Container(
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey[800],
                ),
                clipBehavior: Clip.antiAlias,
                child: avatar != null && avatar.toString().isNotEmpty
                    ? PixivImage(
                        url: avatar,
                        fit: BoxFit.cover,
                        isThumbnail: true,
                        errorWidget: const Icon(
                          Icons.person,
                          size: 35,
                          color: Colors.grey,
                        ),
                      )
                    : const Icon(Icons.person, size: 35, color: Colors.grey),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _userDetail!['name'] ?? '',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '@${_userDetail!['account'] ?? ''}',
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildStatItem('フォロワー', followers.toString()),
                        const SizedBox(width: 16),
                        _buildStatItem('イラスト', totalIllusts.toString()),
                        const SizedBox(width: 16),
                        _buildStatItem('小説', totalNovels.toString()),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (comment.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF262626),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                comment,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String count) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Text(
          count,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildIllustsTab() {
    if (_isLoadingIllusts && _illusts.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.pinkAccent),
      );
    }

    if (_illusts.isEmpty) {
      return const Center(
        child: Text('イラスト・マンガ作品はありません。', style: TextStyle(color: Colors.grey)),
      );
    }

    return GridView.builder(
      controller: _illustScrollController,
      padding: const EdgeInsets.all(8.0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 1.0,
      ),
      itemCount: _illusts.length + (_isLoadingMoreIllusts ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _illusts.length) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.pinkAccent),
          );
        }

        final illust = _illusts[index];
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => IllustDetailScreen(illust: illust),
              ),
            ).then((_) {
              if (!mounted) return;
              setState(() {});
            });
          },
          child: Container(
            color: Colors.grey[900],
            child: Stack(
              fit: StackFit.expand,
              children: [
                PixivImage(
                  url: illust.urls.preview ?? '',
                  fit: BoxFit.cover,
                  isThumbnail: true,
                  errorWidget: const Icon(
                    Icons.broken_image,
                    color: Colors.grey,
                  ),
                ),
                if (illust.metaPages.isNotEmpty)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.layers,
                            size: 10,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            illust.metaPages.length.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNovelsTab() {
    if (_isLoadingNovels && _novels.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.pinkAccent),
      );
    }

    if (_novels.isEmpty) {
      return const Center(
        child: Text('小説作品はありません。', style: TextStyle(color: Colors.grey)),
      );
    }

    return ListView.builder(
      controller: _novelScrollController,
      padding: const EdgeInsets.all(8.0),
      itemCount: _novels.length + (_isLoadingMoreNovels ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _novels.length) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.pinkAccent),
          );
        }

        final novel = _novels[index];
        return Card(
          color: const Color(0xFF1E1E1E),
          margin: const EdgeInsets.symmetric(vertical: 4.0),
          child: ListTile(
            leading: Container(
              width: 54,
              height: 81,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
              clipBehavior: Clip.antiAlias,
              child: novel.coverUrl.isNotEmpty
                  ? PixivImage(
                      url: novel.coverUrl,
                      fit: BoxFit.cover,
                      isThumbnail: true,
                    )
                  : const Icon(Icons.book, color: Colors.grey),
            ),
            title: Text(
              novel.title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  '📄 ${novel.pageCount}P  |  ✍️ ${novel.textLength}文字',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: novel.tags.take(3).map((tag) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tag,
                        style: const TextStyle(color: Colors.grey, fontSize: 9),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => NovelDetailScreen(novel: novel),
                ),
              ).then((_) {
                if (!mounted) return;
                setState(() {});
              });
            },
          ),
        );
      },
    );
  }
}
