import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'mcp_oauth.dart';

class McpException implements Exception {
  final String message;
  McpException(this.message);
  @override
  String toString() => message;
}

/// A remote MCP server the user linked by URL (Streamable HTTP transport).
class McpServerConfig {
  final String id;
  final String name;
  final String url;
  final String token;
  final bool enabled;

  /// Extra HTTP headers (for servers that don't use a Bearer token).
  final Map<String, String> headers;

  /// Tool names the user switched off for this server.
  final Set<String> disabledTools;

  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.token = '',
    this.enabled = true,
    this.headers = const {},
    this.disabledTools = const {},
  });

  McpServerConfig copyWith({
    String? name,
    String? url,
    String? token,
    bool? enabled,
    Map<String, String>? headers,
    Set<String>? disabledTools,
  }) =>
      McpServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        token: token ?? this.token,
        enabled: enabled ?? this.enabled,
        headers: headers ?? this.headers,
        disabledTools: disabledTools ?? this.disabledTools,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'url': url,
        'token': token,
        'enabled': enabled,
        'headers': headers,
        'disabledTools': disabledTools.toList(),
      };

  factory McpServerConfig.fromMap(Map<String, dynamic> m) {
    final h = m['headers'];
    final d = m['disabledTools'];
    return McpServerConfig(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      url: (m['url'] ?? '').toString(),
      token: (m['token'] ?? '').toString(),
      enabled: m['enabled'] != false,
      headers: h is Map
          ? {for (final e in h.entries) e.key.toString(): e.value.toString()}
          : const {},
      disabledTools: d is List ? d.map((e) => e.toString()).toSet() : const {},
    );
  }

  /// Short identifier safe to use inside tool names.
  static String slug(String name) {
    final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final t = s.replaceAll(RegExp(r'^_+|_+$'), '');
    return t.isEmpty ? 'server' : t;
  }
}

