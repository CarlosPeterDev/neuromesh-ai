import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/widgets/composer_actions.dart';

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(640, 320),
    const Size(800, 1200),
    const Size(1200, 800)
  ]) {
    testWidgets(
        'composer preserves microphone and switches voice/send at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var value = '';
      var thinking = false;
      var mic = 0;
      var voice = 0;
      var send = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: StatefulBuilder(
                  builder: (context, setState) => Column(children: [
                        TextField(onChanged: (v) => setState(() => value = v)),
                        ComposerActions(
                            thinking: thinking,
                            hasContent: value.trim().isNotEmpty,
                            loading: false,
                            listening: false,
                            onThink: () => setState(() => thinking = !thinking),
                            onMicrophone: () => mic++,
                            onVoice: () => voice++,
                            onSend: () => send++,
                            onStop: () {})
                      ])))));
      expect(find.byKey(const ValueKey('voice-mode')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('microphone')));
      expect(mic, 1);
      await tester.tap(find.byKey(const ValueKey('voice-mode')));
      expect(voice, 1);
      await tester.tap(find.byKey(const ValueKey('think')));
      await tester.pump();
      expect(thinking, isTrue);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      expect(find.byKey(const ValueKey('microphone')), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-mode')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('send')));
      expect(send, 1);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.byKey(const ValueKey('voice-mode')), findsOneWidget);
      expect(thinking, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
