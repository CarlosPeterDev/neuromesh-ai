import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'hive_service.dart';

class McpOAuthException implements Exception {
  final String message;
  McpOAuthException(this.message);
  @override
  String toString() => message;
}

/// Browser sign-in (OAuth 2.1 + PKCE) for remote MCP servers, so no token has
/// to be pasted. Follows the MCP authorization spec: discovery through
/// /.well-known metadata, dynamic client registration, authorization code with
/// PKCE, and refresh tokens. Tokens are stored in platform secure storage.
class McpOAuth {
  McpOAuth._();

  static const _ua = 'NeuroMeshAI';

  static String _key(String serverUrl) {
    final u = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return 'mcp_oauth_${base64Url.encode(utf8.encode(u))}';
  }

  static HiveService? get _hive =>
      Get.isRegistered<HiveService>() ? Get.find<HiveService>() : null;

  static const _storage = FlutterSecureStorage();
  static Future<void>? _migration;

  static Future<void> _migrateLegacyTokens() async {
    final hive = _hive;
    if (hive == null) return;
    final box = hive.settingsBox;
    final keys = box.keys.whereType<String>()
        .where((key) => key.startsWith('mcp_oauth_')).toList();
    if (keys.isEmpty) return;
    for (final key in keys) {
      final old = box.get(key);
      if (old is String && old.isNotEmpty) {
        final existing = await _storage.read(key: key);
        if (existing == null) await _storage.write(key: key, value: old);
      }
      await box.delete(key);
    }
    await box.compact();
  }

  static Future<void> prepareSecureStorage() async {
    final migration = _migration ??= _migrateLegacyTokens();
    try {
      await migration;
    } catch (_) {
      if (identical(_migration, migration)) _migration = null;
      rethrow;
    }
  }