class McpTool {
  final String serverId;
  final String serverName;
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpTool({
    required this.serverId,
    required this.serverName,
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  String get qualifiedName => '${McpServerConfig.slug(serverName)}__$name';

  /// Compact argument list for the model, e.g. {"repo":"string (required)"}.
  String get signature {
    final props = inputSchema['properties'];
    if (props is! Map || props.isEmpty) return '{}';
    final req = (inputSchema['required'] is List)
        ? (inputSchema['required'] as List).map((e) => e.toString()).toSet()
        : <String>{};
    final parts = <String>[];
    for (final e in props.entries) {
      final v = e.value;
      var type = 'any';
      var desc = '';
      if (v is Map) {
        final t = v['type'];
        type = t is List ? t.join('|') : (t ?? 'any').toString();
        if (v['enum'] is List) type = (v['enum'] as List).take(8).join('|');
        desc = (v['description'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ');
        if (desc.length > 80) desc = '${desc.substring(0, 80)}…';
      }
      parts.add('"${e.key}":"$type${req.contains(e.key) ? ' REQUIRED' : ''}${desc.isEmpty ? '' : ' - $desc'}"');
    }
    final out = '{${parts.join(',')}}';
    return out.length > 700 ? '${out.substring(0, 700)}…}' : out;
  }
}

/// Thrown for HTTP-level failures so callers can react to the status code.
class McpHttpException extends McpException {
  final int status;
  McpHttpException(this.status, super.message);
}

/// MCP client that works with both transports in use today:
///  * Streamable HTTP (current standard: POST, answer as JSON or an SSE body)
///  * legacy HTTP+SSE (GET a stream, then POST to the endpoint it announces)
/// The transport is detected automatically. Custom headers and Bearer tokens
/// are supported, and so is browser sign-in (OAuth) through [McpOAuth].
class McpClient {
  McpClient(this.config, {http.Client? client}) : _client = client ?? http.Client();

  final McpServerConfig config;
  final http.Client _client;
  String? _sessionId;
  String _protocol = '2025-06-18';
  int _nextId = 1;
  bool _initialized = false;

  // Legacy SSE state.
  bool _legacy = false;
  Uri? _endpoint;
  StreamSubscription<String>? _sseSub;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  static const _timeout = Duration(seconds: 30);

  /// Access token from the browser sign-in (OAuth), when the user signed in.
  String? _oauthToken;

  Future<void> _refreshOAuth() async {
    if (config.token.isNotEmpty) return;
    try {
      _oauthToken = await McpOAuth.accessToken(config.url);
    } catch (_) {
      _oauthToken = null;
    }
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'MCP-Protocol-Version': _protocol,
        ...config.headers,
        if (config.token.isNotEmpty && !config.headers.keys.any((k) => k.toLowerCase() == 'authorization'))
          'Authorization': 'Bearer ${config.token}'
        else if (_oauthToken != null && !config.headers.keys.any((k) => k.toLowerCase() == 'authorization'))
          'Authorization': 'Bearer $_oauthToken',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      };

  Future<void> initialize() async {
    if (_initialized) return;
    await _refreshOAuth();
    Map<String, dynamic> result;
    try {
      result = await _rpc('initialize', _initParams());
    } on McpHttpException catch (e) {
      // Older servers answer a POST to the SSE URL with 404/405/400.
      if (!const {400, 404, 405, 406}.contains(e.status)) rethrow;
      await _openLegacy();
      result = await _rpc('initialize', _initParams());
    }
    final v = result['protocolVersion'];
    if (v is String && v.isNotEmpty) _protocol = v;
    await _notify('notifications/initialized');
    _initialized = true;
  }

  Map<String, dynamic> _initParams() => {
        'protocolVersion': _protocol,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'NeuroMeshAI', 'version': '1.0'},
      };

  Future<List<McpTool>> listTools() async {
    await initialize();
    final tools = <McpTool>[];
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final result = await _rpc('tools/list', {if (cursor != null) 'cursor': cursor});
      final list = result['tools'];
      if (list is List) {
        for (final t in list.whereType<Map>()) {
          final schema = t['inputSchema'];
          tools.add(McpTool(
            serverId: config.id,
            serverName: config.name,
            name: (t['name'] ?? '').toString(),
            description: (t['description'] ?? t['title'] ?? '').toString(),
            inputSchema: schema is Map
                ? Map<String, dynamic>.from(schema)
                : <String, dynamic>{},
          ));
        }
      }
      cursor = result['nextCursor']?.toString();
      if (cursor == null || cursor.isEmpty) break;
    }
    return tools.where((t) => t.name.isNotEmpty).toList();
  }

  /// Runs a tool and returns its text output.
  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    await initialize();
    final result = await _rpc('tools/call', {'name': name, 'arguments': arguments},
        timeout: const Duration(seconds: 120));
    final text = StringBuffer();
    void add(String s) {
      if (text.isNotEmpty) text.write('\n');
      text.write(s);
    }

    final content = result['content'];
    if (content is List) {
      for (final c in content.whereType<Map>()) {
        switch (c['type']) {
          case 'text':
            add('${c['text']}');
          case 'resource':
            final r = c['resource'];
            if (r is Map && r['text'] != null) {
              add('${r['text']}');
            } else {
              add('[resource ${r is Map ? r['uri'] : ''}]');
            }
          case 'resource_link':
            add('[link ${c['uri']}]');
          default:
            add('[${c['type']} content not shown]');
        }
      }
    }
    if (text.isEmpty && result['structuredContent'] != null) {
      add(jsonEncode(result['structuredContent']));
    }
    final out = text.toString().trim();
    if (result['isError'] == true) return 'Tool error: ${out.isEmpty ? 'unknown' : out}';
    return out.isEmpty ? '(no output)' : out;
  }

  // ── transport ────────────────────────────────────────────────────────

  Future<void> _notify(String method) async {
    final body = jsonEncode({'jsonrpc': '2.0', 'method': method});
    try {
      await _client
          .post(_legacy ? _endpoint! : Uri.parse(config.url), headers: _headers, body: body)
          .timeout(_timeout);
    } catch (_) {
      // Notifications have no reply; a failure here is not fatal.
    }
  }

  Future<Map<String, dynamic>> _rpc(String method, Map<String, dynamic> params,
      {Duration timeout = _timeout, bool retried = false}) async {
    final id = _nextId++;
    final payload = jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    if (_legacy) return _legacyRpc(id, payload, timeout);

    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(config.url), headers: _headers, body: payload)
          .timeout(timeout);
    } on TimeoutException {
      throw McpException('${config.name} took too long to answer.');
    } catch (_) {
      throw McpException('Could not reach ${config.name}. Check the URL and your connection.');
    }
    // A stale session id: start over once.
    if (res.statusCode == 404 && _sessionId != null && !retried && method != 'initialize') {
      _sessionId = null;
      _initialized = false;
      await initialize();
      return _rpc(method, params, timeout: timeout, retried: true);
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      final oauth = (res.headers['www-authenticate'] ?? '').toLowerCase().contains('bearer') &&
          config.token.isEmpty && config.headers.isEmpty;
      throw McpHttpException(
          res.statusCode,
          oauth
              ? '${config.name} needs you to sign in (HTTP ${res.statusCode}). Tap "Sign in" on this server to log in with your browser, no token needed.'
              : '${config.name} rejected the credentials (HTTP ${res.statusCode}).');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final snippet = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
      throw McpHttpException(res.statusCode,
          '${config.name} returned HTTP ${res.statusCode}${snippet.isEmpty ? '' : ': ${snippet.length > 160 ? snippet.substring(0, 160) : snippet}'}');
    }
    final sid = res.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;

