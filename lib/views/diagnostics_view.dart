import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';

class DiagnosticsView extends StatefulWidget {
  const DiagnosticsView({super.key});

  @override
  State<DiagnosticsView> createState() => _DiagnosticsViewState();
}

class _DiagnosticsViewState extends State<DiagnosticsView> {
  late Future<String> _report;
  bool _includeErrors = false;
  bool _sharing = false;

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
              final preview = ready ? snapshot.data : null;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Text(
                            'Review the device and model diagnostics below. '
                            'Share ZIP lets you choose where to send the report.',
                          ),
                        ),
                        SwitchListTile(
                          value: _includeErrors,
                          title: const Text('Include recent app errors'),
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
                          label:
                              Text(_sharing ? 'Preparing ZIP…' : 'Share ZIP'),
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
