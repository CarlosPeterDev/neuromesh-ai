import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Read-only Android grants. Permission prompts remain attached to feature use.
class DeviceAccessStatus extends StatefulWidget {
  const DeviceAccessStatus({super.key});
  @override
  State<DeviceAccessStatus> createState() => _DeviceAccessStatusState();
}

class _DeviceAccessStatusState extends State<DeviceAccessStatus>
    with WidgetsBindingObserver {
  Map<String, PermissionStatus>? _statuses;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (!Platform.isAndroid) return;
    try {
      final mic = await Permission.microphone.status;
      final cam = await Permission.camera.status;
      if (mounted)
        setState(() {
          _statuses = {'Microphone': mic, 'Camera': cam};
          _error = null;
        });
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Could not read Android permissions.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Android access',
          style: TextStyle(fontWeight: FontWeight.bold)),
      if (_error != null)
        Text(_error!)
      else if (_statuses == null)
        const Text('Checking permissions…')
      else
        for (final entry in _statuses!.entries)
          Text(
              '${entry.key}: ${entry.value.isGranted ? 'Allowed' : entry.value.isPermanentlyDenied ? 'Blocked in Android settings' : 'Not allowed'}'),
      const Text(
          'Shared folder access is granted separately by selecting a folder below.'),
      TextButton(
          onPressed: () async {
            await openAppSettings();
          },
          child: const Text('Open Android app settings')),
    ]);
  }
}
