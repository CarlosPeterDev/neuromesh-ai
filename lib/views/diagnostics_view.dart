import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';
import '../services/model_load_diagnostics.dart';

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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _report = DiagnosticsService.buildReport(
      includeRecentErrors: _includeErrors,
    );
  }

  Future<void> _send(String preview) async {
    if (_sending || _sent) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      await DiagnosticsService.sendReport(preview);
      if (mounted) setState(() => _sent = true);
    } on ReportSubmissionError catch (error) {
      if (mounted) setState(() => _sendError = error.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Report an error')),
        body: SafeArea(
          child: FutureBuilder<String>(
            future: _report,
            builder: (context, snapshot) {
              final ready = snapshot.connectionState == ConnectionState.done;
              final report = ready ? snapshot.data : null;
              final note = diagnosticText(_description.trim());
              final canSend = DiagnosticsService.canSendReport;
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
                            'Review the diagnostic report before sending. '
                            'Send report uploads the preview as a ZIP.',
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
                              labelText: 'What happened? (optional)',
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
                          if (!canSend)
                            const Text(
                                'Support uploads are unavailable in this build.'),
                          FilledButton.icon(
                            icon: Icon(_sent
                                ? Icons.check_rounded
                                : Icons.send_outlined),
                            label: Text(_sent
                                ? 'Report sent'
                                : _sending
                                    ? 'Sending…'
                                    : 'Send report'),
                            onPressed: !canSend || _sending || _sent
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
