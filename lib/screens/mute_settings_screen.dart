import 'package:flutter/material.dart';
import '../services/database_service.dart';

class MuteSettingsScreen extends StatefulWidget {
  const MuteSettingsScreen({super.key});

  @override
  State<MuteSettingsScreen> createState() => _MuteSettingsScreenState();
}

class _MuteSettingsScreenState extends State<MuteSettingsScreen> {
  List<Map<String, dynamic>> _mutes = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchMutes();
  }

  Future<void> _fetchMutes() async {
    try {
      setState(() => _isLoading = true);
      final db = DatabaseService();
      final mutes = await db.getMutesList();
      if (mounted) {
        setState(() {
          _mutes = mutes;
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

Future<void> _addMute(String type, String value, {String? label}) async {
    try {
      final db = DatabaseService();
      await db.insertOrUpdateMute(
        muteType: type,
        value: value,
        label: label ?? (type == 'tag' ? value : ''),
      );
      _fetchMutes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('追加エラー: $e')));
      }
    }
  }

Future<void> _deleteMute(int id) async {
    try {
      final db = DatabaseService();
      await db.deleteMute(id);
      _fetchMutes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('削除エラー: $e')));
      }
    }
  }

void _showAddMuteDialog() {
    final TextEditingController valController = TextEditingController();
    final TextEditingController labelController = TextEditingController();
    String selectType = 'tag';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('新規ミュート登録', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  dropdownColor: const Color(0xFF1E1E1E),
                  style: const TextStyle(color: Colors.white),
                  initialValue: selectType,
                  items: const [
                    DropdownMenuItem(value: 'tag', child: Text('タグ')),
                    DropdownMenuItem(value: 'user', child: Text('ユーザーID')),
                    DropdownMenuItem(
                      value: 'ai',
                      child: Text('AI作品判定 (0=除外しない, 1=AI非表示, 2=AIのみ)'),
                    ),
                  ],
                  onChanged: (val) {
                    setDialogState(() {
                      selectType = val!;
                      if (selectType == 'ai') {
                        valController.text = '1';
                        labelController.clear();
                      } else {
                        valController.clear();
                        labelController.clear();
                      }
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'ミュート種別',
                    labelStyle: TextStyle(color: Colors.grey),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (selectType == 'ai')
                  DropdownButtonFormField<String>(
                    dropdownColor: const Color(0xFF1E1E1E),
                    style: const TextStyle(color: Colors.white),
                    initialValue: '1',
                    items: const [
                      DropdownMenuItem(
                        value: '1',
                        child: Text('AI作品を完全に非表示にする'),
                      ),
                      DropdownMenuItem(
                        value: '2',
                        child: Text('AI作品のみにする (逆フィルタ)'),
                      ),
                    ],
                    onChanged: (val) {
                      valController.text = val ?? '1';
                    },
                    decoration: const InputDecoration(
                      labelText: 'AI制御パラメータ',
                      labelStyle: TextStyle(color: Colors.grey),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey),
                      ),
                    ),
                  )
                else ...[
                  TextField(
                    controller: valController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: selectType == 'tag'
                          ? 'タグ名 (完全一致/部分一致)'
                          : '数値型 Pixiv ユーザーID',
                      labelStyle: const TextStyle(color: Colors.grey),
                      hintText: selectType == 'tag'
                          ? '例: 東方Project'
                          : '例: 123456',
                      hintStyle: const TextStyle(color: Colors.grey),
                      enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: labelController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '表示名/ラベル (任意)',
                      labelStyle: const TextStyle(color: Colors.grey),
                      hintText: selectType == 'tag'
                          ? '例: 東方Project (タグ名が自動で入る場合は空欄でOK)'
                          : '例: 作者名 (ユーザー名が自動で入る場合は空欄でOK)',
                      hintStyle: const TextStyle(color: Colors.grey),
                      enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.grey),
                      ),
                    ),
                  ),
                ],
              ],
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
              onPressed: () {
                final value = valController.text.trim();
                if (value.isEmpty) return;
                final label = labelController.text.trim();
                Navigator.pop(context);
                _addMute(selectType, value, label: label.isEmpty ? null : label);
              },
              child: const Text('追加'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'ミュート（ブラックリスト）管理',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.add, color: Colors.pinkAccent),
            onPressed: _showAddMuteDialog,
            tooltip: '新規ミュート登録',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchMutes,
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
            : _mutes.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.block, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text(
                      '登録されているミュートはありません。',
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '検索結果やおすすめ、ランキング等から\nミュート対象が自動で除外されます。',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: _mutes.length,
                itemBuilder: (context, idx) {
                  final mute = _mutes[idx];
                  final String typeLabel = mute['mute_type'] == 'tag'
                      ? '🏷️ タグ'
                      : mute['mute_type'] == 'user'
                      ? '👤 作者'
                      : '🤖 AI判定';

                  String valueLabel = '';
                  if (mute['mute_type'] == 'ai') {
                    valueLabel = mute['value'] == '1' ? 'AI作品非表示' : 'AI作品のみ表示';
                  } else {
                    final label = mute['label'];
                    if (label != null && label.toString().isNotEmpty) {
                      valueLabel = '${label.toString()} (${mute['value']})';
                    } else {
                      valueLabel = mute['value'].toString();
                    }
                  }

                  return Card(
                    color: const Color(0xFF1E1E1E),
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: ListTile(
                      title: Text(
                        valueLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        '種別: $typeLabel',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                        onPressed: () => _deleteMute(mute['id']),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
