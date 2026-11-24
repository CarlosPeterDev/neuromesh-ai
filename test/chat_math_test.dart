import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/chat_calculator.dart';
import 'package:neuromesh_ai/widgets/chat_math.dart';

void main() {
  test('literal notation is preserved and rounded by Calc', () {
    final math = literalArithmetic(
        'What is ((84729 × 93617) + √987654321)/(137.29² + 17.83), rounded to 8 decimal places?')!;
    expect(
        evaluateCalculator({
          'expression': math.expression,
          'decimal_places': 8,
        }),
        '420436.17803423');
    expect(math.remaining, isNot(contains('987654321')));
    expect(literalArithmetic('Calculate 3×84,729'), isNull);
    expect(literalArithmetic('Calculate 2+3 and 7*9'), isNull);
    expect(evaluateExpression('-2^2'), -4);
    expect(evaluateExpression('2^-2'), 0.25);
  });

  testWidgets('renders inline and display math and keeps code literal',
      (tester) async {
    const source = r'''
An inline equation \(x^2\) and $y^2$.

\[
\frac{a}{b}
\]

$$\sqrt{2}$$

`$code$` and prices $10 to $20.
''';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkdownBody(
          data: source,
          inlineSyntaxes: chatMathSyntax(),
          blockSyntaxes: const [ChatMathBlock()],
          builders: chatMathBuilders(),
        ),
      ),
    ));
    expect(find.byType(Math), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });
}
