import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
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
    expect(find.textContaining('Working…'), findsOneWidget);
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
  testWidgets('open activity dialog updates while the agent runs',
      (tester) async {
    Widget view(bool running) => MaterialApp(
            home: Scaffold(
                body: AgentStepsView(
          messageId: 'same-turn',
          live: true,
          steps: [
            AgentStep('read_file', running ? 'Reading file' : 'Read file',
                {'name': 'notes.md'}, running ? '' : 'notes', running, 12)
          ],
        )));
    await tester.pumpWidget(view(true));
    await tester.tap(find.textContaining('Working…'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Reading file'), findsOneWidget);
    await tester.pumpWidget(view(false));
    await tester.pump();
    expect(find.text('Read file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('live trace completes even before the chat widget rebuilds',
      (tester) async {
    final source = ''.obs;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AgentStepsView(
      messageId: 'direct-call',
      live: true,
      traceSource: source,
      steps: const [AgentStep('write_file', 'Writing file', {}, '', true, 0)],
    ))));
    await tester.tap(find.textContaining('Working…'));
    await tester.pump(const Duration(milliseconds: 300));
    source.value =
        '> 🔧 {"n":"write_file","l":"Saved file","a":{},"r":"done","run":false,"ms":12}';
    await tester.pump();
    expect(find.text('Saved file'), findsOneWidget);
    expect(find.text('Writing file'), findsNothing);
    await tester.tap(find.byTooltip('Close'));
    // The deliberately unreconstructed background still has a running spinner.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
  testWidgets('an open tool detail shows its result as soon as it finishes',
      (tester) async {
    final source = ''.obs;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AgentStepsView(
      messageId: 'details',
      live: true,
      traceSource: source,
      steps: const [AgentStep('write_file', 'Writing file', {}, '', true, 0)],
    ))));
    await tester.tap(find.textContaining('Working…'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Writing file'));
    await tester.pump(const Duration(milliseconds: 300));
    source.value =
        '> 🔧 {"n":"write_file","l":"Saved file","a":{},"r":"done","run":false,"ms":12}';
    await tester.pump();
    expect(find.text('done'), findsOneWidget);
    expect(find.text('Result'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
