import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../core/ui.dart';
import '../services/download_service.dart';

class StorageView extends StatefulWidget {
  const StorageView({super.key});

  @override
  State<StorageView> createState() => _StorageViewState();
}

class _StorageViewState extends State<StorageView> {
  final _selected = <String>{};
  List<({String name, int size})> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dl = Get.find<DownloadService>();
    final names = await dl.getDownloadedModels();
    final out = <({String name, int size})>[];
    for (final n in names) {
      out.add((name: n, size: await dl.getModelSize(n)));
    }
    out.sort((a, b) => b.size.compareTo(a.size));
    if (!mounted) return;
    setState(() {
      _files = out;
      _loading = false;
    });
  }

  String _fmt(int b) => b >= 1 << 30
      ? '${(b / (1 << 30)).toStringAsFixed(2)} GB'
      : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

  Future<void> _deleteSelected() async {
    final total = _files
        .where((f) => _selected.contains(f.name))
        .fold<int>(0, (a, f) => a + f.size);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${_selected.length} model(s)?'),
        content: Text('This frees ${_fmt(total)} and cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final mc = Get.find<ModelController>();
    for (final n in _selected.toList()) {
      await mc.deleteModel(n);
    }
    _selected.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final total = _files.fold<int>(0, (a, f) => a + f.size);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Storage'),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline),
              label: Text('Delete ${_selected.length}'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: kPagePadding, children: [
              SectionHeader('${_files.length} models · ${_fmt(total)}'),
              if (_files.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No models downloaded yet.')),
              AppGroup(children: [
                for (final f in _files)
                  AppRow(
                    icon: Icons.memory_rounded,
                    title: f.name,
                    subtitle: _fmt(f.size),
                    selected: _selected.contains(f.name),
                    onTap: () => setState(() {
                      if (!_selected.remove(f.name)) _selected.add(f.name);
                    }),
                    trailing: Checkbox(
                        value: _selected.contains(f.name),
                        onChanged: (_) => setState(() {
                              if (!_selected.remove(f.name)) {
                                _selected.add(f.name);
                              }
                            })),
                  ),
              ]),
            ]),
    );
  }
}
