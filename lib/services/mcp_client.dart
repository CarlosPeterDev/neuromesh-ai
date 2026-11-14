import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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

  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.token = '',
    this.enabled = true,
  });

  McpServerConfig copyWith({String? name, String? url, String? token, bool? enabled}) =>
      McpServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        token: token ?? this.token,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toMap() =>
      {'id': id, 'name': name, 'url': url, 'token': token, 'enabled': enabled};

  factory McpServerConfig.fromMap(Map<String, dynamic> m) => McpServerConfig(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        url: (m['url'] ?? '').toString(),
        token: (m['token'] ?? '').toString(),
        enabled: m['enabled'] != false,
      );

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
}

/// Minimal MCP client: initialize, tools/list and tools/call over HTTP.
class McpClient {
  McpClient(this.config, {http.Client? client}) : _client = client ?? http.Client();

  final McpServerConfig config;
  final http.Client _client;
  String? _sessionId;
  int _nextId = 1;
  bool _initialized = false;

  static const _protocolVersion = '2025-03-26';
  static const _timeout = Duration(seconds: 30);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        if (config.token.isNotEmpty) 'Authorization': 'Bearer ${config.token}',
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      };

  Future<void> initialize() async {
    if (_initialized) return;
    await _rpc('initialize', {
      'protocolVersion': _protocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'NeuroMeshAI', 'version': '1.0'},
    });
    try {
      await _client
          .post(Uri.parse(config.url),
              headers: _headers,
              body: jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}))
          .timeout(_timeout);
    } catch (_) {
      // The notification has no reply; a failure here is not fatal.
    }
    _initialized = true;
  }

  Future<List<McpTool>> listTools() async {
    await initialize();
    final tools = <McpTool>[];
    String? cursor;
    for (var page = 0; page < 5; page++) {
      final result = await _rpc('tools/list', {if (cursor != null) 'cursor': cursor});
      final list = result['tools'];
      if (list is List) {
        for (final t in list.whereType<Map>()) {
          final schema = t['inputSchema'];
          tools.add(McpTool(
            serverId: config.id,
            serverName: config.name,
            name: (t['name'] ?? '').toString(),
            description: (t['description'] ?? '').toString(),
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
    final result = await _rpc('tools/call', {'name': name, 'arguments': arguments});
    final content = result['content'];
    final text = StringBuffer();
    if (content is List) {
      for (final c in content.whereType<Map>()) {
        if (c['type'] == 'text') {
          if (text.isNotEmpty) text.write('\n');
          text.write(c['text']);
        } else {
          text.write('\n[${c['type']} content not shown]');
        }
      }
    }
    final out = text.toString().trim();
    if (result['isError'] == true) return 'Tool error: ${out.isEmpty ? 'unknown' : out}';
    return out.isEmpty ? '(no output)' : out;
  }

  Future<Map<String, dynamic>> _rpc(String method, Map<String, dynamic> params) async {
    final id = _nextId++;
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(config.url),
              headers: _headers,
              body: jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}))
          .timeout(_timeout);
    } on TimeoutException {
      throw McpException('${config.name} took too long to answer.');
    } catch (_) {
      throw McpException('Could not reach ${config.name}. Check the URL and your connection.');
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw McpException('${config.name} rejected the token (HTTP ${res.statusCode}).');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw McpException('${config.name} returned HTTP ${res.statusCode}.');
    }
    final sid = res.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;

    final body = utf8.decode(res.bodyBytes);
    final type = res.headers['content-type'] ?? '';
    Map<String, dynamic>? message;
    if (type.contains('text/event-stream')) {
      message = _fromSse(body, id);
    } else {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        message = decoded;
      } else if (decoded is List) {
        for (final m in decoded.whereType<Map<String, dynamic>>()) {
          if (m['id'] == id) message = m;
        }
      }
    }
    if (message == null) throw McpException('${config.name} sent no answer.');
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

  void dispose() => _client.close();
}
