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

/// Numeric intermediate results from the same parser used by Calc.
List<String> calculatorSteps(String expression) {
  final steps = <String>[];
  _ExprParser(expression, steps: steps).parse();
  return steps.length > 1 ? steps.take(12).toList() : const [];
}

class _ExprParser {
  _ExprParser(this.s, {this.steps});
  final String s;
  final List<String>? steps;
  double _step(double result, String operation) {
    if (result.isFinite)
      steps?.add('${operation.trim()} = ${formatNumber(result)}');
    return result;
  }

  double _binary(double left, String symbol, double right, double result) =>
      steps == null
          ? result
          : _step(
              result, '${formatNumber(left)} $symbol ${formatNumber(right)}');
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
        final operand = _term();
        v = _binary(v, '+', operand, v + operand);
      } else if (_eat('-')) {
        final operand = _term();
        v = _binary(v, '−', operand, v - operand);
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _unary();
    while (true) {
      if (_eat('*')) {
        final operand = _unary();
        v = _binary(v, '×', operand, v * operand);
      } else if (_eat('/')) {
        final d = _unary();
        if (d == 0) throw const FormatException('Division by zero');
        v = _binary(v, '÷', d, v / d);
      } else if (_eat('%')) {
        final d = _unary();
        if (d == 0) throw const FormatException('Division by zero');
        v = _binary(v, '%', d, v % d);
      } else {
        return v;
      }
    }
  }

  double _power() {
    final base = _atom();
    if (_eat('^')) {
      final exponent = _unary();
      return _binary(base, '^', exponent, math.pow(base, exponent).toDouble());
    }
    return base;
  }

  double _unary() {
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _power();
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
          return steps == null
              ? math.sqrt(arg)
              : _step(math.sqrt(arg), 'sqrt(${formatNumber(arg)})');
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

String evaluateCalculator(Map<String, dynamic> args) {
  final expression = args['expression'];
  if (expression is! String || expression.isEmpty || expression.length > 180) {
    throw const FormatException(
        'Provide an arithmetic expression of at most 180 characters.');
  }
  final value = evaluateExpression(expression);
  final digits = args['decimal_places'];
  if (digits == null) return formatNumber(value);
  if (digits is! int || digits < 0 || digits > 12) {
    throw const FormatException('Choose between 0 and 12 decimal places.');
  }
  return value.toStringAsFixed(digits);
}

/// Reads literal arithmetic after the model has selected the calculator.
/// A single source expression avoids asking a model to retype its operands.
({String expression, String remaining})? literalArithmetic(String input) {
  var text = input
      .replaceAll(r'\left', '')
      .replaceAll(r'\right', '')
      .replaceAll(r'\times', '*')
      .replaceAll(r'\cdot', '*')
      .replaceAll(r'\div', '/')
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll('−', '-')
      .replaceAll('²', '^2')
      .replaceAll('³', '^3');
  text = text.replaceAllMapped(
      RegExp(r'\\sqrt\{([^{}]+)\}|√([0-9]+(?:\.[0-9]+)?)'),
      (match) => 'sqrt(${match[1] ?? match[2]})');
  text = text.replaceAllMapped(RegExp(r'\\frac\{([^{}]+)\}\{([^{}]+)\}'),
      (match) => '(${match[1]})/(${match[2]})');
  text = text.replaceAllMapped(
      RegExp(r'\^\{([+-]?[0-9]+)\}'), (match) => '^(${match[1]})');
  if (RegExp(r'\\(?:frac|sqrt)|√|[0-9],[0-9]').hasMatch(text)) return null;

  final formulas = <({String expression, String remaining})>[];
  final math =
      RegExp(r'(?:\b(?:sqrt|abs|round|floor|ceil)\b|[0-9 .()+*/%^-])+');
  for (final match in math.allMatches(text)) {
    final value = match[0]!.trim().replaceFirst(RegExp(r'\.$'), '');
    if (value.length > 180 || !RegExp(r'\d').hasMatch(value)) continue;
    if (!RegExp(r'[0-9)]\s*[+*/%^-]|[a-z]+\(').hasMatch(value)) continue;
    if (match.start > 0 &&
        RegExp(r'[A-Za-z0-9_]').hasMatch(text[match.start - 1]) &&
        !match[0]!.startsWith(' ')) continue;
    if (match.end < text.length &&
        RegExp(r'[A-Za-z0-9_]').hasMatch(text[match.end]) &&
        !match[0]!.endsWith(' ')) continue;
    formulas.add((
      expression: value,
      remaining:
          '${text.substring(0, match.start)} ${text.substring(match.end)}'
              .trim()
              .replaceAll(RegExp(r'\s+'), ' '),
    ));
  }
  return formulas.length == 1 ? formulas.single : null;
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