  static Future<Map<String, dynamic>?> _load(String serverUrl) async {
    try {
      await prepareSecureStorage();
      final raw = await _storage.read(key: _key(serverUrl));
      if (raw == null || raw.isEmpty) return null;
      final m = jsonDecode(raw);
      return m is Map ? Map<String, dynamic>.from(m) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _save(String serverUrl, Map<String, dynamic> rec) async {
    try {
      await prepareSecureStorage();
      await _storage.write(key: _key(serverUrl), value: jsonEncode(rec));
    } catch (_) {
      throw McpOAuthException('Secure storage is unavailable. Sign-in was not saved.');
    }
  }

  static Future<bool> hasTokens(String serverUrl) async {
    final record = await _load(serverUrl);
    return record != null &&
        (record['access'] != null && record['access'] != '' ||
         record['refresh'] != null && record['refresh'] != '');
  }

  static Future<void> signOut(String serverUrl) async {
    final inflight = _inflight[_key(serverUrl)];
    if (inflight != null) await inflight;
    await prepareSecureStorage();
    await _storage.delete(key: _key(serverUrl));
  }

  /// A valid access token for the server, refreshing it when it is about to
  /// expire. Returns null when the user has not signed in (or refresh failed).
  static Future<String?> accessToken(String serverUrl) async {
    final rec = await _load(serverUrl);
    if (rec == null) return null;
    final access = '${rec['access'] ?? ''}';
    final exp = (rec['expiresAt'] as num?)?.toInt() ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (access.isNotEmpty && (exp == 0 || exp - now > 60000)) return access;
    return refresh(serverUrl);
  }

  /// Gets a new access token with the stored refresh token.
  static final _inflight = <String, Future<String?>>{};

  /// One refresh at a time per server: servers that rotate refresh tokens
  /// reject a second parallel use of the same token.
  static Future<String?> refresh(String serverUrl) {
    final key = _key(serverUrl);
    return _inflight.putIfAbsent(
      key, () => _refresh(serverUrl).whenComplete(() => _inflight.remove(key)));
  }

  static Future<String?> _refresh(String serverUrl) async {
    final rec = await _load(serverUrl);
    if (rec == null) return null;
    final rt = '${rec['refresh'] ?? ''}';
    final te = '${rec['tokenEndpoint'] ?? ''}';
    final cid = '${rec['clientId'] ?? ''}';
    if (rt.isEmpty || te.isEmpty || cid.isEmpty) return null;
    try {
      final res = await http.post(Uri.parse(te), headers: {
        'Accept': 'application/json',
        'User-Agent': _ua,
      }, body: {
        'grant_type': 'refresh_token',
        'refresh_token': rt,
        'client_id': cid,
        if ('${rec['clientSecret'] ?? ''}'.isNotEmpty) 'client_secret': '${rec['clientSecret']}',
      }).timeout(const Duration(seconds: 20));
      if (res.statusCode == 400 || res.statusCode == 401) {
        // The refresh token is no longer valid: forget it so the app shows
        // "sign in again" instead of retrying forever.
        rec['refresh'] = '';
        rec['access'] = '';
        await _save(serverUrl, rec);
        return null;
      }
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final access = '${j['access_token'] ?? ''}';
      if (access.isEmpty) return null;
      rec['access'] = access;
      if ('${j['refresh_token'] ?? ''}'.isNotEmpty) rec['refresh'] = '${j['refresh_token']}';
      final ttl = (j['expires_in'] as num?)?.toInt();
      rec['expiresAt'] = ttl == null ? 0 : DateTime.now().millisecondsSinceEpoch + ttl * 1000;
      await _save(serverUrl, rec);
      return access;
    } catch (_) {
      return null;
    }
  }

  // ── discovery ────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> _getJson(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'Accept': 'application/json', 'User-Agent': _ua})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  /// The protected-resource metadata, from the server's 401 header or the
  /// standard well-known locations.
  static Future<Map<String, dynamic>?> _resourceMetadata(Uri server) async {
    final candidates = <String>[];
    try {
      final res = await http
          .post(server,
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json, text/event-stream',
                'User-Agent': _ua,
              },
              body: jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'method': 'initialize',
                'params': {
                  'protocolVersion': '2025-06-18',
                  'capabilities': <String, dynamic>{},
                  'clientInfo': {'name': 'NeuroMeshAI', 'version': '1.0'},
                },
              }))
          .timeout(const Duration(seconds: 15));
      final h = res.headers['www-authenticate'] ?? '';
      final m = RegExp(r'resource_metadata="?([^",\s]+)"?').firstMatch(h);
      if (m != null) candidates.add(m.group(1)!);
    } catch (_) {}
    final origin = '${server.scheme}://${server.authority}';
    final path = server.path == '/' ? '' : server.path;
    candidates
      ..add('$origin/.well-known/oauth-protected-resource$path')
      ..add('$origin/.well-known/oauth-protected-resource');
    for (final c in candidates) {
      final j = await _getJson(c);
      if (j != null) return j;
    }
    return null;
  }

  static Future<Map<String, dynamic>> _authServerMetadata(Uri issuer) async {
    final origin = '${issuer.scheme}://${issuer.authority}';
    final path = issuer.path == '/' ? '' : issuer.path;
    final tries = <String>[
      '$origin/.well-known/oauth-authorization-server$path',
      '$origin/.well-known/oauth-authorization-server',
      '$origin/.well-known/openid-configuration$path',
      '$origin/.well-known/openid-configuration',
    ];
    for (final t in tries) {
      final j = await _getJson(t);
      if (j != null && j['authorization_endpoint'] != null && j['token_endpoint'] != null) return j;
    }
    // Spec fallback for servers without metadata.
    return {
      'authorization_endpoint': '$origin/authorize',
      'token_endpoint': '$origin/token',
      'registration_endpoint': '$origin/register',
    };
  }

  // ── sign-in ──────────────────────────────────────────────────────────

  static String _random(int n) {
    const c = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => c[r.nextInt(c.length)]).join();
  }

  /// Opens the browser for the user to sign in, waits for the redirect on a
  /// loopback port and stores the tokens. Throws [McpOAuthException] with a
  /// readable message when something goes wrong.
  static Future<void> signIn(String serverUrl, {void Function(String)? onStatus}) async {
    final server = Uri.tryParse(serverUrl.trim());
    if (server == null || !(server.scheme == 'https' || server.scheme == 'http') || server.host.isEmpty) {
      throw McpOAuthException('Enter the full server URL first (https://…).');
    }
    onStatus?.call('Looking up how this server signs you in…');
    final resource = await _resourceMetadata(server);
    var issuer = Uri.parse('${server.scheme}://${server.authority}');
    final servers = resource?['authorization_servers'];
    if (servers is List && servers.isNotEmpty) {
      issuer = Uri.tryParse('${servers.first}') ?? issuer;
    }
    final meta = await _authServerMetadata(issuer);
    final authEndpoint = '${meta['authorization_endpoint']}';
    final tokenEndpoint = '${meta['token_endpoint']}';
    final regEndpoint = '${meta['registration_endpoint'] ?? ''}';
    bool safe(String u) {
      final x = Uri.tryParse(u);
      return x != null && (x.scheme == 'https' || (x.scheme == 'http' && (x.host == 'localhost' || x.host == '127.0.0.1')));
    }

    if (!safe(authEndpoint) || !safe(tokenEndpoint) || (regEndpoint.isNotEmpty && !safe(regEndpoint))) {
      throw McpOAuthException('This server uses an insecure sign-in address (not https), so sign-in was stopped.');
    }
    if (regEndpoint.isEmpty) {
      throw McpOAuthException(
          'This server does not allow automatic sign-in. Use a token or header instead.');
    }

    HttpServer? listener;
    try {
      listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (_) {
      throw McpOAuthException('Could not open a local port to finish the sign-in.');
    }
    final redirect = 'http://127.0.0.1:${listener.port}/callback';
    try {
      onStatus?.call('Registering this app…');
      http.Response reg;
      try {
        reg = await http
            .post(Uri.parse(regEndpoint),
                headers: {'Content-Type': 'application/json', 'Accept': 'application/json', 'User-Agent': _ua},
                body: jsonEncode({
                  'client_name': 'NeuroMesh AI',
                  'redirect_uris': [redirect],
                  'grant_types': ['authorization_code', 'refresh_token'],
                  'response_types': ['code'],
                  'token_endpoint_auth_method': 'none',
                }))
            .timeout(const Duration(seconds: 20));
      } catch (_) {
        throw McpOAuthException('Could not reach the server to register this app.');
      }
      if (reg.statusCode != 200 && reg.statusCode != 201) {
        throw McpOAuthException(
            'The server refused to register this app (HTTP ${reg.statusCode}). Use a token or header instead.');
      }
      final regJson = jsonDecode(reg.body) as Map<String, dynamic>;
      final clientId = '${regJson['client_id'] ?? ''}';
      final clientSecret = '${regJson['client_secret'] ?? ''}';
      if (clientId.isEmpty) throw McpOAuthException('The server did not return a client id.');

      final verifier = _random(64);
      final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
      final state = _random(24);
      final scopes = resource?['scopes_supported'];
      final authUri = Uri.parse(authEndpoint).replace(queryParameters: {
        ...Uri.parse(authEndpoint).queryParameters,
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirect,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'resource': serverUrl.trim(),
        if (scopes is List && scopes.isNotEmpty) 'scope': scopes.join(' '),
      });

      onStatus?.call('Waiting for you to sign in in the browser…');
      final codeFuture = _awaitCode(listener, state);
      codeFuture.ignore(); // errors are reported where it is awaited below
      final opened = await launchUrl(authUri, mode: LaunchMode.externalApplication);
      if (!opened) throw McpOAuthException('Could not open the browser.');
      final code = await codeFuture.timeout(const Duration(minutes: 5),
          onTimeout: () => throw McpOAuthException('Sign-in timed out. Try again.'));

      onStatus?.call('Finishing sign-in…');
      http.Response tok;
      try {
        tok = await http.post(Uri.parse(tokenEndpoint), headers: {
          'Accept': 'application/json',
          'User-Agent': _ua,
        }, body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirect,
          'client_id': clientId,
          'code_verifier': verifier,
          'resource': serverUrl.trim(),
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        }).timeout(const Duration(seconds: 20));
      } catch (_) {
        throw McpOAuthException('Could not reach the server to finish sign-in.');
      }
      if (tok.statusCode != 200) {
        var why = '';
        try {
          final e = jsonDecode(tok.body) as Map<String, dynamic>;
          why = ': ${e['error_description'] ?? e['error'] ?? ''}';
        } catch (_) {}
        throw McpOAuthException('Sign-in was rejected (HTTP ${tok.statusCode})$why');
      }
      final tj = jsonDecode(tok.body) as Map<String, dynamic>;
      final access = '${tj['access_token'] ?? ''}';
      if (access.isEmpty) throw McpOAuthException('The server sent no access token.');
      final ttl = (tj['expires_in'] as num?)?.toInt();
      await _save(serverUrl, {
        'access': access,
        'refresh': '${tj['refresh_token'] ?? ''}',
        'expiresAt': ttl == null ? 0 : DateTime.now().millisecondsSinceEpoch + ttl * 1000,
        'tokenEndpoint': tokenEndpoint,
        'clientId': clientId,
        'clientSecret': clientSecret,
      });
    } finally {
      await listener.close(force: true);
    }
  }

  /// Waits for the browser to be sent back to the loopback address and
  /// returns the authorization code.
  static Future<String> _awaitCode(HttpServer listener, String state) async {
    await for (final req in listener) {
      if (req.uri.path != '/callback') {
        req.response.statusCode = 404;
        await req.response.close();
        continue;
      }
      final q = req.uri.queryParameters;
      if (q['state'] != state) {
        // Not our redirect (another app or page poked the port): ignore it.
        req.response.statusCode = 400;
        await req.response.close();
        continue;
      }
      final error = q['error'];
      final good = error == null && q['state'] == state && (q['code'] ?? '').isNotEmpty;
      req.response.headers.contentType = ContentType.html;
      req.response.write(good
          ? '<html><body style="font-family:sans-serif;text-align:center;margin-top:20vh"><h2>Signed in</h2><p>You can go back to NeuroMesh AI now.</p></body></html>'
          : '<html><body style="font-family:sans-serif;text-align:center;margin-top:20vh"><h2>Sign-in failed</h2><p>Go back to NeuroMesh AI and try again.</p></body></html>');
      await req.response.close();
      if (error != null) {
        throw McpOAuthException('Sign-in was cancelled: ${q['error_description'] ?? error}');
      }
      final code = q['code'];
      if (code == null || code.isEmpty) throw McpOAuthException('The server sent no sign-in code. Try again.');
      return code;
    }
    throw McpOAuthException('Sign-in was interrupted.');
  }
}
