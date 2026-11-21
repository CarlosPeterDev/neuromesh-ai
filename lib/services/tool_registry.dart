import 'dart:async';
import 'dart:convert';

/// JSON Schema subset used by built-ins and MCP. Unknown schema keywords do
/// not grant capabilities; handlers still enforce platform permission checks.
void validateToolArguments(Object? value, Map schema,
    [String path = 'arguments']) {
  final type = schema['type'];
  if (schema['anyOf'] is List) {
    var matched = false;
    for (final branch in schema['anyOf'] as List) {
      try {
        validateToolArguments(value, branch as Map, path);
        matched = true;
      } on FormatException {/* try next */}
    }
    if (!matched)
      throw FormatException('$path does not match any allowed schema');
  }
  if (type is List &&
      !type.any((t) {
        try {
          validateToolArguments(value, {'type': t}, path);
          return true;
        } on FormatException {
          return false;
        }
      })) throw FormatException('$path has the wrong type');
  final valid = switch (type) {
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'boolean' => value is bool,
    'integer' => value is int,
    'number' => value is num && value.isFinite,
    'null' => value == null,
    _ => true,
  };
  if (!valid) throw FormatException('$path must be $type');
  if (schema['enum'] is List && !(schema['enum'] as List).contains(value)) {
    throw FormatException('$path is not an allowed value');
  }
  if (value is num &&
      ((schema['minimum'] is num && value < schema['minimum']) ||
          (schema['maximum'] is num && value > schema['maximum'])))
    throw FormatException('$path is outside its allowed range');
  if (value is String &&
      schema['minLength'] is int &&
      value.length < schema['minLength'])
    throw FormatException('$path is too short');
  if (value is String &&
      schema['pattern'] is String &&
      !RegExp(schema['pattern']).hasMatch(value))
    throw FormatException('$path has invalid formatting');
  if (value is String &&
      value.length > (schema['maxLength'] as int? ?? 262144)) {
    throw FormatException('$path is too long');
  }
  if (value is Map) {
    final props = schema['properties'] as Map? ?? const {};
    for (final key in schema['required'] as List? ?? const []) {
      if (!value.containsKey(key))
        throw FormatException('$path.$key is required');
    }
    for (final entry in value.entries) {
      if (!props.containsKey(entry.key) &&
          schema['additionalProperties'] == false) {
        throw FormatException('$path.${entry.key} is unknown');
      }
      if (props[entry.key] is Map) {
        validateToolArguments(
            entry.value, props[entry.key], '$path.${entry.key}');
      }
    }
  }
  if (value is List) {
    if (value.length > (schema['maxItems'] as int? ?? 100)) {
      throw FormatException('$path has too many items');
    }
    if (schema['items'] is Map) {
      for (final item in value) {
        validateToolArguments(item, schema['items'], '$path[]');
      }
    }
  }
}

/// Migrates the existing concise signatures to actual schemas. New tools may
/// provide schemas directly; descriptions are retained for the model.
Map<String, dynamic> schemaFromSignature(String signature) {
  final decoded = jsonDecode(signature);
  if (decoded is! Map) throw const FormatException('Invalid tool signature');
  if (decoded['type'] == 'object') return Map<String, dynamic>.from(decoded);
  return {
    'type': 'object',
    'properties': {
      for (final e in decoded.entries)
        '${e.key}': {
          'description': '${e.value}',
          // Legacy optional values permit their documented numeric/bool forms.
          if ('${e.value}'.contains('offset') ||
              '${e.value}'.contains('max characters'))
            'type': 'integer'
          else if ('${e.value}'.contains('JSON object'))
            'type': ['object', 'string']
          else if ('${e.value}'.contains('list of'))
            'type': ['array', 'string']
          else if ('${e.value}'.contains('true'))
            'type': ['boolean', 'string']
          else
            'type': 'string',
        },
    },
    'required': [
      for (final e in decoded.entries)
        if (!'${e.value}'.startsWith('optional')) '${e.key}'
    ],
    'additionalProperties': false,
  };
}

