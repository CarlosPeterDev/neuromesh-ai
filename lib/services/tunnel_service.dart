import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:get/get.dart';

import '../controllers/server_controller.dart';
import 'app_log_service.dart';

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
    status.value = 'Starting the local API…';
    try {
      final sc = Get.find<ServerController>();
      sc.useApiKey.value = true;
      await sc.saveSettings().timeout(const Duration(seconds: 10));
      if (!_want || gen != _gen) return;
      if (!sc.isRunning.value) {
        await sc.startServer().timeout(const Duration(seconds: 10));
      }
      if (!_want || gen != _gen) return;
      if (!sc.isRunning.value || sc.apiKey.value.trim().isEmpty) {
        throw const _TunnelFailure(
            'The local API could not start with an API key.');
      }
    } catch (error, stack) {
      if (gen == _gen) _fail(error, stack, 'The local API could not start.');
      return;
    }
    unawaited(_keepProcessAlive(true));
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

  void _fail(Object error, StackTrace stack, String message) {
    _want = false;
    running.value = false;
    url.value = '';
    status.value = error is _TunnelFailure ? error.message : message;
    if (Get.isRegistered<AppLogService>()) {
      Get.find<AppLogService>()
          .error('Temporary link failed', details: '$error\n$stack');
    }
    unawaited(_keepProcessAlive(false));
  }

  Future<void> _loop(int gen) async {
    while (_want && gen == _gen) {
      try {
        await _connectOnce(gen);
      } catch (error, stack) {
        if (gen != _gen || !_want) return;
        if (url.value.isEmpty || error is _TunnelFailure) {
          _fail(error, stack,
              'Could not establish the temporary link. Try again.');
          return;
        }
      }
      if (gen != _gen || !_want) return;
      url.value = '';
      status.value = 'Link disconnected. Reconnecting…';
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  // Published by the tunnel provider: https://localhost.run/docs/security
  static bool verifyHostKey(String algorithm, Uint8List fingerprint) {
    final expected = switch (algorithm) {
      'ssh-ed25519' => 'SHA256:pG6qrBxubYfWa1Zadu/V0NUgjEDiBds/7e2xzte/QNM',
      'ssh-rsa' ||
      'rsa-sha2-256' ||
      'rsa-sha2-512' =>
        'SHA256:FV8IMJ4IYjYUTnd6on7PqbRjaZf4c1EhhEBgeUdE94I',
      _ => null,
    };
    return expected != null &&
        ascii.decode(fingerprint, allowInvalid: true) == expected;
  }

  Future<void> _connectOnce(int gen) async {
    SSHClient? client;
    SSHRemoteForward? fwd;
    SSHSession? session;
    void checkCurrent() {
      if (!_want || gen != _gen) throw const _TunnelFailure('Link stopped.');
    }

    final address = Completer<String>();
    final banners = TunnelAddress();
    void readAddress(String chunk) {
      final link = banners.add(chunk);
      if (link != null && !address.isCompleted) address.complete(link);
    }

    try {
      status.value = 'Connecting to localhost.run…';
      final socket = await SSHSocket.connect('localhost.run', 22,
              timeout: const Duration(seconds: 12))
          .onError((error, stack) {
        throw const _TunnelFailure(
            'Could not reach localhost.run on SSH port 22. Try another network.');
      });
      if (gen != _gen || !_want) {
        await socket.close();
        return;
      }
      var rejectedHost = false;
      client = SSHClient(
        socket,
        username: 'nokey',
        onVerifyHostKey: (algorithm, fingerprint) {
          final verified = verifyHostKey(algorithm, fingerprint);
          rejectedHost = !verified;
          return verified;
        },
        onUserauthBanner: readAddress,
        onPasswordRequest: () => '',
        keepAliveInterval: const Duration(seconds: 20),
      );
      _client = client;
      final done =
          client.done.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      status.value = 'Verifying the SSH server…';
      try {
        await client.authenticated.timeout(const Duration(seconds: 12));
      } catch (_) {
        throw _TunnelFailure(rejectedHost
            ? 'localhost.run presented an unrecognized SSH host key.'
            : 'SSH verification or sign-in failed. Try creating the link again.');
      }
      checkCurrent();

      status.value = 'Requesting the temporary link…';
      fwd = await client
          .forwardRemote(host: 'localhost', port: 80)
          .timeout(const Duration(seconds: 10), onTimeout: () {
        throw const _TunnelFailure(
            'localhost.run did not answer the forwarding request.');
      });
      if (fwd == null) {
        throw const _TunnelFailure(
            'localhost.run refused the forwarding request.');
      }
      checkCurrent();
      _forward = fwd;
      fwd.connections.listen(_forwardConnection);

      if (!address.isCompleted) {
        session = await client.shell().timeout(const Duration(seconds: 8));
        session.stdout
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(readAddress);
        session.stderr
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(readAddress);
      }
      final link = await Future.any([
        address.future,
        done.then<String>((_) {
          throw const _TunnelFailure(
              'localhost.run closed SSH before returning a link.');
        }),
      ]).timeout(const Duration(seconds: 12), onTimeout: () {
        throw const _TunnelFailure(
            'localhost.run connected but did not return a public link.');
      });
      checkCurrent();
      url.value = link;
      status.value = 'Online';
      unawaited(_keepProcessAlive(true));
      await done;
    } finally {
      try {
        session?.close();
        if (fwd != null && identical(_forward, fwd)) fwd.close();
      } finally {
        client?.close();
      }
      if (identical(_client, client)) _client = null;
      if (identical(_forward, fwd)) _forward = null;
    }
  }

  Future<void> _forwardConnection(SSHForwardChannel conn) async {
    try {
      final local = await Socket.connect('127.0.0.1', ServerController.port,
          timeout: const Duration(seconds: 5));
      conn.stream.cast<List<int>>().listen(local.add,
          onDone: () => local.close(), onError: (_) => local.destroy());
      local.listen(conn.sink.add,
          onDone: () => conn.sink.close(), onError: (_) => conn.sink.close());
    } catch (_) {
      conn.sink.close();
    }
  }
}

class _TunnelFailure implements Exception {
  const _TunnelFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Collects URL fragments from SSH banners and streams without growing forever.
class TunnelAddress {
  static final _link = RegExp(
    r'https://[a-z0-9-]+\.(?:lhr\.(?:life|rocks)|localhost\.run)(?![a-z0-9.-])',
    caseSensitive: false,
  );
  String _buffer = '';

  String? add(String chunk) {
    _buffer += chunk;
    if (_buffer.length > 8192)
      _buffer = _buffer.substring(_buffer.length - 8192);
    return _link.firstMatch(_buffer)?.group(0);
  }
}
