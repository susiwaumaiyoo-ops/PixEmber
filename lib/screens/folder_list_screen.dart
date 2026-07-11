import 'package:flutter/material.dart';
import 'folder_items_screen.dart';
import '../services/database_service.dart';

class FolderListScreen extends StatefulWidget {
  const FolderListScreen({super.key});

  @override
  State<FolderListScreen> createState() => _FolderListScreenState();
}

class _FolderListScreenState extends State<FolderListScreen> {
  final DatabaseService _dbService = DatabaseService();
  List<dynamic> _folders = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchFolders();
  }

  Future<void> _fetchFolders() async {
    try {
      setState(() => _isLoading = true);
      final folders = await _dbService.getFoldersList();
      if (mounted) {
        setState(() {
          _folders = folders;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _createNewFolder() async {
    final TextEditingController nameController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新規フォルダ作成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'フォルダ名',
                hintText: '例: イラストお気に入りなど',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;

              final navigator = Navigator.of(context);
              await _dbService.createFolder(name);
              if (!mounted) return;
              if (navigator.canPop()) {
                navigator.pop();
              }
              _fetchFolders();
            },
            child: const Text('作成'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteFolder(int id, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('フォルダの削除'),
        content: Text(
          'フォルダ「$name」を削除しますか？\n(フォルダに分類されていたお気に入り情報のみが削除され、公式 Pixiv のお気に入りは解除されません)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    if (!mounted) return;

    try {
      await _dbService.deleteFolder(id);
      _fetchFolders();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('エラー: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('お気に入りフォルダ'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder, color: Colors.pinkAccent),
            onPressed: _createNewFolder,
            tooltip: '新規フォルダ作成',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchFolders,
        color: Colors.pinkAccent,
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Colors.pinkAccent),
              )
            : _error != null
            ? Center(
                child: Text(
                  'エラー: $_error',
                  style: const TextStyle(color: Colors.grey),
                ),
              )
            : _folders.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.folder_open, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text(
                      'フォルダがありません。',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _createNewFolder,
                      child: const Text('最初のフォルダを作成'),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: _folders.length,
                itemBuilder: (context, idx) {
                  final folder = _folders[idx];
                  return Card(
                    color: const Color(0xFF1E1E1E),
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: ListTile(
                      leading: const Icon(
                        Icons.folder,
                        color: Colors.amber,
                        size: 36,
                      ),
                      title: Text(
                        folder['name'],
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        '作成日: ${folder['created_at'] ?? ''}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.redAccent,
                        ),
                        onPressed: () =>
                            _deleteFolder(folder['id'], folder['name']),
                      ),
                      isThreeLine: true,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => FolderItemsScreen(
                              folderId: folder['id'],
                              folderName: folder['name'],
                            ),
                          ),
                        ).then((_) => _fetchFolders());
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }
}
