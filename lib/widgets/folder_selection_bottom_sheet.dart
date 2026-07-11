import 'package:flutter/material.dart';
import '../services/database_service.dart';

class FolderSelectionBottomSheet extends StatefulWidget {
  final int itemId;
  final String title;
  final String authorName;
  final String previewUrl;
  final String type; // 'illust' or 'novel'

  const FolderSelectionBottomSheet({
    super.key,
    required this.itemId,
    required this.title,
    required this.authorName,
    required this.previewUrl,
    required this.type,
  });

  @override
  State<FolderSelectionBottomSheet> createState() =>
      _FolderSelectionBottomSheetState();
}

class _FolderSelectionBottomSheetState
    extends State<FolderSelectionBottomSheet> {
  List<Map<String, dynamic>> _folders = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchFolders();
  }

  Future<void> _fetchFolders() async {
    try {
      final db = DatabaseService();
      // getFoldersList(): List<Map<String, dynamic>> where each map represents a folder
      final folderList = await db.getFoldersList();

      // Calculate item count per folder from SQLite folder_items
      final List<Map<String, dynamic>> processedFolders = [];
      for (final f in folderList) {
        final folderId = f['id'] as int;
        final items = await db.getFolderItems(folderId: folderId);
        final count = items.length;

        processedFolders.add({
          'id': folderId,
          'name': f['name'],
          'item_count': count,
        });
      }

      if (mounted) {
        setState(() {
          _folders = processedFolders;
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
        backgroundColor: const Color(0xFF222222),
        title: const Text(
          '新規フォルダ作成',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'フォルダ名',
            labelStyle: TextStyle(color: Colors.pinkAccent),
            hintText: '例: お気に入り、AI作品など',
            hintStyle: TextStyle(color: Colors.grey),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.grey),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.pinkAccent),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.pinkAccent,
              foregroundColor: Colors.white,
            ),
onPressed: () async {
              final navigator = Navigator.of(context);
              final messenger = ScaffoldMessenger.of(context);
              final name = nameController.text.trim();
              if (name.isEmpty) return;

              try {
                final db = DatabaseService();
                await db.createFolder(name);
                if (!context.mounted) return;

                if (navigator.canPop()) {
                  navigator.pop();
                }
                _fetchFolders();
              } catch (e) {
                if (!context.mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text('フォルダの作成に失敗しました: $e')),
                );
              }
            },
            child: const Text('作成'),
          ),
        ],
      ),
    );
  }

Future<void> _addToFolder(int folderId) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final db = DatabaseService();
      await db.addFolderItem(
        folderId: folderId,
        workId: widget.itemId,
        title: widget.title,
        authorName: widget.authorName,
        previewUrl: widget.previewUrl,
        type: widget.type,
      );

      if (!context.mounted) return;

      messenger.showSnackBar(
        const SnackBar(
          content: Text('フォルダにお気に入り作品を追加しました！'),
          duration: Duration(seconds: 1),
        ),
      );
      if (context.mounted && navigator.canPop()) {
        navigator.pop();
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('追加に失敗しました: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'お気に入りフォルダに分類',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_to_photos, color: Colors.pinkAccent),
                onPressed: _createNewFolder,
                tooltip: '新規フォルダ作成',
              ),
            ],
          ),
          const Divider(color: Colors.grey),
          if (_isLoading)
            const SizedBox(
              height: 120,
              child: Center(
                child: CircularProgressIndicator(color: Colors.pinkAccent),
              ),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'エラー: $_error',
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            )
          else if (_folders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30.0),
              child: Column(
                children: [
                  const Text(
                    'フォルダがまだありません。',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _createNewFolder,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.pinkAccent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('フォルダを作成する'),
                  ),
                ],
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.4,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _folders.length,
                itemBuilder: (context, idx) {
                  final folder = _folders[idx];
                  return ListTile(
                    leading: const Icon(Icons.folder, color: Colors.amber),
                    title: Text(
                      folder['name'],
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${folder['item_count']} 件',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                    ),
                    onTap: () => _addToFolder(folder['id']),
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
