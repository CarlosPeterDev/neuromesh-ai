import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/widgets/scroll_to_end.dart';

void main() {
  for (final explicitController in [true, false]) {
    testWidgets(
        'jumps to the end with explicit scroll controller $explicitController',
        (tester) async {
      final controller = explicitController ? ScrollController() : null;
      var jumped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ScrollToEnd(
            label: 'Go to end',
            controller: controller,
            onJump: () => jumped = true,
            child: ListView.builder(
              controller: controller,
              itemExtent: 64,
              itemCount: 70,
              itemBuilder: (context, index) => Text('Item $index'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Go to end'), findsOneWidget);
      await tester.tap(find.byTooltip('Go to end'));
      await tester.pumpAndSettle();
      expect(jumped, isTrue);
      expect(find.text('Item 69'), findsOneWidget);
      expect(find.byTooltip('Go to end'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller?.dispose();
    });
  }
}
