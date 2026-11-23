import 'package:flutter/material.dart';

/// Opens storage before constructing anything that can read it.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.openStorage,
    required this.startApp,
    required this.onError,
  });

  final Future<void> Function() openStorage;
  final Future<Widget> Function() startApp;
  final void Function(Object, StackTrace) onError;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  late Future<Widget> _startup;
  bool _storageReady = false;

  @override
  void initState() {
    super.initState();
    _startup = _start();
  }

  Future<Widget> _start() async {
    try {
      if (!_storageReady) {
        await widget.openStorage();
        _storageReady = true;
      }
      return await widget.startApp();
    } catch (error, stack) {
      widget.onError(error, stack);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Widget>(
        future: _startup,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData) {
            return snapshot.requireData;
          }
          final failed = snapshot.connectionState == ConnectionState.done &&
              snapshot.hasError;
          return MaterialApp(
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!failed) const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        failed
                            ? _storageReady
                                ? 'NeuroMesh could not finish starting. Restart the app to try again.'
                                : 'Could not open chat storage. Check the available storage and try again. Existing data is retained.'
                            : 'Starting NeuroMesh…',
                        textAlign: TextAlign.center,
                      ),
                      if (failed && !_storageReady)
                        FilledButton(
                          onPressed: () {
                            final next = _start();
                            setState(() {
                              _startup = next;
                            });
                          },
                          child: const Text('Retry'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
}
