import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/hf_service.dart';
import '../widgets/tonal_button.dart';

String _compact(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

/// Search Hugging Face for GGUF models and download them. Replaces the old
/// fixed list of download links.
class HfBrowser extends StatefulWidget {
  const HfBrowser({super.key});

  @override
  State<HfBrowser> createState() => _HfBrowserState();
}

class _HfBrowserState extends State<HfBrowser> {
  final _hf = HfService();
  final _search = TextEditingController();
  Timer? _debounce;
  List<HfRepo> _repos = const [];
  bool _loading = false;
  String? _error;
  String _query = '';
  int _limit = 30;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _hf.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _query = value.trim();
      _limit = 30;
      _run();
    });
  }

  Future<void> _run() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repos = await _hf.searchModels(_query, limit: _limit);
      if (!mounted || seq != _seq) return;
      setState(() {
        _repos = repos;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _openRepo(HfRepo repo) {
    showAppSheet<void>(
      context,
      title: repo.name,
      subtitle: repo.id,
      builder: (ctx) => _RepoFiles(repo: repo, hf: _hf),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: (v) {
            _debounce?.cancel();
            _query = v.trim();
            _limit = 30;
            _run();
          },
          decoration: appInputDecoration(
            context,
            hint: 'Search Hugging Face, e.g. deepseek',
            prefix: const Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _query.isEmpty
              ? 'Most downloaded GGUF models'
              : 'GGUF models matching "$_query"',
          style: t.small,
        ),
        const SizedBox(height: 8),
        if (_loading && _repos.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null && _repos.isEmpty)
          EmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load models',
            message: _error,
            action: TextButton(onPressed: _run, child: const Text('Try again')),
          )
        else if (_repos.isEmpty)
          const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No GGUF models found',
            message: 'Try a different search.',
          )
        else ...[
          AppGroup(children: [
            for (final r in _repos)
              AppRow(
                icon: r.gated ? Icons.lock_outline_rounded : Icons.memory_rounded,
                title: r.name,
                subtitle:
                    '${r.author} · ${_compact(r.downloads)} downloads · ${_compact(r.likes)} likes${r.gated ? ' · login required' : ''}',
                chevron: true,
                onTap: () => _openRepo(r),
              ),
          ]),
          if (_repos.length >= _limit)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton(
                onPressed: _loading
                    ? null
                    : () {
                        _limit += 30;
                        _run();
                      },
                child: Text(_loading ? 'Loading…' : 'Load more'),
              ),
            ),
        ],
      ],
    );
  }
}

class _RepoFiles extends StatefulWidget {
  final HfRepo repo;
  final HfService hf;
  const _RepoFiles({required this.repo, required this.hf});

  @override
  State<_RepoFiles> createState() => _RepoFilesState();
}

class _RepoFilesState extends State<_RepoFiles> {
  late final Future<List<HfGgufFile>> _files;

  @override
  void initState() {
    super.initState();
    _files = widget.hf.listGgufFiles(widget.repo.id);
  }

  AiModel _asModel(HfGgufFile f) => AiModel(
        name: widget.repo.name,
        filename: f.filename,
        url: HfService.downloadUrl(widget.repo.id, f.path),
        size: DownloadService.formatBytes(f.size),
        description: 'Hugging Face · ${widget.repo.id}',
        template: 'chatml',
      );

  void _choose(HfGgufFile f) {
    final model = _asModel(f);
    final controller = Get.find<ModelController>();
    showAppSheet<void>(
      context,
      title: f.quant.isEmpty ? f.filename : '${widget.repo.name} · ${f.quant}',
      subtitle: f.filename,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppRow(
            icon: Icons.sd_storage_outlined,
            title: 'File size',
            trailing: Text(DownloadService.formatBytes(f.size)),
          ),
          const SizedBox(height: 12),
          const AppNotice(
            'Large download. Wi-Fi is recommended. Models bigger than your phone\'s free memory will not load.',
            icon: Icons.wifi_rounded,
          ),
          const SizedBox(height: 20),
          PrimaryButton(
            label: 'Download into the app',
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).maybePop();
              controller.downloadModel(model);
            },
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Save to phone Downloads folder instead',
            onTap: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).maybePop();
              controller.downloadModelToDownloads(model);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    if (widget.repo.gated) {
      return const AppNotice(
        'This model needs a Hugging Face login and licence acceptance, so it cannot be downloaded here.',
        icon: Icons.lock_outline_rounded,
      );
    }
    return FutureBuilder<List<HfGgufFile>>(
      future: _files,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return EmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load files',
            message: snap.error.toString(),
          );
        }
        final files = snap.data ?? const <HfGgufFile>[];
        if (files.isEmpty) {
          return const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No single-file GGUF models here',
            message: 'This repository only has split or projector files.',
          );
        }
        final controller = Get.find<ModelController>();
        return Obx(() => AppGroup(children: [
              for (final f in files)
                AppRow(
                  icon: Icons.insert_drive_file_outlined,
                  title: f.quant.isEmpty ? f.filename : f.quant,
                  subtitle:
                      '${DownloadService.formatBytes(f.size)} · ${f.filename}',
                  trailing: controller.downloadedFiles.contains(f.filename)
                      ? Text('On phone', style: t.small)
                      : controller.isDownloadingModel(f.filename)
                          ? Text('Downloading', style: t.small)
                          : null,
                  chevron: !controller.downloadedFiles.contains(f.filename),
                  onTap: controller.downloadedFiles.contains(f.filename) ||
                          controller.isDownloadingModel(f.filename)
                      ? null
                      : () => _choose(f),
                ),
            ]));
      },
    );
  }
}
