import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/pollinations_credentials.dart';
import '../services/pollinations_image_service.dart';

class PollinationsPanel extends StatefulWidget {
  const PollinationsPanel({super.key});

  @override
  State<PollinationsPanel> createState() => _PollinationsPanelState();
}

class _PollinationsPanelState extends State<PollinationsPanel> {
  final _key = TextEditingController();
  bool _saved = false;
  bool _busy = true;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final key = await PollinationsCredentials.read();
      if (mounted) setState(() => _saved = key?.isNotEmpty == true);
    } on Exception {
      if (mounted) setState(() => _status = 'Couldn’t open secure storage.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool remove = false}) async {
    final value = remove ? '' : _key.text.trim();
    if (!remove && value.isEmpty) return;
    setState(() => _busy = true);
    try {
      await PollinationsCredentials.save(value);
      if (!mounted) return;
      _key.clear();
      setState(() {
        _saved = value.isNotEmpty;
        _status =
            _saved ? 'Pollinations key saved.' : 'Pollinations key removed.';
      });
    } on Exception {
      if (mounted) setState(() => _status = 'Couldn’t save to secure storage.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Pollinations', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(PollinationsImageService.internetNotice),
        const SizedBox(height: 8),
        const Text(
            'Ask Chat to create an image. For an edit, attach a photo and say what to change. Edits send the source image to Pollinations.'),
        const SizedBox(height: 16),
        Text(_saved
            ? 'Pollinations key configured'
            : 'Pollinations key for editing'),
        const SizedBox(height: 6),
        const Text(
            'Creation works without a key. Editing requires a key with access to a free image editor.'),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Pollinations key'),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
                onPressed: _busy ? null : () => _save(),
                child: const Text('Save key')),
            if (_saved)
              TextButton(
                  onPressed: _busy ? null : () => _save(remove: true),
                  child: const Text('Remove key')),
            TextButton(
              onPressed: () => launchUrl(
                  Uri.https('enter.pollinations.ai', '/keys'),
                  mode: LaunchMode.externalApplication),
              child: const Text('Get a Pollinations key'),
            ),
          ],
        ),
        if (_status != null) Text(_status!),
      ],
    );
  }
}
