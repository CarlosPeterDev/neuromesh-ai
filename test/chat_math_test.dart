import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/widgets/chat_math.dart';

void main() {
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
