import 'dart:convert';

import 'package:get/get.dart';

import 'agent_tools.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'mcp_client.dart';

class AgentEvent {
  /// 'task', 'model', 'tool_call', 'tool_result', 'answer', 'info', 'error'
  final String kind;
  final String text;
  AgentEvent(this.kind, this.text);
}

/// Asks the user whether a tool may run. Returns true to allow.
typedef ToolConfirm = Future<bool> Function(
    String toolName, String serverName, Map<String, dynamic> args);

class _BuiltIn {
  final String name;
  final String description;
  final String params;
  final String Function(Map<String, dynamic> args) run;
  const _BuiltIn(this.name, this.description, this.params, this.run);
}

/// Runs a multi-step task: the local model may call built-in tools or tools
/// from linked MCP servers. MCP tools always need the user's confirmation.
class AgentService extends GetxService {
  static const _serversKey = 'mcp_servers';
  static const maxSteps = 6;

  final HiveService _hive = Get.find<HiveService>();

  final servers = <McpServerConfig>[].obs;
  final serverStatus = <String, String>{}.obs;
  final _tools = <String, List<McpTool>>{};
  final events = <AgentEvent>[].obs;
  final isRunning = false.obs;
  bool _cancel = false;

  late final List<_BuiltIn> _builtIns = [
    _BuiltIn(
      'calculator',
      'Evaluate an arithmetic expression exactly.',
      '{"expression":"string, e.g. (12+3)*4/5"}',
      (args) {
        final expr = (args['expression'] ?? '').toString();
        return formatNumber(evaluateExpression(expr));
      },
    ),
    _BuiltIn(
      'current_time',
      'Get the phone\'s current local date and time.',
      '{}',
      (args) => DateTime.now().toString(),
    ),
  ];

  @override
  void onInit() {
    super.onInit();
    final raw = _hive.getSetting<List>(_serversKey) ?? const [];
    servers.value = raw
        .whereType<Map>()
        .map((m) => McpServerConfig.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> _saveServers() =>
      _hive.setSetting(_serversKey, servers.map((s) => s.toMap()).toList());

  Future<void> addServer(String name, String url, String token) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final cfg = McpServerConfig(id: id, name: name.trim(), url: url.trim(), token: token.trim());
    servers.add(cfg);
    await _saveServers();
    await refreshServer(cfg);
  }

  Future<void> removeServer(String id) async {
    servers.removeWhere((s) => s.id == id);
    _tools.remove(id);
    serverStatus.remove(id);
    await _saveServers();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = servers.indexWhere((s) => s.id == id);
    if (i < 0) return;
    servers[i] = servers[i].copyWith(enabled: enabled);
    await _saveServers();
  }

  /// Connects to the server and lists its tools; updates [serverStatus].
  Future<void> refreshServer(McpServerConfig cfg) async {
    serverStatus[cfg.id] = 'Connecting…';
    final client = McpClient(cfg);
    try {
      final tools = await client.listTools();
      _tools[cfg.id] = tools;
      serverStatus[cfg.id] = 'Connected · ${tools.length} tool${tools.length == 1 ? '' : 's'}';
    } catch (e) {
      _tools.remove(cfg.id);
      serverStatus[cfg.id] = e.toString();
    } finally {
      client.dispose();
    }
  }

  List<McpTool> toolsOf(String id) => _tools[id] ?? const [];

  Iterable<McpTool> get _enabledMcpTools sync* {
    for (final s in servers.where((s) => s.enabled)) {
      yield* toolsOf(s.id);
    }
  }

  String _systemPrompt() {
    final b = StringBuffer()
      ..writeln('You are an assistant that can use tools to complete the user\'s task.')
      ..writeln('To use a tool, reply with ONLY this and nothing else:')
      ..writeln('<tool_call>{"name":"TOOL_NAME","arguments":{...}}</tool_call>')
      ..writeln('Call one tool at a time. You will then receive the result.')
      ..writeln('Use a tool only when it is needed. When you have what you need, answer the user directly without a tool call.')
      ..writeln()
      ..writeln('Available tools:');
    for (final t in _builtIns) {
      b.writeln('- ${t.name}: ${t.description} arguments: ${t.params}');
    }
    for (final t in _enabledMcpTools) {
      final schema = jsonEncode(t.inputSchema['properties'] ?? {});
      final shortSchema = schema.length > 600 ? '${schema.substring(0, 600)}…' : schema;
      b.writeln('- ${t.qualifiedName}: ${t.description.replaceAll('\n', ' ')} arguments: $shortSchema');
    }
    return b.toString();
  }

  void cancel() {
    _cancel = true;
    final inference = Get.find<InferenceService>();
    if (inference.isGenerating.value) inference.stopGeneration();
  }

  Future<void> run(String task, ToolConfirm confirm) async {
    if (isRunning.value) return;
    final inference = Get.find<InferenceService>();
    events.clear();
    events.add(AgentEvent('task', task));
    if (!inference.isModelLoaded.value) {
      events.add(AgentEvent('error', 'Load a local model first (Models tab).'));
      return;
    }
    isRunning.value = true;
    _cancel = false;
    final history = <Map<String, String>>[];
    var prompt = task;
    final system = _systemPrompt();
    try {
      for (var step = 0; step < maxSteps; step++) {
        if (_cancel) break;
        final reply = (await inference.generate(
          prompt: prompt,
          systemPrompt: system,
          conversationHistory: history,
          source: 'agent',
          maxTokens: 700,
        ))
            .trim();
        if (_cancel) break;
        if (reply.startsWith('ERROR:')) {
          events.add(AgentEvent('error', reply));
          break;
        }
        final call = parseToolCall(reply);
        if (call == null) {
          events.add(AgentEvent('answer', reply));
          return;
        }
        if (call.textBefore.isNotEmpty) events.add(AgentEvent('model', call.textBefore));
        events.add(AgentEvent('tool_call', '${call.name} ${jsonEncode(call.arguments)}'));
        final result = await _execute(call, confirm);
        events.add(AgentEvent('tool_result', result));
        history
          ..add({'role': 'user', 'content': prompt})
          ..add({'role': 'assistant', 'content': reply});
        prompt = 'Tool result for ${call.name}:\n$result\n\n'
            'Now either call another tool or give the final answer to: $task';
      }
      if (_cancel) {
        events.add(AgentEvent('info', 'Stopped.'));
      } else {
        events.add(AgentEvent('info',
            'Stopped after $maxSteps steps without a final answer. A small model may be too weak for this task.'));
      }
    } catch (e) {
      events.add(AgentEvent('error', e.toString()));
    } finally {
      isRunning.value = false;
    }
  }

  Future<String> _execute(ParsedToolCall call, ToolConfirm confirm) async {
    for (final t in _builtIns) {
      if (t.name == call.name) {
        try {
          return t.run(call.arguments);
        } catch (e) {
          return 'Error: $e';
        }
      }
    }
    McpTool? tool;
    for (final t in _enabledMcpTools) {
      if (t.qualifiedName == call.name) tool = t;
    }
    if (tool == null) {
      return 'Error: unknown tool "${call.name}". Use only the listed tools.';
    }
    final cfg = servers.firstWhere((s) => s.id == tool!.serverId);
    final allowed = await confirm(tool.name, cfg.name, call.arguments);
    if (!allowed) return 'The user denied this tool call.';
    final client = McpClient(cfg);
    try {
      final out = await client.callTool(tool.name, call.arguments);
      return out.length > 4000 ? '${out.substring(0, 4000)}\n…(truncated)' : out;
    } catch (e) {
      return 'Error: $e';
    } finally {
      client.dispose();
    }
  }
}
