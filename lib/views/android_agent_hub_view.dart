import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../services/android_opencode.dart';
import '../services/inference_service.dart';
import '../services/openai_server_service_io.dart';
import '../services/opencode_server_client.dart';
import 'agent_hub_view.dart';

class AndroidAgentHubView extends StatefulWidget {
  const AndroidAgentHubView({super.key});

  @override
  State<AndroidAgentHubView> createState() => _AndroidAgentHubViewState();
}

class _AndroidAgentHubViewState extends State<AndroidAgentHubView> {
  final _address = TextEditingController(text: 'http://127.0.0.1:4096');
  final _username = TextEditingController(text: 'opencode');
  final _password = TextEditingController();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inference = Get.find<InferenceService>();
  OpenCodeServerClient? _server;
  OpenAiServerService? _bridge;
  String? _bridgeKey;
  String? _bridgeConfig;
  OpenCodeModel? _model;
  List<OpenCodeModel> _models = [];
  String? _session;
  List<OpenCodeMessage> _messages = [];
  String _partial = '';
  String _tool = '';
  String? _error;
  bool _busy = false;
  bool _sending = false;
  bool _allowWorkspaceReads = false;

  String _t(String en, String ar) => agentHubUsesArabic(context) ? ar : en;

  Future<void> _act(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _act(() async {
        final client = OpenCodeServerClient(
            _address.text, _username.text.trim(), _password.text);
        try {
          await client.verify();
          final models = await client.models();
          if (!mounted) {
            client.close();
            return;
          }
          setState(() {
            _server = client;
            _models = models;
            _password.clear();
          });
        } catch (_) {
          client.close();
          rethrow;
        }
      });

  Future<void> _disconnect() => _act(() async {
        _server?.close();
        final bridge = _bridge;
        setState(() {
          _server = null;
          _bridge = null;
          _bridgeKey = null;
          _bridgeConfig = null;
          _session = null;
          _models = [];
          _model = null;
          _messages = [];
          _tool = '';
        });
        await bridge?.stop();
      });

  Future<void> _localBridge() => _act(() async {
        if (_bridge == null) {
          final model = _inference.loadedModelName.value;
          final contextTokens = _inference.contextTokensTotal.value;
          final random = Random.secure();
          final key = List.generate(32,
                  (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
              .join();
          final bridge = OpenAiServerService.forAgentModel(
            model,
            allowTools: _allowWorkspaceReads,
          );
          await bridge.start(port: 0, apiKey: key);
          if (!mounted) {
            await bridge.stop();
            return;
          }
          setState(() {
            _bridge = bridge;
            _bridgeKey = key;
            _bridgeConfig = OpenCodeLocalProfile.localProviderConfig(
                name: model,
                context: contextTokens,
                endpoint: '${bridge.localUrl}/v1',
                allowTools: _allowWorkspaceReads);
          });
        }
        await _showModelConfig();
      });

  Future<void> _showModelConfig() async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
            _t('Same-phone local model', 'النموذج المحلي على الهاتف نفسه')),
        content: SingleChildScrollView(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t(
              'Use this configuration in a separate OpenCode profile on this phone. Set NEUROMESH_BRIDGE_KEY in the server environment. Restart the server if it is already running. The key expires when the bridge stops.',
              'استخدم هذا الإعداد في ملف تعريف منفصل لـ OpenCode على هذا الهاتف. اضبط NEUROMESH_BRIDGE_KEY في بيئة الخادم. أعد تشغيل الخادم إذا كان يعمل. تنتهي صلاحية المفتاح عند إيقاف الاتصال بالنموذج.',
            )),
            const SizedBox(height: 12),
            const Text('NEUROMESH_BRIDGE_KEY'),
            SelectableText(_bridgeKey!, textDirection: TextDirection.ltr),
          ],
        )),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: _bridgeConfig!)),
            child: Text(_t('Copy configuration', 'نسخ الإعداد')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_t('Done', 'تم')),
          ),
        ],
      ),
    );
  }

  Future<void> _stopBridge() => _act(() async {
        final bridge = _bridge;
        setState(() {
          _bridge = null;
          _bridgeKey = null;
          _bridgeConfig = null;
        });
        await bridge?.stop();
      });

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });

  Future<void> _openSession() => _act(() async {
        final sessions = await _server!.sessions();
        if (!mounted) return;
        final selected = await showDialog<String>(
          context: context,
          builder: (dialog) => SimpleDialog(
            title: Text(_t('OpenCode sessions', 'جلسات OpenCode')),
            children: [
              for (final session in sessions)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialog, session.id),
                    child: Text(session.title)),
              if (sessions.isEmpty)
                Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(_t('No sessions', 'لا توجد جلسات'))),
            ],
          ),
        );
        if (selected == null || !mounted) return;
        final history = await _server!.history(selected);
        if (!mounted) return;
        setState(() {
          _session = selected;
          _messages = history;
          _tool = '';
        });
        _toEnd();
      });

  Future<void> _send() async {
    final model = _model;
    final text = _input.text.trim();
    if (_busy || model == null || text.isEmpty) return;
    await _act(() async {
      final server = _server!;
      final session = _session ??
          await server.createSession(allowWorkspaceReads: _allowWorkspaceReads);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _session = session;
        _messages.add((role: 'user', text: text));
        _tool = '';
        _sending = true;
      });
      _toEnd();
      try {
        await server.send(session, model, text, onText: (token) {
          if (mounted) setState(() => _partial += token);
          _toEnd();
        }, onTool: (tool) {
          if (mounted) setState(() => _tool = tool);
        });
      } finally {
        if (mounted) {
          setState(() => _sending = false);
          try {
            final history = await server.history(session);
            if (mounted) setState(() => _messages = history);
          } finally {
            if (mounted) setState(() => _partial = '');
          }
          _toEnd();
        }
      }
    });
  }

  Future<void> _abort() async {
    try {
      await _server?.abort(_session!);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _server?.close();
    unawaited(_bridge?.stop());
    _address.dispose();
    _username.dispose();
    _password.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: appScreenBar(context, title: _t('Agents', 'الوكلاء')),
        body: SafeArea(
            child: Column(children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Expanded(child: _server == null ? _setup() : _chat()),
        ])),
      );

  Widget _setup() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('OpenCode', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(_t(
            'Connect to an OpenCode server you manage. NeuroMesh does not install Linux or OpenCode. Messages are sent to the server you connect to.',
            'اتصل بخادم OpenCode تديره بنفسك. لا يثبّت NeuroMesh نظام Linux أو OpenCode. تُرسل الرسائل إلى الخادم الذي تتصل به.',
          )),
          Text(_t(
            'Use OpenCode 1.19.6 with server authentication. For a server on another device, use HTTPS. Terminal is available from your OpenCode host.',
            'استخدم OpenCode 1.19.6 مع مصادقة الخادم وHTTPS عند الاتصال بجهاز آخر. استخدم الطرفية على جهاز خادم OpenCode.',
          )),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_t('Allow workspace reads in new chats',
                'السماح بقراءة ملفات المشروع في المحادثات الجديدة')),
            subtitle: Text(_t(
                'Requires a compatible model. Existing sessions use the server’s permissions.',
                'يتطلب نموذجًا متوافقًا. تستخدم الجلسات الحالية أذونات الخادم.')),
            value: _allowWorkspaceReads,
            onChanged: _busy || _bridge != null
                ? null
                : (value) => setState(() => _allowWorkspaceReads = value),
          ),
          Obx(() => OutlinedButton.icon(
                onPressed: !_busy &&
                        (_bridge != null || _inference.isModelLoaded.value)
                    ? _localBridge
                    : null,
                icon: const Icon(Icons.memory),
                label: Text(_bridge != null
                    ? _t('View phone model configuration',
                        'عرض إعدادات نموذج الهاتف')
                    : _t(
                        'Link loaded phone model', 'ربط نموذج الهاتف المحمّل')),
              )),
          if (_bridge != null)
            TextButton(
                onPressed: _busy ? null : _stopBridge,
                child: Text(_t('Stop model bridge', 'إيقاف ربط النموذج'))),
          TextField(
              controller: _address,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                  labelText: _t('Server address', 'عنوان الخادم'))),
          TextField(
              controller: _username,
              enabled: !_busy,
              textDirection: TextDirection.ltr,
              decoration:
                  InputDecoration(labelText: _t('Username', 'اسم المستخدم'))),
          TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                  labelText: _t('Server password', 'كلمة مرور الخادم'))),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: _busy ? null : _connect,
              child: Text(_t('Connect to OpenCode', 'الاتصال بـ OpenCode'))),
        ],
      );

  Widget _chat() => Column(children: [
        ListTile(
          title: Text(_t('OpenCode connected', 'تم الاتصال بـ OpenCode')),
          subtitle: Text(_server!.endpoint.authority,
              textDirection: TextDirection.ltr),
          trailing: IconButton(
              icon: const Icon(Icons.link_off),
              onPressed: _busy ? null : _disconnect,
              tooltip: _t('Disconnect', 'قطع الاتصال')),
        ),
        if (_models.isEmpty)
          Text(_t('Configure a model on the server, then reconnect.',
              'أعد الاتصال بعد إعداد نموذج على الخادم.'))
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<OpenCodeModel>(
              value: _model,
              isExpanded: true,
              hint: Text(_t('Select a server model', 'اختيار نموذج الخادم')),
              onChanged:
                  _busy ? null : (model) => setState(() => _model = model),
              items: [
                for (final model in _models)
                  DropdownMenuItem(
                      value: model,
                      child: Text('${model.name} · ${model.provider}',
                          overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        Wrap(children: [
          TextButton(
              onPressed: _busy ? null : _openSession,
              child: Text(_t('Sessions', 'الجلسات'))),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _session = null;
                      _messages = [];
                      _tool = '';
                    }),
            child: Text(_t('New chat', 'محادثة جديدة')),
          ),
        ]),
        Expanded(
            child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (final message in _messages)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(message.role == 'user'
                          ? _t('You', 'أنت')
                          : 'OpenCode'),
                      if (message.role == 'user')
                        SelectableText(message.text)
                      else
                        MarkdownBody(data: message.text, selectable: true),
                    ],
                  )),
            if (_partial.isNotEmpty)
              MarkdownBody(data: _partial, selectable: true),
            if (_tool.isNotEmpty)
              ListTile(
                  leading: const Icon(Icons.build_outlined),
                  title: Text(_tool)),
          ],
        )),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: _input,
                    enabled: !_busy && _model != null,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                        hintText: _t('Ask OpenCode', 'اسأل OpenCode')))),
            IconButton(
              tooltip: _sending ? _t('Stop', 'إيقاف') : _t('Send', 'إرسال'),
              icon: Icon(_sending ? Icons.stop_circle_outlined : Icons.send),
              onPressed:
                  _sending ? _abort : (_busy || _model == null ? null : _send),
            ),
          ]),
        ),
      ]);
}
