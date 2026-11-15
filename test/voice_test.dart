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

  test('wav round trip keeps samples and rate', () {
    final src = Float32List.fromList([0, 0.25, -0.25, 0.5, -0.5]);
    final back = decodeWav(encodeWav(src, 22050))!;
    expect(back.rate, 22050);
    expect(back.samples.length, 5);
    expect(back.samples[3], closeTo(0.5, 0.001));
    expect(decodeWav(Uint8List(10)), isNull);
  });

  test('speech chunks drop markdown, code and thinking', () {
    final c = speechChunks('<think>hmm</think>**Hello** there. How are you? ```x=1```');
    expect(c, ['Hello there.', 'How are you?']);
    expect(speechChunks('  '), isEmpty);
  });

  test('streaming sentences are released as they complete', () {
    var r = nextSentences('Hello there. How are', 0);
    expect(r.sentences, ['Hello there.']);
    r = nextSentences('Hello there. How are you today? Fine', r.next);
    expect(r.sentences, ['How are you today?']);
    r = nextSentences('Hello there. How are you today? Fine', r.next, flush: true);
    expect(r.sentences, ['Fine']);
  });

  test('thinking is never spoken while streaming', () {
    final r = nextSentences('<think>let me see. ok. ', 0);
    expect(r.sentences, isEmpty);
    final r2 = nextSentences('<think>x.</think>Answer is here. ', 0);
    expect(r2.sentences, ['Answer is here.']);
  });

  test('voice catalog ids unique and resolvable', () {
    final ids = kVoiceModels.map((m) => m.id).toSet();
    expect(ids.length, kVoiceModels.length);
    expect(voiceModelById('piper-ar-kareem')?.espeakVoice, 'ar');
    expect(voiceModelById('pocket-tts-clone')?.clone, true);
    expect(voiceModelById('nope'), isNull);
  });
}
