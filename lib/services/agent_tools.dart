import 'dart:convert';
import 'dart:math' as math;

/// Parsed `<tool_call>{...}</tool_call>` from a model reply.
class ParsedToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  final String textBefore;
  const ParsedToolCall(this.name, this.arguments, this.textBefore);
}

final _literalSpeechRequest = RegExp(
  r'^\s*(?:please\s+)?(?:create|make|generate)\s+(?:an?\s+)?(?:audio|wav)\s+file\s+(?:that\s+)?(?:says?|saying)\s+(.+?)\s+using\s+(?:the\s+)?(?:tts|text.to.speech)\s+tool[.!]?\s*$',
  caseSensitive: false,
);

final _toolFirstSpeechRequest = RegExp(
  r'^\s*(?:please\s+)?use\s+(?:the\s+)?(?:tts|text.to.speech)(?:\s+tool)?\s+to\s+(?:create|make|generate)\s+(?:an?\s+)?(?:(?:audio|wav)\s+)?file\s+(?:that\s+)?(?:says?|saying)\s+(.+?)\s*$',
  caseSensitive: false,
);

/// Directly routes requests that explicitly supply the text and ask for TTS.
String? literalSpeechText(String request) {
  final match = _literalSpeechRequest.firstMatch(request) ??
      _toolFirstSpeechRequest.firstMatch(request);
  var text = match?.group(1)?.trim();
  if (text == null || text.isEmpty) return null;
  if ((text.startsWith('"') && text.endsWith('"')) ||
      (text.startsWith('“') && text.endsWith('”'))) {
    text = text.substring(1, text.length - 1).trim();
  }
  return text.isEmpty ? null : text;
}

final _namedWorkspaceFile = RegExp(
  r'^\s*(?:please\s+)?(?:create|make)\s+(?:an?\s+)?(?:empty\s+)?(?:text\s+)?file\s+'
  r'(?:(?:in\s+(?:the\s+)?workspace)\s+)(?:named|called)\s+([\w-]+\.txt)[.!]?\s*$',
  caseSensitive: false,
);

String? namedWorkspaceFile(String request) => _namedWorkspaceFile.firstMatch(request)?.group(1);

/// Finds the first tool call in [reply]. Tolerates a missing closing tag
/// and surrounding prose; returns null when there is no valid call.
ParsedToolCall? parseToolCall(String reply) {
  const open = '<tool_call>';
  final tag = reply.indexOf(open);
  var start = tag;
  var jsonStart = -1;
  var bare = false;
  if (tag >= 0) {
    jsonStart = reply.indexOf('{', tag + open.length);
  } else {
    // Small models often forget the tag: accept a bare JSON object (optionally
    // inside a code fence) that looks like {"name":..., "arguments":{...}}.
    final m = RegExp(r'\{\s*"(?:name|tool|function)"\s*:').firstMatch(reply);
    if (m == null) return null;
    jsonStart = m.start;
    start = m.start;
    bare = true;
  }
  if (jsonStart < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = jsonStart; i < reply.length; i++) {
    final c = reply[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) {
        try {
          final obj = jsonDecode(reply.substring(jsonStart, i + 1));
          if (obj is Map) {
            final name = obj['name'] ?? obj['tool'] ?? obj['function'];
            final args = obj['arguments'] ?? obj['parameters'] ?? obj['args'] ?? obj['input'];
            if (name is String && (!bare || args is Map)) {
              var before = reply.substring(0, start).trim();
              before = before.replaceAll(RegExp(r'```\w*\s*$'), '').trim();
              return ParsedToolCall(
                name,
                args is Map ? Map<String, dynamic>.from(args) : <String, dynamic>{},
                before,
              );
            }
          }
        } catch (_) {}
        return null;
      }
    }
  }
  return null;
}

/// Safe arithmetic evaluator for the built-in calculator tool.
/// Supports + - * / % ^, parentheses, unary minus, sqrt/abs/round/floor/ceil.
double evaluateExpression(String input) {
  final p = _ExprParser(input);
  final v = p.parse();
  if (v.isNaN || v.isInfinite) throw const FormatException('Result is not a number');
  return v;
}

class _ExprParser {
  _ExprParser(this.s);
  final String s;
  int i = 0;

  double parse() {
    final v = _expr();
    _ws();
    if (i != s.length) throw FormatException('Unexpected "${s[i]}"');
    return v;
  }

  void _ws() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
  }

  bool _eat(String c) {
    _ws();
    if (i < s.length && s[i] == c) {
      i++;
      return true;
    }
    return false;
  }

  double _expr() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        v += _term();
      } else if (_eat('-')) {
        v -= _term();
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _power();
    while (true) {
      if (_eat('*')) {
        v *= _power();
      } else if (_eat('/')) {
        final d = _power();
        if (d == 0) throw const FormatException('Division by zero');
        v /= d;
      } else if (_eat('%')) {
        final d = _power();
        if (d == 0) throw const FormatException('Division by zero');
        v %= d;
      } else {
        return v;
      }
    }
  }

  double _power() {
    final base = _unary();
    if (_eat('^')) return math.pow(base, _power()).toDouble();
    return base;
  }

  double _unary() {
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _atom();
  }

  double _atom() {
    _ws();
    if (_eat('(')) {
      final v = _expr();
      if (!_eat(')')) throw const FormatException('Missing )');
      return v;
    }
    final start = i;
    while (i < s.length && RegExp(r'[a-zA-Z]').hasMatch(s[i])) {
      i++;
    }
    if (i > start) {
      final fn = s.substring(start, i).toLowerCase();
      if (!_eat('(')) throw FormatException('Unknown name "$fn"');
      final arg = _expr();
      if (!_eat(')')) throw const FormatException('Missing )');
      switch (fn) {
        case 'sqrt':
          return math.sqrt(arg);
        case 'abs':
          return arg.abs();
        case 'round':
          return arg.roundToDouble();
        case 'floor':
          return arg.floorToDouble();
        case 'ceil':
          return arg.ceilToDouble();
        default:
          throw FormatException('Unknown function "$fn"');
      }
    }
    final numStart = i;
    while (i < s.length && RegExp(r'[0-9.]').hasMatch(s[i])) {
      i++;
    }
    if (i == numStart) {
      throw FormatException(i < s.length ? 'Unexpected "${s[i]}"' : 'Unexpected end');
    }
    final v = double.tryParse(s.substring(numStart, i));
    if (v == null) throw const FormatException('Bad number');
    return v;
  }
}

String formatNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  return v.toString();
}
