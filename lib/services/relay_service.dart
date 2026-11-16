import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../controllers/server_controller.dart';
import 'hive_service.dart';
import 'relay_worker_script.dart';

/// Reach this phone from anywhere through a free Cloudflare Worker.
/// The phone connects OUT to the Worker; web chat and the API are served at
/// the Worker's address and forwarded to the phone's own local server.
class RelayService extends GetxService {
  static const _cf = 'https://api.cloudflare.com/client/v4';

  final connected = false.obs;
  final deploying = false.obs;
  final status = 'Off'.obs;
  final enabled = false.obs;
  final url = ''.obs;

  HiveService get _hive => Get.find<HiveService>();

  // Stored settings
  String get cfToken => _hive.getSetting<String>('relay_cf_token') ?? '';
  String get cfAccount => _hive.getSetting<String>('relay_cf_account') ?? '';
  String get workerName => _hive.getSetting<String>('relay_worker') ?? 'neuromesh-relay';
  String get password => _hive.getSetting<String>('relay_password') ?? '';
  String get apiKey => _hive.getSetting<String>('relay_api_key') ?? '';

  /// 'cloud': Cloudflare checks the API key. 'local': the phone checks it.
  String get keyMode => _hive.getSetting<String>('relay_key_mode') ?? 'cloud';
  String get relayToken => _hive.getSetting<String>('relay_token') ?? '';

  WebSocket? _ws;
  Timer? _ping;
  bool _wantOn = false;
  int _retry = 0;
  final _reqs = <String, _Req>{};

  @override
  void onInit() {
    super.onInit();
    url.value = _hive.getSetting<String>('relay_url') ?? '';
    // Persistent until turned off: resume after an app restart.
    if (!kIsWeb && (_hive.getSetting<bool>('relay_on') ?? false) && url.value.isNotEmpty) {
      Future.delayed(const Duration(seconds: 4), () => start());
    }
  }

  Future<void> saveSettings({
    String? token,
    String? account,
    String? name,
    String? password,
    String? apiKey,
    String? keyMode,
  }) async {
    if (token != null) await _hive.setSetting('relay_cf_token', token.trim());
    if (account != null) await _hive.setSetting('relay_cf_account', account.trim());
    if (name != null && name.trim().isNotEmpty) {
      await _hive.setSetting('relay_worker', name.trim().toLowerCase());
    }
    if (password != null) await _hive.setSetting('relay_password', password);
    if (apiKey != null) await _hive.setSetting('relay_api_key', apiKey.trim());
    if (keyMode != null) await _hive.setSetting('relay_key_mode', keyMode);
  }

  static String randomSecret([int n = 32]) {
    const c = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random.secure();
    return List.generate(n, (_) => c[r.nextInt(c.length)]).join();
  }

  // ── Deploying the Worker with the user's own Cloudflare token ────────

