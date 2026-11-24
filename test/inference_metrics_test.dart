import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' as llama;
import 'package:neuromesh_ai/models/chat_message.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy chunk rates are hidden and measured token rates round-trip', () {
    final message = ChatMessage.fromMap({'tokensPerSec': 8.5});
    expect(message.tokensPerSec, isNull);

    final measured = ChatMessage.fromMap({
      ...message.toMap(),
      'measuredTokensPerSec': 9.5,
    });
    expect(ChatMessage.fromMap(measured.toMap()).tokensPerSec, 9.5);
  });

  test('native counts are independent of the text chunks delivered to Dart',
      () async {
    final messenger = binding.defaultBinaryMessenger;
    const prefix = 'dev.flutter.pigeon.llama_flutter_android';
    const codec = llama.LlamaHostApi.pigeonChannelCodec;
    for (final method in ['generateChat', 'dispose']) {
      messenger.setMockDecodedMessageHandler(
        BasicMessageChannel<Object?>('$prefix.LlamaHostApi.$method', codec),
        (_) async => [null],
      );
    }
    final controller = llama.LlamaController();
    addTearDown(controller.dispose);

    final progress = <(int, int)>[];
    final output = controller.generateChat(
      messages: [llama.ChatMessage(role: 'user', content: 'Hi')],
      onDecodeProgress: (count, micros) => progress.add((count, micros)),
    ).toList();

    Future<void> send(String method, [Object? arguments]) async {
      await messenger.handlePlatformMessage('$prefix.LlamaFlutterApi.$method',
          codec.encodeMessage(arguments), (_) {});
    }

    await send('onToken', ['Hi ', 1, 0]);
    await send('onToken', ['👋', 3, 400000]);
    await send('onToken', ['', 4, 600000]);
    await send('onToken', ['legacy text']);
    await send('onDone');

    expect(await output, ['Hi ', '👋', 'legacy text']);
    expect(progress, [(1, 0), (3, 400000), (4, 600000)]);
  });
}
