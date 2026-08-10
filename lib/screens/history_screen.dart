import 'package:flutter/material.dart';
import 'novel_detail_screen.dart';
import '../services/database_service.dart';
import '../services/pixiv_api_service.dart';

/// 閲覧履歴画面
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final DatabaseService _databaseService = DatabaseService();

  List<Map<String, dynamic>> _historyList = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await _databaseService.getHistoryList();
      if (mounted) {
        setState(() {
          _historyList = history;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _navigateToDetail(Map<String, dynamic> item) async {
    final workType = item['work_type'] ?? 'illust';
    final workId = item['work_id'] ?? 0;
    if (workType == 'novel') {
      try {
        // Novel オブジェクトを取得
        final novel = await PixivApiService().getNovelById(workId);
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => NovelDetailScreen(novel: novel),
            ),
          );
        }
      } catch (e) {
        // エラー時は簡易表示
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('小説の詳細を取得できませんでした: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('閲覧履歴'),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _historyList.isEmpty
          ? const Center(
              child: Text('閲覧履歴はありません', style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              itemCount: _historyList.length,
              itemBuilder: (context, index) {
                final item = _historyList[index];
                return ListTile(
                  title: Text(item['title'] ?? '無題'),
                  subtitle: Text(item['author_name'] ?? ''),
                  onTap: () => _navigateToDetail(item),
                );
              },
            ),
    );
  }
}
