import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Raised on an interrupted native stream. Partial calls must never execute.
class NativeAgentStreamError implements Exception {
  NativeAgentStreamError(this.message, this.partialText);
  final String message, partialText;
  @override
  String toString() => message;
}

/// Reads real provider deltas, keeping argument fragments out of visible text.
/// A JSON response is supported when a provider declines streaming.
Future<({Map<String, dynamic> data, bool streamed})> readNativeAgentResponse(
  http.StreamedResponse response, {
  required String provider,
  required Duration idleTimeout,
  required void Function(String) onText,
}) async {
  const maxBytes = 2 * 1024 * 1024;
  var bytes = 0;
  final text = StringBuffer();
  Stream<List<int>> bounded() async* {
    await for (final chunk in response.stream.timeout(idleTimeout)) {
      bytes += chunk.length;
      if (bytes > maxBytes)
        throw const FormatException('Provider response exceeds the size limit');
      yield chunk;
    }
  }

  final isSse = (response.headers['content-type'] ?? '')
      .toLowerCase()
      .contains('text/event-stream');
  if (!isSse) {
    final body = await bounded().transform(utf8.decoder).join();
    final data = jsonDecode(body);
    if (data is! Map)
      throw const FormatException('Provider returned an invalid response');
    return (data: Map<String, dynamic>.from(data), streamed: false);
  }
  final calls = <int, Map<String, dynamic>>{};
  final blocks = <int, Map<String, dynamic>>{};
  final inputJson = <int, StringBuffer>{};
  final googleParts = <Map<String, dynamic>>[];
  var finished = false;
  var stopped = false;
  var anthropicStopReason = false;
  void delta(String value) {
    if (value.isEmpty) return;
    text.write(value);
    onText(value);
  }

  void fail(String message) =>
      throw NativeAgentStreamError(message, text.toString());
  void event(String payload) {
    if (payload == '[DONE]') {
      stopped = true;
      return;
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map) throw const FormatException('Invalid SSE event');
    if (decoded['error'] != null || decoded['type'] == 'error')
      fail('Provider reported a streaming error: ${decoded['error']}');
    if (provider == 'google') {
      final candidates = decoded['candidates'];
      if (candidates is! List || candidates.isEmpty) {
        if (decoded['promptFeedback']?['blockReason'] != null)
          fail('Provider blocked the response');
        return;
      }
      final candidate = candidates.first as Map;
      for (final raw in candidate['content']?['parts'] as List? ?? const []) {
        final part = Map<String, dynamic>.from(raw as Map);
        if (part['text'] is String && part['thought'] != true)
          delta(part['text']);
        if (part['functionCall'] is Map) googleParts.add(part);
        if (googleParts.length > 8)
          fail('Provider requested too many tools in one batch');
      }
      final reason = candidate['finishReason'];
      if (reason != null) {
        if (reason != 'STOP')
          fail('Provider stopped before completion: $reason');
        finished = true;
      }
      return;
    }
    if (provider == 'anthropic') {
      final kind = decoded['type'];
      final index = decoded['index'];
      if (kind == 'content_block_start' && index is int) {
        if (blocks.length >= 32)
          fail('Provider returned too many content blocks');
        final block =
            Map<String, dynamic>.from(decoded['content_block'] as Map);
        blocks[index] = block;
        if (block['type'] == 'text') delta(block['text'] as String? ?? '');
      } else if (kind == 'content_block_delta' && index is int) {
        final part = decoded['delta'] as Map;
        if (part['type'] == 'text_delta') {
          final value = part['text'] as String;
          final block = blocks[index];
          if (block == null || block['type'] != 'text')
            fail('Text delta has no matching block');
          block!['text'] = '${block['text'] ?? ''}$value';
          delta(value);
        } else if (part['type'] == 'input_json_delta') {
          if (blocks[index]?['type'] != 'tool_use')
            fail('Tool delta has no matching block');
          (inputJson[index] ??= StringBuffer())
              .write(part['partial_json'] as String);
        }
      } else if (kind == 'message_delta') {
        final reason = decoded['delta']?['stop_reason'];
        if (reason != null &&
            reason != 'end_turn' &&
            reason != 'tool_use' &&
            reason != 'stop_sequence')
          fail('Provider stopped before completion: $reason');
        if (reason != null) anthropicStopReason = true;
      } else if (kind == 'message_stop') {
        if (!anthropicStopReason)
          fail('Provider stream ended without a stop reason');
        finished = true;
      }
      return;
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return;
    final choice = choices.first as Map;
    final part = choice['delta'] as Map?;
    if (part?['content'] is String) delta(part!['content']);
    for (final raw in part?['tool_calls'] as List? ?? const []) {
      final index = raw['index'];
      if (index is! int || index < 0 || index > 7)
        fail('Invalid tool-call index');
      final call = calls.putIfAbsent(
          index as int,
          () => {
                'id': '',
                'type': 'function',
                'function': {'name': '', 'arguments': ''}
              });
      final id = raw['id'];
      if (id is String && id != call['id']) call['id'] = '${call['id']}$id';
      final fn = raw['function'];
      if (fn is Map) {
        if (fn['name'] is String && fn['name'] != call['function']['name'])
          call['function']['name'] = '${call['function']['name']}${fn['name']}';
        if (fn['arguments'] is String)
          call['function']['arguments'] =
              '${call['function']['arguments']}${fn['arguments']}';
      }
    }
    final reason = choice['finish_reason'];
    if (reason != null) {
      if (reason != 'stop' &&
          reason != 'tool_calls' &&
          reason != 'function_call')
        fail('Provider stopped before completion: $reason');
      finished = true;
    }
  }

  try {
    final data = <String>[];
    await for (final line
        in bounded().transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          event(data.join('\n'));
          data.clear();
        }
        if (stopped) break;
      } else if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      }
    }
    if (data.isNotEmpty && !stopped) event(data.join('\n'));
    if (!finished &&
        !(stopped &&
            calls.isEmpty &&
            provider != 'google' &&
            provider != 'anthropic'))
      fail(
          'The response was cut off before it finished; no pending tools were executed');
    if (provider == 'google') {
      return (
        data: {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': text.toString()},
                  ...googleParts
                ]
              }
            }
          ]
        },
        streamed: true
      );
    }
    if (provider == 'anthropic') {
      for (final entry in inputJson.entries) {
        blocks[entry.key]!['input'] = jsonDecode(entry.value.toString());
      }
      final indices = blocks.keys.toList()..sort();
      return (
        data: {
          'content': [for (final i in indices) blocks[i]]
        },
        streamed: true
      );
    }
    final indices = calls.keys.toList()..sort();
    return (
      data: {
        'choices': [
          {
            'message': {
              'content': text.toString(),
              'tool_calls': [for (final i in indices) calls[i]]
            }
          }
        ]
      },
      streamed: true
    );
  } on NativeAgentStreamError {
    rethrow;
  } catch (error) {
    throw NativeAgentStreamError('$error', text.toString());
  }
}
