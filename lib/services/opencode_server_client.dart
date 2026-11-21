import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'android_opencode.dart';

typedef OpenCodeModel = ({String provider, String id, String name});
typedef OpenCodeSession = ({String id, String title});

/// Talks to a server started and managed independently by the user.
class OpenCodeServerClient {
  OpenCodeServerClient(String address, String user, String password)
      : endpoint = _validateEndpoint(address),
        _authorization =
            'Basic ${base64Encode(utf8.encode('$user:$password'))}' {
    if (user.isEmpty || user.contains(':') || password.isEmpty) {
      throw const FormatException('Enter the server username and password.');
    }
  }

  static const supportedVersion = '1.19.6';
  static const _limit = 8 * 1024 * 1024;
  final Uri endpoint;
  final String _authorization;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  static bool _loopback(String host) => host == '127.0.0.1' || host == '::1';
  bool get isLoopback => _loopback(endpoint.host);

  static Uri _validateEndpoint(String address) {
    final uri = Uri.tryParse(address.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' && _loopback(uri.host)))) {
      throw const FormatException(
          'Use HTTPS or a numeric loopback HTTP address.');
    }
    return uri;
  }

  Future<HttpClientResponse> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 15),
    bool authenticate = true,
  }) async {
    final prefix = endpoint.path.replaceFirst(RegExp(r'/+$'), '');
    final url = endpoint.replace(path: '$prefix$path', queryParameters: query);
    final request = await _http.openUrl(method, url).timeout(timeout);
    request.followRedirects = false;
    if (authenticate) {
      request.headers.set(HttpHeaders.authorizationHeader, _authorization);
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(timeout, onTimeout: () {
      request.abort();
      throw TimeoutException('OpenCode server did not respond.');
    });
    if (!authenticate) return response;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      unawaited(response.listen((_) {}).cancel());
      throw StateError('OpenCode server returned HTTP ${response.statusCode}.');
    }
    return response;
  }

  Future<Object?> _json(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final response = await _request(method, path,
        body: body, query: query, timeout: timeout);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > _limit) {
        throw const FormatException('The OpenCode response is too large.');
      }
      bytes.add(chunk);
    }
    return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes.takeBytes()));
  }

  Future<String> verify() async {
    final probe = await _request('GET', '/session/status', authenticate: false);
    unawaited(probe.listen((_) {}).cancel());
    if (probe.statusCode != HttpStatus.unauthorized) {
      throw StateError(
          'Enable password authentication on the OpenCode server.');
    }
    final data = await _json('GET', '/global/health');
    if (data is! Map ||
        data['healthy'] != true ||
        data['version'] != supportedVersion) {
      throw StateError('Connect to OpenCode $supportedVersion.');
    }
    return data['version'] as String;
  }

  Future<List<OpenCodeModel>> models() async {
    final data = await _json('GET', '/provider');
    if (data is! Map || data['connected'] is! List || data['all'] is! List)
      return [];
    final connected = (data['connected'] as List).whereType<String>().toSet();
    final models = <OpenCodeModel>[];
    for (final provider in (data['all'] as List).whereType<Map>()) {
      final id = provider['id'];
      final entries = provider['models'];
      if (id is! String || !connected.contains(id) || entries is! Map) continue;
      for (final model in entries.entries) {
        final info = model.value;
        if (model.key is String && info is Map) {
          models.add((
            provider: id,
            id: model.key as String,
            name: info['name'] is String
                ? info['name'] as String
                : model.key as String
          ));
        }
      }
    }
    return models;
  }

  Future<List<OpenCodeSession>> sessions() async {
    final data = await _json('GET', '/session', query: {'limit': '30'});
    if (data is! List) return [];
    final result = <OpenCodeSession>[];
    for (final item in data.whereType<Map>()) {
      final id = item['id'];
      if (id is String && _validSession(id)) {
        result.add((
          id: id,
          title: item['title'] is String ? item['title'] as String : id
        ));
      }
    }
    return result;
  }

  static bool _validSession(String id) =>
      RegExp(r'^ses_[a-zA-Z0-9_-]{1,100}$').hasMatch(id);

  String _session(String id) {
    if (!_validSession(id))
      throw const FormatException('Invalid OpenCode session.');
    return '/session/$id';
  }

  Future<String> createSession({bool allowWorkspaceReads = false}) async {
    final data = await _json('POST', '/session', body: {
      'permission': [
        {'permission': '*', 'pattern': '*', 'action': 'deny'},
        if (allowWorkspaceReads)
          {'permission': 'read', 'pattern': '*', 'action': 'allow'},
      ],
    });
    final id = data is Map ? data['id'] : null;
    if (id is! String || !_validSession(id)) {
      throw const FormatException(
          'The OpenCode server did not create a session.');
    }
    return id;
  }

  Future<List<OpenCodeMessage>> history(String id) async {
    final data =
        await _json('GET', '${_session(id)}/message', query: {'limit': '100'});
    return OpenCodeLocalProfile.messagesFrom(data);
  }

  Future<void> send(
    String id,
    OpenCodeModel model,
    String prompt, {
    required void Function(String) onText,
    required void Function(String) onTool,
  }) async {
    final path = _session(id);
    final response = await _request('GET', '/event');
    final ready = Completer<void>();
    final textParts = <String, StringBuffer>{};
    final toolStatuses = <String, String>{};
    void tool(Map part) {
      final state = part['state'];
      final partId = part['id'];
      if (part['type'] != 'tool' ||
          part['tool'] is! String ||
          state is! Map ||
          partId is! String) return;
      final status = '${part['tool']} · ${state['status'] ?? ''}';
      if (toolStatuses[partId] == status) return;
      toolStatuses[partId] = status;
      onTool(status);
    }

    final events =
        response.transform(utf8.decoder).transform(const LineSplitter());
    final subscription = events.listen((line) {
      if (!line.startsWith('data:')) return;
      final event = OpenCodeLocalProfile.parseEvent(line.substring(5).trim());
      if (event?['type'] == 'server.connected' && !ready.isCompleted)
        ready.complete();
      final properties = event?['properties'];
      if (properties is! Map) return;
      final part = properties['part'];
      if (event?['type'] == 'message.part.updated' &&
          part is Map &&
          part['sessionID'] == id) {
        if (part['type'] == 'text' && part['id'] is String) {
          textParts.putIfAbsent(part['id'] as String, StringBuffer.new);
        }
        tool(part);
      }
      final partId = properties['partID'];
      if (event?['type'] == 'message.part.delta' &&
          properties['sessionID'] == id &&
          partId is String &&
          properties['field'] == 'text' &&
          properties['delta'] is String) {
        final stream = textParts[partId];
        if (stream == null) return;
        final delta = properties['delta'] as String;
        stream.write(delta);
        onText(delta);
      }
    }, onError: (Object error) {
      if (!ready.isCompleted) ready.completeError(error);
    }, onDone: () {
      if (!ready.isCompleted)
        ready.completeError(StateError('OpenCode event stream closed.'));
    });
    try {
      await ready.future.timeout(const Duration(seconds: 10));
      final data = await _json('POST', '$path/message',
          timeout: const Duration(minutes: 5),
          body: {
            'model': {'providerID': model.provider, 'modelID': model.id},
            'parts': [
              {'type': 'text', 'text': prompt}
            ],
          });
      final info = data is Map ? data['info'] : null;
      if (info is! Map || info['error'] != null) {
        throw StateError(
            'OpenCode could not complete the turn. Check the server and model.');
      }
      // The message response and SSE use separate sockets. Reconcile the
      // completed text in case the response arrives before the last event.
      await subscription.cancel();
      final parts = (data as Map)['parts'];
      if (parts is List) {
        for (final part in parts.whereType<Map>()) {
          final text = part['text'];
          if (part['type'] == 'text' && text is String) {
            final streamed = textParts[part['id']]?.toString() ?? '';
            if (text.startsWith(streamed) && text.length > streamed.length) {
              onText(text.substring(streamed.length));
            }
          }
          tool(part);
        }
      }
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> abort(String id) async => _json('POST', '${_session(id)}/abort');
  void close() => _http.close(force: true);
}