class RegisteredTool {
  const RegisteredTool(
      {required this.id,
      required this.description,
      required this.inputSchema,
      required this.execute,
      this.permissions = const [],
      this.dependencies = const [],
      this.available,
      this.timeout = const Duration(seconds: 120),
      this.outputSchema = const {'type': 'string', 'maxLength': 6000},
      this.retrySafe = false});
  final String id, description;
  final Map<String, dynamic> inputSchema, outputSchema;
  final List<String> permissions, dependencies;
  final bool Function()? available;
  final Duration timeout;
  final bool retrySafe;
  final Future<String> Function(Map<String, dynamic>) execute;
  Map<String, dynamic> get nativeSchema => {
        'type': 'function',
        'function': {
          'name': id,
          'description': description,
          'parameters': inputSchema,
        }
      };
}

class ToolRegistry {
  ToolRegistry(Iterable<RegisteredTool> tools)
      : _tools = {for (final t in tools) t.id: t};
  final Map<String, RegisteredTool> _tools;
  Iterable<RegisteredTool> get available =>
      _tools.values.where((t) => t.available?.call() ?? true);
  RegisteredTool? find(String id) =>
      available.where((t) => t.id == id).firstOrNull;
  List<Map<String, dynamic>> get schemas =>
      available.map((t) => t.nativeSchema).toList();
}

class AgentLimits {
  const AgentLimits(
      {this.maxSteps = 20,
      this.modelTimeout = const Duration(seconds: 120),
      this.totalTimeout = const Duration(minutes: 10),
      this.readRetries = 1});
  final int maxSteps, readRetries;
  final Duration modelTimeout, totalTimeout;
}

class ModelToolCall {
  const ModelToolCall(this.name, this.arguments,
      {this.id = '', this.dependsOn = const []});
  final String name, id;
  final List<String> dependsOn;
  final Map<String, dynamic> arguments;
}

/// Only an explicit tagged object at the end of a model answer is executable.
/// JSON in ordinary prose, code examples or reasoning never executes.
List<ModelToolCall> decodeModelCalls(String response) {
  var answer = response;
  final endThought = answer.lastIndexOf('</think>');
  if (endThought >= 0) answer = answer.substring(endThought + 8);
  if (answer.contains('<think>')) return [];
  final match =
      RegExp(r'^\s*<tool_call>([\s\S]*?)</tool_call>\s*$').firstMatch(answer);
  if (match == null) {
    if (answer.trimLeft().startsWith('<tool_call>'))
      throw const FormatException('Malformed tool call');
    return [];
  }
  final obj = jsonDecode(match.group(1)!);
  final calls =
      obj is Map && obj['calls'] is List ? obj['calls'] as List : [obj];
  if (calls.isEmpty || calls.length > 8)
    throw const FormatException('Use one to eight calls per turn');
  return calls.map((call) {
    if (call is! Map || call['name'] is! String || call['arguments'] is! Map) {
      throw const FormatException('Each call needs name and object arguments');
    }
    final id = call['id'] ?? '';
    final dependencies = call['depends_on'] ?? const [];
    if (id is! String ||
        id.length > 80 ||
        dependencies is! List ||
        dependencies.length > 20 ||
        dependencies.any((d) => d is! String)) {
      throw const FormatException('Invalid call ID or dependency list');
    }
    return ModelToolCall(
        call['name'], Map<String, dynamic>.from(call['arguments']),
        id: id, dependsOn: dependencies.cast<String>());
  }).toList();
}

String encodeModelCalls(List<ModelToolCall> calls,
        {List<String> plan = const []}) =>
    '<tool_call>${jsonEncode({
          if (plan.isNotEmpty) 'plan': plan,
          'calls': [
            for (final c in calls)
              {
                'name': c.name,
                'arguments': c.arguments,
                if (c.id.isNotEmpty) 'id': c.id,
                if (c.dependsOn.isNotEmpty) 'depends_on': c.dependsOn
              }
          ]
        })}</tool_call>';

/// A model-authored plan is progress metadata and never executable code.
List<String> decodeModelPlan(String response) {
  if (decodeModelCalls(response).isEmpty) return [];
  final start = response.indexOf('<tool_call>');
  final end = response.lastIndexOf('</tool_call>');
  if (start < 0 || end < start) return [];
  final data = jsonDecode(response.substring(start + 11, end));
  if (data is! Map || data['plan'] == null) return [];
  final plan = data['plan'];
  if (plan is! List ||
      plan.length > 20 ||
      plan.any((s) => s is! String || s.length > 300)) {
    throw const FormatException('A plan must contain up to 20 short strings');
  }
  return plan.cast<String>();
}
