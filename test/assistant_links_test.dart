import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:neuromesh_ai/widgets/chat_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('assistant text and source chips open web links', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'launch') return null;
      launched.add((call.arguments as Map)['url'] as String);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          AssistantMarkdown(
            text: '[Release notes](https://example.org/release?version=2)\n\n'
                'https://example.org/help\n\n'
                'www.example.org/docs',
          ),
          ChatSourcesList(
            sources: [('Original announcement', 'https://example.net')],
            muted: Colors.grey,
          ),
        ]),
      ),
    ));

    for (final label in [
      'Release notes',
      'https://example.org/help',
      'www.example.org/docs',
    ]) {
      await tester.tap(find.text(label, findRichText: true));
      await tester.pump();
    }
    await tester.tap(find.textContaining('Sources (1)'));
    await tester.pump();
    await tester.tap(find.text('example.net'));
    await tester.pump();

    expect(launched, [
      'https://example.org/release?version=2',
      'https://example.org/help',
      'http://www.example.org/docs',
      'https://example.net',
    ]);
  });
}