    final body = utf8.decode(res.bodyBytes);
    final type = res.headers['content-type'] ?? '';
    Map<String, dynamic>? message;
    if (type.contains('text/event-stream')) {
      message = _fromSse(body, id);
    } else if (body.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          message = decoded;
        } else if (decoded is List) {
          for (final m in decoded.whereType<Map<String, dynamic>>()) {
            if (m['id'] == id) message = m;
          }
        }
      } catch (_) {
        throw McpException('${config.name} did not answer with MCP data. Is the URL an MCP endpoint?');
      }
    }
    if (message == null) throw McpException('${config.name} sent no answer.');
    return _unwrap(message);
  }

  Map<String, dynamic> _unwrap(Map<String, dynamic> message) {
    final err = message['error'];
    if (err is Map) throw McpException((err['message'] ?? 'Server error').toString());
    final result = message['result'];
    return result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
  }

  static Map<String, dynamic>? _fromSse(String body, int id) {
    for (final block in body.split(RegExp(r'\r?\n\r?\n'))) {
      final data = block
          .split(RegExp(r'\r?\n'))
          .where((l) => l.startsWith('data:'))
          .map((l) => l.substring(5).trim())
          .join('\n');
      if (data.isEmpty) continue;
      try {
        final m = jsonDecode(data);
        if (m is Map<String, dynamic> && m['id'] == id) return m;
      } catch (_) {}
    }
    return null;
  }

  // ── legacy HTTP+SSE ──────────────────────────────────────────────────

  Future<void> _openLegacy() async {
    final req = http.Request('GET', Uri.parse(config.url))
      ..headers.addAll({
        'Accept': 'text/event-stream',
        ...config.headers,
        if (config.token.isNotEmpty && !config.headers.keys.any((k) => k.toLowerCase() == 'authorization'))
          'Authorization': 'Bearer ${config.token}'
        else if (_oauthToken != null)
          'Authorization': 'Bearer $_oauthToken',
      });
    final http.StreamedResponse res;
    try {
      res = await _client.send(req).timeout(_timeout);
    } catch (_) {
      throw McpException('Could not reach ${config.name}. Check the URL and your connection.');
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw McpHttpException(res.statusCode, '${config.name} rejected the credentials (HTTP ${res.statusCode}).');
    }
    if (res.statusCode != 200) {
      throw McpException('${config.name} is not an MCP server at this URL (HTTP ${res.statusCode}).');
    }
    final ready = Completer<void>();
    var event = 'message';
    final data = StringBuffer();
    _sseSub = utf8.decoder.bind(res.stream).transform(const LineSplitter()).listen((line) {
      if (line.isEmpty) {
        final payload = data.toString();
        final ev = event;
        data.clear();
        event = 'message';
        if (payload.isEmpty) return;
        if (ev == 'endpoint') {
          _endpoint = Uri.parse(config.url).resolve(payload.trim());
          if (!ready.isCompleted) ready.complete();
        } else {
          try {
            final m = jsonDecode(payload);
            if (m is Map<String, dynamic> && m['id'] is int) {
              _pending.remove(m['id'])?.complete(m);
            }
          } catch (_) {}
        }
      } else if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }, onError: (_) {
      for (final c in _pending.values) {
        if (!c.isCompleted) c.completeError(McpException('Connection to ${config.name} dropped.'));
      }
      _pending.clear();
    });
    _legacy = true;
    try {
      await ready.future.timeout(_timeout);
    } on TimeoutException {
      throw McpException('${config.name} never announced a message endpoint.');
    }
  }

  Future<Map<String, dynamic>> _legacyRpc(int id, String payload, Duration timeout) async {
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    try {
      final res = await _client.post(_endpoint!, headers: _headers, body: payload).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _pending.remove(id);
        throw McpHttpException(res.statusCode, '${config.name} returned HTTP ${res.statusCode}.');
      }
      // Some servers answer in the POST body instead of the stream.
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.startsWith('{')) {
        try {
          final m = jsonDecode(body);
          if (m is Map<String, dynamic> && m['id'] == id) {
            _pending.remove(id);
            return _unwrap(m);
          }
        } catch (_) {}
      }
      return _unwrap(await c.future.timeout(timeout));
    } on TimeoutException {
      _pending.remove(id);
      throw McpException('${config.name} took too long to answer.');
    }
  }

  void dispose() {
    _sseSub?.cancel();
    _client.close();
  }
}
