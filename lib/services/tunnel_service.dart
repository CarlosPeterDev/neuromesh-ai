import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:get/get.dart';

import '../controllers/server_controller.dart';

/// A free, temporary public link to this phone's local API: no account, no
/// API key, no Cloudflare. It opens an SSH reverse tunnel to localhost.run
/// (anonymous user "nokey"); everything that arrives on the public https URL
/// is passed to the local server on 127.0.0.1.
///
/// The link changes every time it is started and stops working when the app
/// closes, so it is meant for quick sharing. Anyone with the link can call the
/// API, so the local API key is switched on while the tunnel is up.
class TunnelService extends GetxService {
  static bool get supported => !kIsWeb;

  final running = false.obs;
  final status = 'Off'.obs;
  final url = ''.obs;

  bool _want = false;
  SSHClient? _client;
  SSHRemoteForward? _forward;

  static TunnelService ensure() => Get.isRegistered<TunnelService>()
      ? Get.find<TunnelService>()
      : Get.put(TunnelService(), permanent: true);

  Future<void> start() async {
    if (_want || !supported) return;
    _want = true;
    running.value = true;
    final sc = Get.find<ServerController>();
    if (!sc.useApiKey.value) sc.useApiKey.value = true;
    if (!sc.isRunning.value) await sc.startServer();
    await _keepProcessAlive(true);
    unawaited(_loop());
  }

  Future<void> stop() async {
    _want = false;
    running.value = false;
    status.value = 'Off';
    url.value = '';
    try {
      _forward?.close();
    } catch (_) {}
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
    _forward = null;
    await _keepProcessAlive(false);
  }

  Future<void> _keepProcessAlive(bool on) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final svc = FlutterBackgroundService();
      if (on) {
        if (!await svc.isRunning()) await svc.startService();
        svc.invoke('keepAlive', {'on': true});
        svc.invoke('progress', {
          'title': 'Temporary link is on',
          'content': url.value.isEmpty ? 'Connecting…' : url.value,
        });
      } else {
        svc.invoke('keepAlive', {'on': false});
        svc.invoke('forceStop');
      }
    } catch (_) {}
  }

  Future<void> _loop() async {
    var wait = 2;
    while (_want) {
      try {
        status.value = 'Connecting…';
        await _connectOnce();
        wait = 2;
      } catch (e) {
        status.value = 'Disconnected: ${'$e'.split('\n').first}';
      }
      url.value = '';
      if (!_want) break;
      await Future.delayed(Duration(seconds: wait));
      wait = (wait * 2).clamp(2, 30);
    }
  }

  Future<void> _connectOnce() async {
    final socket = await SSHSocket.connect('localhost.run', 22,
        timeout: const Duration(seconds: 15));
    final client = SSHClient(
      socket,
      username: 'nokey',
      onPasswordRequest: () => '',
      keepAliveInterval: const Duration(seconds: 20),
    );
    _client = client;
    await client.authenticated;

    // Ask the server to listen on port 80 and send us every connection.
    final fwd = await client.forwardRemote(port: 80);
    if (fwd == null) throw Exception('localhost.run refused the tunnel');
    _forward = fwd;
    final port = ServerController.port;
    fwd.connections.listen((conn) async {
      try {
        final local = await Socket.connect('127.0.0.1', port);
        conn.stream.cast<List<int>>().listen(local.add,
            onDone: () => local.close(), onError: (_) => local.destroy());
        local.listen((d) => conn.sink.add(Uint8List.fromList(d)),
            onDone: () => conn.sink.close(), onError: (_) => conn.sink.close());
      } catch (_) {
        conn.sink.close();
      }
    });

    // The public address is printed on the session's output.
    final shell = await client.shell();
    final re = RegExp(r'https://[a-z0-9\-]+\.(?:lhr\.life|localhost\.run)');
    var buf = '';
    shell.stdout.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
      buf += chunk;
      final m = re.firstMatch(buf);
      if (m != null && url.value.isEmpty) {
        url.value = m.group(0)!;
        status.value = 'Online';
        _keepProcessAlive(true);
      }
    });
    await client.done;
    throw Exception('connection closed');
  }
}
