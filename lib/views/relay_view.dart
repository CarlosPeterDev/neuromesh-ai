import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ui.dart';
import '../services/relay_service.dart';

/// Outdoor access: chat with this phone from any device, through your own
/// free Cloudflare Worker.
class RelayView extends StatefulWidget {
  const RelayView({super.key});

  @override
  State<RelayView> createState() => _RelayViewState();
}

class _RelayViewState extends State<RelayView> {
  final r = Get.find<RelayService>();
  late final _token = TextEditingController(text: r.cfToken);
  late final _account = TextEditingController(text: r.cfAccount);
  late final _name = TextEditingController(text: r.workerName);
  late final _password = TextEditingController(text: r.password);
  late final _key = TextEditingController(text: r.apiKey);
  late String _mode = r.keyMode;
  late bool _usePw = r.password.isNotEmpty;
  late bool _useKey = r.apiKey.isNotEmpty;
  String? _error;

  Future<void> _save() => r.saveSettings(
        token: _token.text,
        account: _account.text,
        name: _name.text,
        password: _usePw ? _password.text : '',
        apiKey: _useKey ? _key.text : '',
        keyMode: _mode,
      );

  Future<void> _deploy() async {
    setState(() => _error = null);
    if (_useKey && _key.text.trim().isEmpty) _key.text = RelayService.randomSecret(40);
    await _save();
    try {
      await r.deploy();
      Get.snackbar('Relay ready', r.url.value);
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Outdoor access'),
      body: Obx(() => ListView(padding: kPagePadding, children: [
            const AppNotice(
                'Chat with this phone from any browser or app, anywhere, through a free Cloudflare Worker that you own. '
                'The phone connects out to it, so no router settings are needed. Nothing is stored in the cloud: '
                'the phone does the thinking. The phone must stay on, and the app keeps running in the background while this is on.'),
            const SizedBox(height: 8),
            const SectionHeader('1 · Your Cloudflare token'),
            AppGroup(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text(
                      'Free account at cloudflare.com → My Profile → API Tokens → Create Token → use the "Edit Cloudflare Workers" template → copy the token.',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  TextField(
                      controller: _token,
                      obscureText: true,
                      decoration: appInputDecoration(context, hint: 'API token')),
                  const SizedBox(height: 8),
                  TextField(
                      controller: _account,
                      decoration: appInputDecoration(context, hint: 'Account ID (leave empty to find it automatically)')),
                  const SizedBox(height: 8),
                  TextField(
                      controller: _name,
                      decoration: appInputDecoration(context, hint: 'Worker name')),
                  const SizedBox(height: 6),
                  TextButton(
                      onPressed: () => launchUrl(Uri.parse('https://dash.cloudflare.com/profile/api-tokens'),
                          mode: LaunchMode.externalApplication),
                      child: const Text('Open Cloudflare tokens page')),
                ]),
              ),
            ]),
            const SectionHeader('2 · Protection'),
            AppGroup(children: [
              SwitchListTile(
                  title: const Text('Password for the web chat'),
                  value: _usePw,
                  onChanged: (v) => setState(() => _usePw = v)),
              if (_usePw)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: TextField(
                      controller: _password,
                      decoration: appInputDecoration(context, hint: 'Password')),
                ),
              SwitchListTile(
                  title: const Text('API key for apps and scripts'),
                  subtitle: const Text('Needed to use the API from outside'),
                  value: _useKey,
                  onChanged: (v) => setState(() => _useKey = v)),
              if (_useKey) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _key,
                            decoration: appInputDecoration(context, hint: 'API key'))),
                    IconButton(
                        tooltip: 'Generate',
                        icon: const Icon(Icons.casino_outlined),
                        onPressed: () => setState(() => _key.text = RelayService.randomSecret(40))),
                    IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () => Clipboard.setData(ClipboardData(text: _key.text))),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'cloud', label: Text('Checked by Cloudflare')),
                      ButtonSegment(value: 'local', label: Text('Checked by the phone')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (v) => setState(() => _mode = v.first),
                  ),
                ),
              ],
            ]),
            const SectionHeader('3 · Publish'),
            AppGroup(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  PrimaryButton(
                      label: r.deploying.value ? r.status.value : (r.url.value.isEmpty ? 'Create the relay' : 'Update the relay'),
                      onPressed: r.deploying.value ? null : _deploy),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
                ]),
              ),
              if (r.url.value.isNotEmpty) ...[
                AppRow(
                  icon: Icons.link_rounded,
                  title: r.url.value,
                  subtitle: 'Tap to copy. Open it in any browser.',
                  onTap: () => Clipboard.setData(ClipboardData(text: r.url.value)),
                  trailing: IconButton(
                      icon: const Icon(Icons.open_in_new_rounded),
                      onPressed: () => launchUrl(Uri.parse(r.url.value),
                          mode: LaunchMode.externalApplication)),
                ),
                SwitchListTile(
                  title: const Text('Remote access'),
                  subtitle: Text(r.enabled.value
                      ? (r.connected.value ? 'On · connected' : r.status.value)
                      : 'Off. Stays on until you turn it off.'),
                  value: r.enabled.value,
                  onChanged: (v) async {
                    try {
                      v ? await r.start() : await r.stop();
                    } catch (e) {
                      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
                    }
                  },
                ),
              ],
            ]),
            const SizedBox(height: 12),
            const AppNotice(
                'API from outside: POST /v1/chat/completions (chat, tools and memory included), /v1/audio/transcriptions, '
                '/v1/audio/speech, /v1/images/generations, and GET /v1/files to list and download files the AI created. '
                'Send "Authorization: Bearer <your key>".'),
          ])),
    );
  }
}