  Future<Map<String, dynamic>> _api(String method, String path,
      {Object? json, List<int>? body, Map<String, String>? headers}) async {
    final req = http.Request(method, Uri.parse('$_cf$path'));
    req.headers['Authorization'] = 'Bearer $cfToken';
    if (json != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(json);
    }
    if (body != null) req.bodyBytes = body;
    if (headers != null) req.headers.addAll(headers);
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 60)));
    Map<String, dynamic> j;
    try {
      j = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Cloudflare replied ${res.statusCode}.');
    }
    if (j['success'] != true) {
      final errs = (j['errors'] as List?)?.map((e) => '${(e as Map)['message']}').join('; ') ?? 'unknown error';
      throw Exception(errs);
    }
    return j;
  }

  /// Uploads the Worker, turns on its workers.dev address and returns the URL.
  Future<String> deploy() async {
    if (cfToken.isEmpty) throw Exception('Paste your Cloudflare API token first.');
    deploying.value = true;
    try {
      status.value = 'Finding your Cloudflare account…';
      var account = cfAccount;
      if (account.isEmpty) {
        final r = await _api('GET', '/accounts');
        final list = (r['result'] as List?) ?? const [];
        if (list.isEmpty) throw Exception('No account found for this token. Enter the Account ID by hand.');
        account = '${(list.first as Map)['id']}';
        await saveSettings(account: account);
      }

      if (relayToken.isEmpty) await _hive.setSetting('relay_token', randomSecret());

      status.value = 'Uploading the relay…';
      final bindings = <Map<String, String>>[
        {'type': 'durable_object_namespace', 'name': 'RELAY', 'class_name': 'Relay'},
        {'type': 'secret_text', 'name': 'RELAY_TOKEN', 'text': relayToken},
        {'type': 'plain_text', 'name': 'KEY_MODE', 'text': keyMode},
        if (password.isNotEmpty) {'type': 'secret_text', 'name': 'PASSWORD', 'text': password},
        if (apiKey.isNotEmpty && keyMode == 'cloud')
          {'type': 'secret_text', 'name': 'API_KEY', 'text': apiKey},
      ];
      Future<void> upload(bool withMigration) async {
        final meta = {
          'main_module': 'worker.js',
          'compatibility_date': '2025-01-01',
          'bindings': bindings,
          if (withMigration) 'migrations': {'new_tag': 'v1', 'new_sqlite_classes': ['Relay']},
        };
        final boundary = 'nm${randomSecret(16)}';
        final b = BytesBuilder();
        void part(String name, String type, String content, {String? filename}) {
          b.add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="$name"'
              '${filename != null ? '; filename="$filename"' : ''}\r\nContent-Type: $type\r\n\r\n'));
          b.add(utf8.encode(content));
          b.add(utf8.encode('\r\n'));
        }

        part('metadata', 'application/json', jsonEncode(meta));
        part('worker.js', 'application/javascript+module', kRelayWorkerScript, filename: 'worker.js');
        b.add(utf8.encode('--$boundary--\r\n'));
        await _api('PUT', '/accounts/$account/workers/scripts/$workerName',
            body: b.takeBytes(),
            headers: {'Content-Type': 'multipart/form-data; boundary=$boundary'});
      }

      final migrated = _hive.getSetting<bool>('relay_migrated') ?? false;
      try {
        await upload(!migrated);
      } catch (e) {
        final m = '$e'.toLowerCase();
        if (!migrated && m.contains('migration')) {
          await upload(false);
        } else if (migrated && m.contains('durable')) {
          await upload(true);
        } else {
          rethrow;
        }
      }
      await _hive.setSetting('relay_migrated', true);

      status.value = 'Turning on the web address…';
      String sub = '';
      try {
        final r = await _api('GET', '/accounts/$account/workers/subdomain');
        sub = '${(r['result'] as Map?)?['subdomain'] ?? ''}';
      } catch (_) {}
      if (sub.isEmpty) {
        sub = 'nm-${randomSecret(8).toLowerCase()}';
        await _api('PUT', '/accounts/$account/workers/subdomain', json: {'subdomain': sub});
      }
      await _api('POST', '/accounts/$account/workers/scripts/$workerName/subdomain',
          json: {'enabled': true});
      final address = 'https://$workerName.$sub.workers.dev';
      url.value = address;
      await _hive.setSetting('relay_url', address);
      status.value = 'Deployed';
      return address;
    } finally {
      deploying.value = false;
    }
  }

  // ── Keeping the phone connected ──────────────────────────────────────

  Future<void> start() async {
    if (_wantOn || kIsWeb) return;
    if (url.value.isEmpty) throw Exception('Deploy the relay first.');
    _wantOn = true;
    enabled.value = true;
    await _hive.setSetting('relay_on', true);
    final sc = Get.find<ServerController>();
    if (keyMode == 'local' && !sc.useApiKey.value) {
      sc.useApiKey.value = true;
    }
    if (!sc.isRunning.value) await sc.startServer();
    await _keepProcessAlive(true);
    unawaited(_loop());
  }

  Future<void> stop() async {
    _wantOn = false;
    enabled.value = false;
    await _hive.setSetting('relay_on', false);
    _ping?.cancel();
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    connected.value = false;
    status.value = 'Off';
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
          'title': 'Remote access is on',
          'content': 'Your phone is reachable at ${url.value}',
        });
      } else {
        svc.invoke('keepAlive', {'on': false});
        svc.invoke('forceStop');
      }
    } catch (_) {}
  }

  Future<void> _loop() async {
    while (_wantOn) {
      try {
        status.value = 'Connecting…';
        final u = Uri.parse(url.value);
        final ws = await WebSocket.connect('wss://${u.host}/_phone?token=${Uri.encodeQueryComponent(relayToken)}')
            .timeout(const Duration(seconds: 20));
        _ws = ws;
        _retry = 0;
        connected.value = true;
        status.value = 'Connected';
        _ping?.cancel();
        _ping = Timer.periodic(const Duration(seconds: 25), (_) {
          try {
            ws.add('ping');
          } catch (_) {}
        });
        await for (final msg in ws) {
          if (msg is String && msg != 'pong') _onFrame(ws, msg);
        }
      } catch (e) {
        status.value = 'Reconnecting… ($e)';
      }
      connected.value = false;
      _ping?.cancel();
      _reqs.clear();
      if (!_wantOn) break;
      _retry = min(_retry + 1, 6);
      await Future.delayed(Duration(seconds: 2 * _retry));
    }
  }

  void _onFrame(WebSocket ws, String raw) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = '${m['id']}';
    switch (m['t']) {
      case 'req':
        _reqs[id] = _Req('${m['method']}', '${m['path']}',
            Map<String, dynamic>.from(m['headers'] as Map? ?? {}));
      case 'body':
        _reqs[id]?.body.add(base64Decode('${m['b']}'));
      case 'go':
        final r = _reqs.remove(id);
        if (r != null) unawaited(_forward(ws, id, r));
    }
  }

  void _send(WebSocket ws, Map<String, dynamic> m) {
    try {
      ws.add(jsonEncode(m));
    } catch (_) {}
  }

  /// Replays one request against this phone's own local server.
  Future<void> _forward(WebSocket ws, String id, _Req r) async {
    final client = HttpClient();
    try {
      final sc = Get.find<ServerController>();
      final port = ServerController.port;
      final req = await client.openUrl(r.method, Uri.parse('http://127.0.0.1:$port${r.path}'));
      r.headers.forEach((k, v) {
        final key = k.toLowerCase();
        if (['host', 'content-length', 'connection', 'transfer-encoding', 'x-relay-verified'].contains(key)) return;
        req.headers.set(k, '$v');
      });
      // The Worker already vetted this request: use the phone's own key.
      final verified = '${r.headers['x-relay-verified']}' == '1';
      final key = sc.apiKey.value.trim();
      if (verified && sc.requiresApiKey && key.isNotEmpty) {
        req.headers.set('authorization', 'Bearer $key');
      }
      final body = r.body.takeBytes();
      if (body.isNotEmpty) req.add(body);
      final res = await req.close();
      final headers = <String, String>{};
      res.headers.forEach((k, v) {
        if (!['transfer-encoding', 'connection', 'content-length'].contains(k.toLowerCase())) {
          headers[k] = v.join(', ');
        }
      });
      _send(ws, {'t': 'head', 'id': id, 'status': res.statusCode, 'headers': headers});
      await for (final chunk in res) {
        for (var i = 0; i < chunk.length; i += 98304) {
          _send(ws, {
            't': 'chunk',
            'id': id,
            'b': base64Encode(chunk.sublist(i, min(i + 98304, chunk.length))),
          });
        }
      }
      _send(ws, {'t': 'end', 'id': id});
    } catch (e) {
      _send(ws, {'t': 'err', 'id': id, 'msg': 'Phone error: $e'});
    } finally {
      client.close(force: true);
    }
  }
}

class _Req {
  final String method;
  final String path;
  final Map<String, dynamic> headers;
  final BytesBuilder body = BytesBuilder(copy: false);
  _Req(this.method, this.path, this.headers);
}
