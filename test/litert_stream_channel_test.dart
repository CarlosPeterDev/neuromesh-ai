import 'package:flutter/services.dart';
import 'package:flutter_litert_lm/flutter_litert_lm_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LiteRT sends its input when subscribing to the result channel',
      () async {
    const method = MethodChannel('flutter_litert_lm');
    const events = MethodChannel('flutter_litert_lm/stream');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final methodCalls = <String>[];
    final subscriptions = <MethodCall>[];
    messenger.setMockMethodCallHandler(method, (call) async {
      methodCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      subscriptions.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockMethodCallHandler(events, null);
    });

    final stream = MethodChannelFlutterLitertLm().sendMessageStream(
      'conversation-b',
      [
        {'type': 'text', 'text': 'New conversation'}
      ],
      null,
    );
    expect(methodCalls, isEmpty);
    expect(subscriptions, isEmpty);
    final response = stream.first;
    await Future<void>.delayed(Duration.zero);
    expect(subscriptions.single.method, 'listen');
    expect(subscriptions.single.arguments['conversationId'], 'conversation-b');
    expect(subscriptions.single.arguments['contents'].single['text'],
        'New conversation');
    expect(methodCalls, isEmpty);

    await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({'text': 'Reply'}),
        (_) {});
    expect(await response, {'text': 'Reply'});
  });
}
