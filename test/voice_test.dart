import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/voice_models.dart';
import 'package:neuromesh_ai/services/voice_service.dart';

void main() {
  test('wav header is valid', () {
    final wav = encodeWav(Float32List.fromList([0, 0.5, -0.5, 1]), 16000);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(wav.length, 44 + 8);
  });

  test('speech chunks drop markdown, code and thinking', () {
    final c = speechChunks('<think>hmm</think>**Hello** there. How are you? ```x=1```');
    expect(c, ['Hello there.', 'How are you?']);
    expect(speechChunks('  '), isEmpty);
  });

  test('voice catalog ids unique and resolvable', () {
    final ids = kVoiceModels.map((m) => m.id).toSet();
    expect(ids.length, kVoiceModels.length);
    expect(voiceModelById('piper-ar-kareem')?.espeakVoice, 'ar');
    expect(voiceModelById('nope'), isNull);
  });
}
