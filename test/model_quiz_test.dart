import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/views/model_quiz_view.dart';

void main() {
  List<StarterChoice> pick(StarterUse use, double ram, int storage,
          {bool speed = false}) =>
      recommendStarters(
        use: use,
        preferSpeed: speed,
        availableRam: ram,
        totalRam: 6,
        freeBytes: storage,
      );

  test('chooses the compact coder when memory or storage is limited', () {
    expect(pick(StarterUse.code, 3, 4e9.toInt()).first.model.name,
        'Qwen 2.5 Coder 1.5B');
    expect(pick(StarterUse.code, 1.2, 4e9.toInt()).first.model.name,
        'Qwen 2.5 Coder 0.5B');
    expect(pick(StarterUse.code, 3, 8e8.toInt()).first.model.name,
        'Qwen 2.5 Coder 0.5B');
    expect(pick(StarterUse.code, 3, 4e9.toInt(), speed: true).first.model.name,
        'Qwen 2.5 Coder 0.5B');
    expect(pick(StarterUse.code, 3, 4e8.toInt()), isEmpty);
  });

  test('offers different publishers and ranks the fastest when requested', () {
    final choices = pick(StarterUse.chat, 3, 4e9.toInt());
    expect(
        choices.map((choice) => choice.model.name).join(' '),
        allOf(contains('LFM'), contains('Gemma'), contains('Llama'),
            contains('SmolLM')));
    expect(pick(StarterUse.chat, 3, 4e9.toInt(), speed: true).first.model.name,
        'SmolLM2 360M');
    expect(pick(StarterUse.learn, 5, 4e9.toInt()).first.model.name,
        startsWith('Phi'));
  });

  test('offers only compatible vision candidates for camera use', () {
    final choices = pick(StarterUse.camera, 5, 4e9.toInt());
    expect(choices.length, 3);
    expect(choices.every((choice) => choice.model.hasVisionProjector), isTrue);
    expect(pick(StarterUse.camera, 1.9, 4e9.toInt()), isEmpty);
  });
}
