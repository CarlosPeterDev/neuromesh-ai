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
  int _gen = 0;
  Future<void>? _loopFuture;
  SSHClient? _client;
  SSHRemoteForward? _forward;

  static TunnelService ensure() => Get.isRegistered<TunnelService>()
      ? Get.find<TunnelService>()
      : Get.put(TunnelService(), permanent: true);

  Future<void> start() async {
    if (_want || !supported) return;
    _want = true;
    final gen = ++_gen;
    running.value = true;
    final sc = Get.find<ServerController>();
    // Anyone with the link can reach the API, so a key is mandatory: switch it
    // on, generate one if needed and push it to a server that is already running.
    sc.useApiKey.value = true;
    await sc.saveSettings();
    if (!sc.isRunning.value) await sc.startServer();
    if (!_want || gen != _gen) return; // stopped while starting
    await _keepProcessAlive(true);
    final prev = _loopFuture;
    _loopFuture = () async {
      try {
        await prev;
      } catch (_) {}
      if (_want && gen == _gen) await _loop(gen);
    }();
  }

  Future<void> stop() async {
    _want = false;
    _gen++;
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

  Future<void> _loop(int gen) async {
    var wait = 2;
    while (_want && gen == _gen) {
      try {
        status.value = 'Connecting…';
        await _connectOnce(gen);
        wait = 2;
      } catch (e) {
        if (gen == _gen) status.value = 'Disconnected: ${'$e'.split('\n').first}';
      }
      if (gen != _gen) break;
      url.value = '';
      if (!_want) break;
      await Future.delayed(Duration(seconds: wait));
      wait = (wait * 2).clamp(2, 30);
    }
  }

  Future<void> _connectOnce(int gen) async {
    SSHClient? client;
    SSHRemoteForward? fwd;
    try {
      final socket = await SSHSocket.connect('localhost.run', 22,
          timeout: const Duration(seconds: 15));
      client = SSHClient(
        socket,
        username: 'nokey',
        onPasswordRequest: () => '',
        keepAliveInterval: const Duration(seconds: 20),
      );
      _client = client;
      await client.authenticated;
      if (gen != _gen) throw Exception('stopped');

      // Ask the server to listen on port 80 and send us every connection.
      fwd = await client.forwardRemote(port: 80);
      if (fwd == null) throw Exception('localhost.run refused the tunnel');
      if (gen != _gen) throw Exception('stopped');
      _forward = fwd;
      await _serve(client, fwd, gen);
    } finally {
      // Never leave a half-open connection behind, whatever went wrong.
      try {
        fwd?.close();
      } catch (_) {}
      try {
        client?.close();
      } catch (_) {}
      if (identical(_client, client)) _client = null;
      if (identical(_forward, fwd)) _forward = null;
    }
  }

  Future<void> _serve(SSHClient client, SSHRemoteForward fwd, int gen) async {
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
