import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/model_transfer_service.dart';

/// Move models (chat, image and voice) to or from another device on the same
/// Wi-Fi: one device sends, the other scans its code and receives.
class ModelTransferView extends StatefulWidget {
  const ModelTransferView({super.key});

  @override
  State<ModelTransferView> createState() => _ModelTransferViewState();
}

class _ModelTransferViewState extends State<ModelTransferView> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Transfer models'),
          bottom: const TabBar(tabs: [Tab(text: 'Send'), Tab(text: 'Receive')]),
        ),
        body: const TabBarView(children: [_SendTab(), _ReceiveTab()]),
      ),
    );
  }
}

class _SendTab extends StatefulWidget {
  const _SendTab();

  @override
  State<_SendTab> createState() => _SendTabState();
}

class _SendTabState extends State<_SendTab> {
  final _server = ModelTransferServer();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server.onChange = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _server.onChange = null;
    _server.stop();
    super.dispose();
  }

  Future<void> _toggle() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_server.running) {
        await _server.stop();
      } else {
        await _server.start();
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final on = _server.running;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text(
          'Start sharing, then open "Receive" on the other device and scan this code (or type the address). Both devices must be on the same Wi-Fi. Nothing goes through the internet.'),
      const SizedBox(height: 16),
      if (on) ...[
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: _server.url, size: 220, padding: EdgeInsets.zero),
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(_server.url, textAlign: TextAlign.center),
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _server.url));
            Get.snackbar('Copied', 'Address copied');
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy address'),
        ),
        Text('Sent so far: ${formatTransferBytes(_server.bytesServed)}',
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
      ],
      if (_error != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      FilledButton.icon(
        onPressed: _busy ? null : _toggle,
        icon: Icon(on ? Icons.stop_rounded : Icons.send_rounded),
        label: Text(on ? 'Stop sharing' : 'Share my models'),
      ),
    ]);
  }
}

class _ReceiveTab extends StatefulWidget {
  const _ReceiveTab();

  @override
  State<_ReceiveTab> createState() => _ReceiveTabState();
}

class _ReceiveTabState extends State<_ReceiveTab> {
  final _addr = TextEditingController();
  ModelTransferClient? _client;
  List<TransferItem> _items = const [];
  final _picked = <String>{};
  final _have = <String>{};
  TransferProgress? _progress;
  bool _loading = false;
  String? _error;
  String? _result;

  @override
  void dispose() {
    _client?.cancel();
    _addr.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Get.to<String>(() => const _ScanPage());
    if (code != null && code.isNotEmpty) {
      _addr.text = code;
      await _connect();
    }
  }

  Future<void> _connect() async {
    final c = ModelTransferClient.parse(_addr.text);
    if (c == null) {
      setState(() => _error = 'That address is not valid. Scan the code or type it exactly.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final items = await c.fetchList();
      final have = <String>{};
      for (final it in items) {
        if (await c.haveLocally(it)) have.add(it.id);
      }
      if (mounted) setState(() {
        _client = c;
        _items = items;
        _have
          ..clear()
          ..addAll(have);
        _picked
          ..clear()
          ..addAll(items.where((i) => !have.contains(i.id)).map((i) => i.id));
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _receive() async {
    final c = _client;
    if (c == null) return;
    final chosen = _items.where((i) => _picked.contains(i.id)).toList();
    if (chosen.isEmpty) return;
    setState(() {
      _progress = const TransferProgress(0, 0, '');
      _error = null;
      _result = null;
    });
    try {
      final failed = await c.download(chosen, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _result = failed.isEmpty
          ? 'Done. The models are installed.'
          : 'Finished with problems:\n${failed.join('\n')}');
    } on TransferCancelled {
      if (mounted) setState(() => _result = 'Stopped.');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _progress = null);
  }

  String _kind(String k) => switch (k) {
        'llm' => 'Chat model',
        'image' => 'Image model',
        'vision' => 'Vision file',
        'voice' => 'Voice model',
        _ => k,
      };

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Scan the code shown on the sending device, or type its address.'),
      const SizedBox(height: 12),
      TextField(
        controller: _addr,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: 'Address (http://192.168…)',
          suffixIcon: IconButton(
              tooltip: 'Scan code',
              icon: const Icon(Icons.qr_code_scanner_rounded),
              onPressed: busy ? null : _scan),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton(
          onPressed: _loading || busy ? null : _connect,
          child: _loading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect')),
      if (_error != null)
        Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (_items.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final it in _items)
          CheckboxListTile(
            value: _picked.contains(it.id),
            onChanged: busy || _have.contains(it.id)
                ? null
                : (v) => setState(() => v == true ? _picked.add(it.id) : _picked.remove(it.id)),
            title: Text(it.name),
            subtitle: Text(
                '${_kind(it.kind)} · ${formatTransferBytes(it.size)}${_have.contains(it.id) ? ' · already here' : ''}'),
          ),
        const SizedBox(height: 8),
        if (busy) ...[
          LinearProgressIndicator(value: _progress!.fraction),
          const SizedBox(height: 6),
          Text('${_progress!.current}  ${formatTransferBytes(_progress!.done)} / ${formatTransferBytes(_progress!.total)}'),
          TextButton(onPressed: () => _client?.cancel(), child: const Text('Cancel')),
        ] else
          FilledButton.icon(
              onPressed: _picked.isEmpty ? null : _receive,
              icon: const Icon(Icons.download_rounded),
              label: Text('Receive ${_picked.length} model${_picked.length == 1 ? '' : 's'}')),
      ],
      if (_result != null)
        Padding(padding: const EdgeInsets.only(top: 12), child: Text(_result!)),
    ]);
  }
}

class _ScanPage extends StatelessWidget {
  const _ScanPage();

  @override
  Widget build(BuildContext context) {
    var done = false;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the sender\'s code')),
      body: MobileScanner(
        onDetect: (cap) {
          if (done) return;
          final v = cap.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
          if (v != null) {
            done = true;
            Get.back(result: v);
          }
        },
      ),
    );
  }
}
