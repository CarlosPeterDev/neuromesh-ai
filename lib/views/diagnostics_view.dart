import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';
import '../services/model_load_diagnostics.dart';
import '../services/telegram_report_delivery.dart';

class DiagnosticsView extends StatefulWidget {
  const DiagnosticsView({super.key});

  @override
  State<DiagnosticsView> createState() => _DiagnosticsViewState();
}

class _DiagnosticsViewState extends State<DiagnosticsView> {
  late Future<String> _report;
  bool _includeErrors = false;
  bool _sending = false;
  bool _sent = false;
  String? _sendError;
  String _description = '';
  TelegramReportDelivery? _direct;
  bool _loadingDelivery = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadDelivery();
  }

  void _refresh() {
    _report = DiagnosticsService.buildReport(
      includeRecentErrors: _includeErrors,
    );
  }

  Future<void> _loadDelivery() async {
    try {
      final delivery = await TelegramReportDelivery.load();
      if (mounted) setState(() => _direct = delivery);
    } catch (_) {
      if (mounted)
        setState(() => _sendError = 'Could not read saved Telegram settings.');
    } finally {
      if (mounted) setState(() => _loadingDelivery = false);
    }
  }

  Future<void> _editDelivery() async {
    var token = '';
    var chat = _direct?.chatId ?? '';
    bool remove = false;
    try {
      final delivery = await showDialog<TelegramReportDelivery>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) {
            final parsed = TelegramReportDelivery.parse(token, chat);
            return AlertDialog(
              title: const Text('Direct Telegram delivery'),
              content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'These credentials are saved on this device. This destination receives your diagnostic ZIP.'),
                  TextFormField(
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(labelText: 'Bot token'),
                      onChanged: (value) => update(() => token = value)),
                  TextFormField(
                      initialValue: chat,
                      keyboardType:
                          const TextInputType.numberWithOptions(signed: true),
                      decoration: const InputDecoration(labelText: 'Chat ID'),
                      onChanged: (value) => update(() => chat = value)),
                ]),
              ),
              actions: [
                if (_direct != null)
                  TextButton(
                      onPressed: () {
                        remove = true;
                        Navigator.pop(context);
                      },
                      child: const Text('Remove')),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: parsed == null
                        ? null
                        : () => Navigator.pop(context, parsed),
                    child: const Text('Save')),
              ],
            );
          },
        ),
      );
      if (remove) {
        await TelegramReportDelivery.clear();
      } else if (delivery != null) {
        await delivery.save();
      } else {
        return;
      }
      if (mounted)
        setState(() {
          _direct = delivery;
          _sendError = null;
        });
    } catch (_) {
      if (mounted)
        setState(
            () => _sendError = 'Could not save credentials to secure storage.');
    }
  }

  Future<void> _send(String preview) async {
    if (_sending || _sent) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      await DiagnosticsService.sendReport(preview, direct: _direct);
      if (mounted) setState(() => _sent = true);
    } on ReportSubmissionError catch (error) {
      if (mounted) setState(() => _sendError = error.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Report an error'), actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Telegram delivery settings',
            onPressed:
                _loadingDelivery || _sending || _sent ? null : _editDelivery,
          ),
        ]),
        body: SafeArea(
          child: FutureBuilder<String>(
            future: _report,
            builder: (context, snapshot) {
              final ready = snapshot.connectionState == ConnectionState.done;
              final report = ready ? snapshot.data : null;
              final note = diagnosticText(_description.trim());
              final preview = report == null || note.isEmpty
                  ? report
                  : 'Problem description\n$note\n\n$report';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Text(
                            'Your report goes to NeuroMesh support via Telegram '
                            'when you tap Send report. Review the preview first.',
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: TextFormField(
                            initialValue: _description,
                            enabled: !_sending && !_sent,
                            minLines: 2,
                            maxLines: 4,
                            maxLength: 1500,
                            decoration: const InputDecoration(
                              labelText: 'What happened?',
                              hintText:
                                  'What did you try, and what did you expect?',
                            ),
                            onChanged: (value) =>
                                setState(() => _description = value),
                          ),
                        ),
                        SwitchListTile(
                          value: _includeErrors,
                          title: const Text('Include recent app logs'),
                          subtitle: const Text(
                            'Review these logs for personal details before sending.',
                          ),
                          onChanged: (_sending || _sent)
                              ? null
                              : (value) => setState(() {
                                    _includeErrors = value;
                                    _refresh();
                                  }),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: preview != null
                              ? SelectableText(preview,
                                  style:
                                      const TextStyle(fontFamily: 'monospace'))
                              : Center(
                                  child: ready
                                      ? TextButton(
                                          onPressed: () => setState(_refresh),
                                          child: const Text(
                                              'Could not prepare report. Retry'),
                                        )
                                      : const CircularProgressIndicator(),
                                ),
                        ),
                      ],
                    ),
                  ),
                  if (preview != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_sendError case final message?)
                            Text(message,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)),
                          if (_direct == null &&
                              !DiagnosticsService.canSendReport)
                            const Text(
                                'Open Telegram delivery settings to connect your bot.'),
                          FilledButton.icon(
                            icon: Icon(_sent
                                ? Icons.check_rounded
                                : Icons.send_outlined),
                            label: Text(_sent
                                ? 'Report sent'
                                : _sending
                                    ? 'Sending…'
                                    : 'Send report'),
                            onPressed: _sending ||
                                    _sent ||
                                    note.isEmpty ||
                                    (_direct == null &&
                                        !DiagnosticsService.canSendReport)
                                ? null
                                : () => _send(preview),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
}
