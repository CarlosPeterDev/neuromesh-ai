import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/widgets/agent_steps.dart';

void main() {
  testWidgets('shows live steps and keeps finished details outside the chat',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget chat(bool live) => MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ListView(
              children: [
                if (!live) const Text('Here is your audio.'),
                AgentStepsView(
                  messageId: live ? 'live-1' : 'answer-1',
                  steps: [
                    AgentStep(
                      'text_to_speech',
                      'Creating an audio file',
                      {'text': 'Hello Carlos! ' * 500},
                      live ? '' : 'Saved speech.wav',
                      live,
                      live ? 0 : 1234,
                    ),
                  ],
                  live: live,
                ),
              ],
            ),
          ),
        );

    await tester.pumpWidget(chat(true));
    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('Input'), findsNothing);

    await tester.pumpWidget(chat(false));
    await tester.pumpAndSettle();
    expect(find.text('Here is your audio.'), findsOneWidget);
    expect(find.text('1 step · 1.2s'), findsOneWidget);
    expect(find.text('Creating an audio file'), findsNothing);

    await tester.tap(find.text('1 step · 1.2s'));
    await tester.pumpAndSettle();
    expect(find.text('Input'), findsNothing);
    await tester.tap(find.text('Creating an audio file'));
    await tester.pumpAndSettle();
    expect(find.text('Input'), findsOneWidget);
    expect(find.text('Text'), findsOneWidget);
    expect(tester.getSize(find.byType(BottomSheet)).height, lessThan(500));
    expect(tester.takeException(), isNull);
  });
}
