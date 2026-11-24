import 'dart:math' as math;

/// Parsed `<tool_call>{...}</tool_call>` from a model reply.
class ParsedToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  final String textBefore;
  const ParsedToolCall(this.name, this.arguments, this.textBefore);
}

double evaluateExpression(String input) {
  final p = _ExprParser(input);
  final v = p.parse();
  if (v.isNaN || v.isInfinite)
    throw const FormatException('Result is not a number');
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
      throw FormatException(
          i < s.length ? 'Unexpected "${s[i]}"' : 'Unexpected end');
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

/// Exact decimal integer operations with fixed input and work limits.
String evaluateBoundedIntegers(Map<String, dynamic> args) {
  final values = (args['values'] as String).split(',');
  if (values.length > 32 ||
      values.any((item) => !RegExp(r'^-?[0-9]{1,80}$').hasMatch(item.trim()))) {
    throw const FormatException(
        'Use up to 32 decimal integers of at most 80 digits.');
  }
  final integers = values.map((value) => BigInt.parse(value.trim()));
  final value = switch (args['operation']) {
    'sum' => integers.reduce((a, b) => a + b),
    'product' => integers.reduce((a, b) => a * b),
    'min' => integers.reduce((a, b) => a < b ? a : b),
    'max' => integers.reduce((a, b) => a > b ? a : b),
    'gcd' => integers.reduce((a, b) => a.gcd(b)).abs(),
    _ => throw const FormatException('Unknown integer operation.'),
  };
  return value.toString();
}
