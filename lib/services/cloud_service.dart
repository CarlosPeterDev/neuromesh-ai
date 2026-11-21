import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'hive_service.dart';
import 'tool_registry.dart';
import 'app_log_service.dart';

/// Cloud API service supporting native and OpenAI-compatible providers.
class CloudService extends GetxService {
  CloudService({http.Client Function()? agentClientFactory})
      : _agentClientFactory = agentClientFactory ?? http.Client.new;
  final http.Client Function() _agentClientFactory;
  final HiveService _hive = Get.find<HiveService>();

  String get _provider =>
      _hive.getSetting(AppConstants.keyCloudProvider,
          defaultValue: 'openrouter') ??
      'openrouter';

  String get _apiKey {
    switch (_provider) {
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicKey) ?? '';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleKey) ?? '';
      case 'kimi':
        return _hive.getSetting(AppConstants.keyKimiKey) ?? '';
      case 'stability':
        return _hive.getSetting(AppConstants.keyStabilityKey) ?? '';
      case 'nvidia':
        return _hive.getSetting(AppConstants.keyNvidiaKey) ?? '';
      case 'openrouter':
        return _hive.getSetting(AppConstants.keyOpenRouterKey) ?? '';
      case 'deepseek':
        return _hive.getSetting(AppConstants.keyDeepSeekKey) ?? '';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudKey) ?? '';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiKey) ?? '';
    }
  }

  String get _model {
    switch (_provider) {
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicModel) ??
            'claude-sonnet-4-6';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleModel) ??
            'gemini-2.5-flash';
      case 'kimi':
        return _hive.getSetting(AppConstants.keyKimiModel) ?? 'kimi-k2.6';
      case 'stability':
        return _hive.getSetting(AppConstants.keyStabilityModel) ??
            'sd3.5-flash';
      case 'nvidia':
        return _hive.getSetting(AppConstants.keyNvidiaModel) ??
            'meta/llama-3.1-8b-instruct';
      case 'openrouter':
        return _hive.getSetting(AppConstants.keyOpenRouterModel) ??
            'openai/gpt-4o-mini';
      case 'deepseek':
        return _hive.getSetting(AppConstants.keyDeepSeekModel) ??
            'deepseek-v4-flash';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudModel) ?? '';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiModel) ?? 'gpt-5.2';
    }
  }

  bool get isConfigured {
    if (_provider == 'custom') {
      final baseUrl =
          _hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '';
      return _apiKey.isNotEmpty && _model.isNotEmpty && baseUrl.isNotEmpty;
    }
    return _apiKey.isNotEmpty;
  }

  http.Client? _activeStreamClient;
  final _googleToolParts = <String, Map<String, dynamic>>{};
  int _nativeCallSerial = 0;

  // Without timeouts a stalled connection (captive Wi-Fi, a hung custom
  // endpoint) leaves the chat loading forever.
  static const _connectTimeout = Duration(seconds: 30);
  static const _responseTimeout = Duration(seconds: 120);

  /// Max gap between streamed chunks. Not const so tests can shorten it.
  static Duration streamIdleTimeout = const Duration(seconds: 60);

  Future<http.Response> _post(Uri url,
          {Map<String, String>? headers, Object? body}) =>
      http.post(url, headers: headers, body: body).timeout(_responseTimeout);

  /// Aborts the streaming response in progress, if any. Closing the client
  /// drops the connection, so the provider stops generating (and billing).
  void cancel() {
    _googleToolParts.clear();
    final client = _activeStreamClient;
    _activeStreamClient = null;
    client?.close();
  }

  /// Send a message to the cloud API. Returns the response text.
  /// [messages] is a list of {role, content} maps forming the conversation.
  /// [imageBase64] is optional for multimodal requests.
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
    void Function(String token)? onToken,
  }) async {
    if (!isConfigured) {
      return 'ERROR: No API key configured for $_provider. Go to Settings.';
    }

    try {
      if (onToken != null && _supportsStreaming) {
        return await _streamOpenAICompatible(
          endpoint: _openAICompatibleEndpoint,
          providerLabel: _providerLabel,
          messages: messages,
          imageBase64: imageBase64,
          temperature: temperature,
          maxTokens: maxTokens,
          extraHeaders: _openAICompatibleExtraHeaders,
          onToken: onToken,
        );
      }

      switch (_provider) {
        case 'anthropic':
          return await _sendAnthropic(
              messages, imageBase64, temperature, maxTokens);
        case 'google':
          return await _sendGoogle(
              messages, imageBase64, temperature, maxTokens);
        case 'kimi':
          return await _sendKimi(messages, imageBase64, temperature, maxTokens);
        case 'stability':
          return 'ERROR: Image creation is available through Pollinations in Chat.';
        case 'nvidia':
          return await _sendNvidia(
              messages, imageBase64, temperature, maxTokens);
        case 'openrouter':
          return await _sendOpenRouter(
              messages, imageBase64, temperature, maxTokens);
        case 'deepseek':
          return await _sendDeepSeek(
              messages, imageBase64, temperature, maxTokens);
        case 'custom':
          return await _sendCustomOpenAICompatible(
              messages, imageBase64, temperature, maxTokens);
        default:
          return await _sendOpenAI(
              messages, imageBase64, temperature, maxTokens);
      }
    } on TimeoutException {
      Get.find<AppLogService>().warning('Cloud API request timed out');
      return "ERROR: $_providerLabel didn't respond in time. Check your "
          'connection and try again.';
    } catch (e) {
      Get.find<AppLogService>().error('Cloud API request failed', details: e);
      return 'ERROR: Cloud API request failed — $e';
    }
  }

  /// Native function calling for known OpenAI-compatible providers. Custom
  /// endpoints require explicit capability opt-in; other providers use the
  /// validated tagged-output protocol supplied by AgentService.
  bool get supportsNativeTools =>
      (_supportsStreaming ||
          _provider == 'google' ||
          _provider == 'anthropic') &&
      (_provider != 'custom' ||
          _hive.getSetting<bool>('custom_native_tools') == true);

  Future<String> sendAgentMessage({
    required List<Map<String, String>> messages,
    required List<Map<String, dynamic>> tools,
    String? imageBase64,
    void Function(String)? onToken,
  }) async {
    if (tools.isEmpty || !supportsNativeTools) {
      return sendMessage(
          messages: messages, imageBase64: imageBase64, onToken: onToken);
    }
    if (!isConfigured)
      return 'ERROR: Configure a cloud provider before using tools.';
    final native = <Map<String, dynamic>>[];
    var pending = <String>[];
    var serial = 0;
    for (final message in messages) {
      final content = message['content'] ?? '';
      if (message['role'] == 'assistant' && message['_nm_tools'] == 'true') {
        final calls = decodeModelCalls(content);
        if (calls.isNotEmpty) {
          pending = [
            for (final call in calls)
              call.id.isEmpty ? 'call_${serial++}' : call.id
          ];
          native.add({
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              for (var i = 0; i < calls.length; i++)
                {
                  'id': pending[i],
                  'type': 'function',
                  'function': {
                    'name': calls[i].name,
                    'arguments': jsonEncode(calls[i].arguments)
                  },
                }
            ]
          });
          continue;
        }
      }
      if (pending.isNotEmpty && message['role'] == 'user') {
        final decoded = jsonDecode(content);
        final results = decoded['tool_results'] as List;
        for (var i = 0; i < pending.length; i++) {
          native.add({
            'role': 'tool',
            'tool_call_id': pending[i],
            'content': jsonEncode(i < results.length
                ? results[i]
                : {'status': 'error', 'content': 'Cancelled before execution'})
          });
        }
        pending = [];
        continue;
      }
      native.add({'role': message['role'], 'content': content});
    }
    if (imageBase64 != null) {
      final lastUser = native.lastIndexWhere((m) => m['role'] == 'user');
      if (lastUser >= 0)
        native[lastUser]['content'] = [
          {'type': 'text', 'text': native[lastUser]['content']},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
          },
        ];
    }
    final client = _agentClientFactory();
    _activeStreamClient = client;
    try {
      if (_provider == 'google' || _provider == 'anthropic') {
        return await _sendNativeOther(native, tools, client, onToken);
      }
      final response = await client
          .post(
            Uri.parse(_openAICompatibleEndpoint),
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
              ..._openAICompatibleExtraHeaders
            },
            body: jsonEncode({
              'model': _model,
              'messages': native,
              'tools': tools,
              'tool_choice': 'auto',
              'stream': false
            }),
          )
          .timeout(_responseTimeout);
      if (response.statusCode != 200)
        return 'ERROR: Native tool request returned HTTP ${response.statusCode}. No further actions were executed.';
      final data = jsonDecode(response.body);
      final message = data['choices'][0]['message'] as Map;
      final calls = message['tool_calls'];
      if (calls is List && calls.isNotEmpty) {
        return encodeModelCalls(calls.map((c) {
          final args = jsonDecode(c['function']['arguments'] as String);
          if (args is! Map)
            throw const FormatException('Tool arguments must be an object');
          return ModelToolCall(
              c['function']['name'], Map<String, dynamic>.from(args),
              id: c['id'] as String? ?? 'native_${_nativeCallSerial++}');
        }).toList());
      }
      final answer = message['content'] as String? ?? '';
      onToken?.call(answer);
      return encodeModelAnswer(answer);
    } catch (e) {
      return 'ERROR: Cloud tool response failed: $e';
    } finally {
      if (identical(_activeStreamClient, client)) _activeStreamClient = null;
      client.close();
    }
  }

  Future<String> _sendNativeOther(
      List<Map<String, dynamic>> messages,
      List<Map<String, dynamic>> tools,
      http.Client client,
      void Function(String)? onToken) async {
    final system = messages
        .where((m) => m['role'] == 'system')
        .map((m) => m['content'])
        .join('\n');
    final converted = <Map<String, dynamic>>[];
    final names = <String, String>{};
    void append(String role, List<Map<String, dynamic>> parts) {
      final key = _provider == 'google' ? 'parts' : 'content';
      if (converted.isNotEmpty && converted.last['role'] == role) {
        (converted.last[key] as List).addAll(parts);
      } else {
        converted.add({'role': role, key: parts});
      }
    }

    for (final message in messages.where((m) => m['role'] != 'system')) {
      final calls = message['tool_calls'];
      if (calls is List) {
        final parts = <Map<String, dynamic>>[];
        for (final call in calls) {
          final fn = call['function'] as Map;
          final id = call['id'] as String;
          names[id] = fn['name'];
          parts.add(_provider == 'google'
              ? _googleToolParts[id] ??
                  {
                    'functionCall': {
                      'name': fn['name'],
                      'args': jsonDecode(fn['arguments'])
                    }
                  }
              : {
                  'type': 'tool_use',
                  'id': id,
                  'name': fn['name'],
                  'input': jsonDecode(fn['arguments'])
                });
        }
        append(_provider == 'google' ? 'model' : 'assistant', parts);
        continue;
      }
      if (message['role'] == 'tool') {
        final id = message['tool_call_id'] as String;
        final result = jsonDecode(message['content'] as String);
        append('user', [
          _provider == 'google'
              ? {
                  'functionResponse': {
                    'name': names[id],
                    'response': result,
                    if (_googleToolParts[id]?['functionCall']?['id'] != null)
                      'id': _googleToolParts[id]!['functionCall']['id']
                  }
                }
              : {
                  'type': 'tool_result',
                  'tool_use_id': id,
                  'content': message['content'],
                  'is_error': result['status'] == 'error'
                }
        ]);
        continue;
      }
      final content = message['content'];
      final parts = <Map<String, dynamic>>[];
      if (content is List) {
        for (final part in content) {
          if (part['type'] == 'text')
            parts.add(_provider == 'google'
                ? {'text': part['text']}
                : {'type': 'text', 'text': part['text']});
          if (part['type'] == 'image_url') {
            final uri = part['image_url']['url'] as String;
            final comma = uri.indexOf(',');
            final mime = uri.substring(5, uri.indexOf(';'));
            parts.add(_provider == 'google'
                ? {
                    'inlineData': {
                      'mimeType': mime,
                      'data': uri.substring(comma + 1)
                    }
                  }
                : {
                    'type': 'image',
                    'source': {
                      'type': 'base64',
                      'media_type': mime,
                      'data': uri.substring(comma + 1)
                    }
                  });
          }
        }
      } else {
        parts.add(_provider == 'google'
            ? {'text': content ?? ''}
            : {'type': 'text', 'text': content ?? ''});
      }
      append(
          _provider == 'google' && message['role'] == 'assistant'
              ? 'model'
              : message['role'],
          parts);
    }
    final url = _provider == 'google'
        ? Uri.parse('${AppConstants.googleEndpoint}/$_model:generateContent')
        : Uri.parse(AppConstants.anthropicEndpoint);
    final body = _provider == 'google'
        ? {
            'systemInstruction': {
              'parts': [
                {'text': system}
              ]
            },
            'contents': converted,
            'tools': [
              {
                'functionDeclarations': [
                  for (final t in tools)
                    {
                      'name': t['function']['name'],
                      'description': t['function']['description'],
                      'parametersJsonSchema': t['function']['parameters']
                    }
                ]
              }
            ],
          }
        : {
            'model': _model,
            'system': system,
            'messages': converted,
            'max_tokens': AppConstants.defaultMaxTokens,
            'tools': [
              for (final t in tools)
                {
                  'name': t['function']['name'],
                  'description': t['function']['description'],
                  'input_schema': t['function']['parameters']
                }
            ],
          };
    final response = await client
        .post(url,
            headers: {
              'Content-Type': 'application/json',
              if (_provider == 'google') 'x-goog-api-key': _apiKey,
              if (_provider == 'anthropic') ...{
                'x-api-key': _apiKey,
                'anthropic-version': '2023-06-01'
              },
            },
            body: jsonEncode(body))
        .timeout(_responseTimeout);
    if (response.statusCode != 200)
      return 'ERROR: Native $_provider tool request returned HTTP ${response.statusCode}. No further actions were executed.';
    final data = jsonDecode(response.body);
    final parts = (_provider == 'google'
        ? data['candidates'][0]['content']['parts']
        : data['content']) as List;
    final calls = <ModelToolCall>[];
    final text = StringBuffer();
    for (final part in parts) {
      if (_provider == 'google' && part['functionCall'] is Map) {
        final fn = part['functionCall'];
        final id = fn['id'] as String? ?? 'google_${_nativeCallSerial++}';
        _googleToolParts[id] = Map<String, dynamic>.from(part);
        if (_googleToolParts.length > 128)
          _googleToolParts.remove(_googleToolParts.keys.first);
        calls.add(ModelToolCall(
            fn['name'], Map<String, dynamic>.from(fn['args'] ?? {}),
            id: id));
      } else if (_provider == 'anthropic' && part['type'] == 'tool_use') {
        calls.add(ModelToolCall(
            part['name'], Map<String, dynamic>.from(part['input']),
            id: part['id']));
      } else if (part['text'] is String && part['thought'] != true) {
        text.write(part['text']);
      }
    }
    if (calls.isNotEmpty) return encodeModelCalls(calls);
    _googleToolParts.clear();
    final answer = text.toString();
    onToken?.call(answer);
    return encodeModelAnswer(answer);
  }

  bool get _supportsStreaming =>
      _provider == 'openai' ||
      _provider == 'nvidia' ||
      _provider == 'openrouter' ||
      _provider == 'deepseek' ||
      _provider == 'custom' ||
      _provider == 'kimi';

  String get _openAICompatibleEndpoint {
    switch (_provider) {
      case 'nvidia':
        return '${AppConstants.nvidiaEndpoint}/chat/completions';
      case 'openrouter':
        return '${AppConstants.openRouterEndpoint}/chat/completions';
      case 'deepseek':
        return '${AppConstants.deepSeekEndpoint}/chat/completions';
      case 'custom':
        final baseUrl =
            (_hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '')
                .toString()
                .replaceAll(RegExp(r'/+$'), '');
        return '$baseUrl/chat/completions';
      case 'kimi':
        return AppConstants.kimiEndpoint;
      default:
        return AppConstants.openaiEndpoint;
    }
  }

  String get _providerLabel {
    switch (_provider) {
      case 'nvidia':
        return 'NVIDIA NIM';
      case 'openrouter':
        return 'OpenRouter';
      case 'deepseek':
        return 'DeepSeek';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudName) ??
            'Custom API';
      case 'kimi':
        return 'Kimi';
      default:
        return 'OpenAI';
    }
  }

  Map<String, String> get _openAICompatibleExtraHeaders {
    if (_provider == 'openrouter') {
      return const {
        'HTTP-Referer': 'https://ai-chat.local',
        'X-Title': 'AI Chat',
      };
    }
    return const {};
  }

  // ─── OpenAI ─────────────────────────────────────

  Future<String> _sendOpenAI(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await _post(
      Uri.parse(AppConstants.openaiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: OpenAI returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  // ─── Anthropic ──────────────────────────────────

  Future<String> _sendAnthropic(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    // Extract system message
    String? systemMsg;
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'system') {
        systemMsg = msg['content'];
        continue;
      }

      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/jpeg',
                'data': imageBase64,
              }
            },
            {'type': 'text', 'text': msg['content']},
          ],
        });
      } else {
        apiMessages.add({
          'role': msg['role'],
          'content': msg['content'],
        });
      }
    }

    final body = <String, dynamic>{
      'model': _model,
      'messages': apiMessages,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'temperature': temperature ?? AppConstants.defaultTemperature,
    };
    if (systemMsg != null) body['system'] = systemMsg;

    final response = await _post(
      Uri.parse(AppConstants.anthropicEndpoint),
      headers: {
        'x-api-key': _apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      return 'ERROR: Anthropic returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    final content = data['content'] as List;
    return content.isNotEmpty ? content[0]['text'] ?? '' : '';
  }

  // ─── Google Gemini ──────────────────────────────

  Future<String> _sendGoogle(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final parts = <Map<String, dynamic>>[];

    // Combine all messages into parts
    for (final msg in messages) {
      parts.add({'text': '${msg['role']}: ${msg['content']}'});
    }

    // Add image if present
    if (imageBase64 != null) {
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': imageBase64,
        }
      });
    }

    // Key goes in a header, not the URL, so it can't leak via exception
    // messages (http's ClientException includes the full URI).
    final url = '${AppConstants.googleEndpoint}/$_model:generateContent';

    final response = await _post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': _apiKey,
      },
      body: jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {
          'temperature': temperature ?? AppConstants.defaultTemperature,
          'maxOutputTokens': maxTokens ?? AppConstants.defaultMaxTokens,
        },
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: Google returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    final candidates = data['candidates'] as List?;
    if (candidates != null && candidates.isNotEmpty) {
      final contentParts = candidates[0]['content']['parts'] as List;
      return contentParts.map((p) => p['text'] ?? '').join('');
    }
    return '';
  }

  // ─── Kimi (Moonshot AI — OpenAI-compatible) ─────

  Future<String> _sendKimi(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      apiMessages.add({'role': msg['role'], 'content': msg['content']});
    }

    final response = await _post(
      Uri.parse(AppConstants.kimiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: Kimi returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _sendNvidia(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await _post(
      Uri.parse('${AppConstants.nvidiaEndpoint}/chat/completions'),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: NVIDIA NIM returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _sendOpenRouter(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    return _sendOpenAICompatible(
      endpoint: '${AppConstants.openRouterEndpoint}/chat/completions',
      providerLabel: 'OpenRouter',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
      extraHeaders: const {
        'HTTP-Referer': 'https://ai-chat.local',
        'X-Title': 'AI Chat',
      },
    );
  }

  Future<String> _sendDeepSeek(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    return _sendOpenAICompatible(
      endpoint: '${AppConstants.deepSeekEndpoint}/chat/completions',
      providerLabel: 'DeepSeek',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  Future<String> _sendCustomOpenAICompatible(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final baseUrl = (_hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '')
        .toString()
        .replaceAll(RegExp(r'/+$'), '');
    return _sendOpenAICompatible(
      endpoint: '$baseUrl/chat/completions',
      providerLabel:
          _hive.getSetting(AppConstants.keyCustomCloudName) ?? 'Custom API',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  Future<String> _sendOpenAICompatible({
    required String endpoint,
    required String providerLabel,
    required List<Map<String, String>> messages,
    required String? imageBase64,
    required double? temperature,
    required int? maxTokens,
    Map<String, String> extraHeaders = const {},
  }) async {
    final apiMessages = <Map<String, dynamic>>[];

    apiMessages.addAll(_buildOpenAICompatibleMessages(messages, imageBase64));

    final response = await _post(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        ...extraHeaders,
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: $providerLabel returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _streamOpenAICompatible({
    required String endpoint,
    required String providerLabel,
    required List<Map<String, String>> messages,
    required String? imageBase64,
    required double? temperature,
    required int? maxTokens,
    required void Function(String token) onToken,
    Map<String, String> extraHeaders = const {},
  }) async {
    final request = http.Request('POST', Uri.parse(endpoint));
    request.headers.addAll({
      'Authorization': 'Bearer $_apiKey',
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      ...extraHeaders,
    });
    request.body = jsonEncode({
      'model': _model,
      'messages': _buildOpenAICompatibleMessages(messages, imageBase64),
      'temperature': temperature ?? AppConstants.defaultTemperature,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'stream': true,
    });

    final client = http.Client();
    _activeStreamClient = client;
    try {
      final response = await client.send(request).timeout(_connectTimeout);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        return 'ERROR: $providerLabel returned ${response.statusCode} — $body';
      }

      final buffer = StringBuffer();
      final lines = response.stream
          .timeout(streamIdleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      // Providers can fail after the 200 (rate limits, moderation, upstream
      // errors) by sending an error event, or just drop the connection. Track
      // both so they aren't shown as a normal, complete reply.
      var finished = false;
      String? streamError;

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]') {
          finished = true;
          break;
        }

        Map? data;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map) data = decoded;
        } catch (_) {
          continue; // Malformed keep-alive chunk.
        }
        if (data == null) continue;

        final error = data['error'];
        if (error != null) {
          streamError = error is Map
              ? '${error['message'] ?? error['code'] ?? error}'
              : '$error';
          break;
        }

        final choices = data['choices'];
        final choice =
            choices is List && choices.isNotEmpty ? choices.first : null;
        if (choice is! Map) continue;
        if (choice['finish_reason'] != null) finished = true;
        final delta = choice['delta'];
        final token = delta is Map ? delta['content']?.toString() : null;
        if (token != null && token.isNotEmpty) {
          buffer.write(token);
          onToken(token);
        }
      }

      final text = buffer.toString();
      if (streamError != null) {
        return text.isEmpty
            ? 'ERROR: $providerLabel returned an error — $streamError'
            : '$text\n\n⚠️ $providerLabel stopped with an error: $streamError';
      }
      if (text.isEmpty) {
        return 'ERROR: $providerLabel returned an empty response.';
      }
      if (!finished) {
        return '$text\n\n⚠️ The response was cut off before it finished.';
      }
      return text;
    } finally {
      if (identical(_activeStreamClient, client)) _activeStreamClient = null;
      client.close();
    }
  }

  List<Map<String, dynamic>> _buildOpenAICompatibleMessages(
    List<Map<String, String>> messages,
    String? imageBase64,
  ) {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    return apiMessages;
  }
}
