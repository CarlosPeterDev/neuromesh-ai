import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';

import 'openai_server_service_io.dart';
import 'opencode_tools.dart';

bool get showAndroidAgentHub =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

typedef OpenCodeMessage = ({String role, String text});

/// Configuration for a user-managed OpenCode server using the phone's model.
abstract final class OpenCodeLocalProfile {
  static const _model = 'neuromesh/${OpenAiServerService.agentModelId}';
  static const exportToFile = r'exec "$1" export "$2" --pure > "$3"';

  static String localProviderConfig({
    required String name,
    required int context,
    required String endpoint,
    bool allowTools = true,
  }) =>
      jsonEncode({
        'enabled_providers': ['neuromesh'],
        'model': _model,
        'small_model': _model,
        'default_agent': 'neuromesh',
        'agent': {
          'neuromesh': {
            'mode': 'primary',
            'prompt': allowTools
                ? 'Help the user understand their project. Read workspace files before describing their contents.'
                : 'Help the user understand their project. Answer from the chat context.',
          },
          'title': {'disable': true},
        },
        'share': 'disabled',
        'autoupdate': false,
        'lsp': false,
        'permission': {
          '*': 'deny',
          if (allowTools)
            for (final tool in openCodeReadTools) tool: 'allow',
        },
        'provider': {
          'neuromesh': {
            'name': 'NeuroMesh local',
            'npm': '@ai-sdk/openai-compatible',
            'env': ['NEUROMESH_BRIDGE_KEY'],
            'options': {'baseURL': endpoint},
            'models': {
              OpenAiServerService.agentModelId: {
                'name': name,
                'tool_call': allowTools,
                'attachment': false,
                'limit': {
                  'context': context,
                  'output': min(1024, context ~/ 4)
                },
              },
            },
          },
        },
      });

  static List<OpenCodeMessage> parseHistory(String output) {
    final data = jsonDecode(output);
    return messagesFrom(data is Map ? data['messages'] : null);
  }

  static List<OpenCodeMessage> messagesFrom(Object? entries) {
    if (entries is! List) return [];
    final messages = <OpenCodeMessage>[];
    for (final message in entries.whereType<Map>()) {
      final info = message['info'];
      final parts = message['parts'];
      final role = info is Map ? info['role'] : null;
      if ((role != 'user' && role != 'assistant') || parts is! List) continue;
      final text = parts
          .whereType<Map>()
          .where((part) => part['type'] == 'text')
          .map((part) => part['text'])
          .whereType<String>()
          .join('\n');
      if (text.isNotEmpty) messages.add((role: role as String, text: text));
    }
    return messages;
  }

  static Map? parseEvent(String line) {
    try {
      final value = jsonDecode(line);
      return value is Map && value['type'] is String ? value : null;
    } on FormatException {
      return null;
    }
  }
}
