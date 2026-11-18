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
  bool _sharing = false;
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

  Future<void> _share(BuildContext buttonContext, String preview) async {
    final box = buttonContext.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _sharing = true);
    try {
      await DiagnosticsService.shareReport(
        preview,
        sharePositionOrigin: origin,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not share the ZIP. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
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
                            'Describe the problem and review the diagnostic '
                            'details before sharing your report.',
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: TextFormField(
                            initialValue: _description,
                            enabled: !_sharing,
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
                            'Review these logs for personal details before sharing.',
                          ),
                          onChanged: _sharing
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
                      child: Builder(
                        builder: (buttonContext) => FilledButton.icon(
                          icon: const Icon(Icons.share_outlined),
                          label: Text(
                              _sharing ? 'Preparing report…' : 'Share report'),
                          onPressed: _sharing
                              ? null
                              : () => _share(buttonContext, preview),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
}
