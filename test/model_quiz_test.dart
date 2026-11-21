import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/views/model_quiz_view.dart';

void main() {
  test('recommends the larger coder only when memory and storage fit', () {
    StarterChoice? pick(double ram, int storage, {bool speed = false}) =>
        recommendStarter(
          use: StarterUse.code,
          preferSpeed: speed,
          availableRam: ram,
          totalRam: 6,
          freeBytes: storage,
        );
    expect(pick(3, 4000000000)?.model.name, 'Qwen 2.5 Coder 1.5B');
    expect(pick(1.2, 4000000000)?.model.name, 'Qwen 2.5 Coder 0.5B');
    expect(pick(3, 800000000)?.model.name, 'Qwen 2.5 Coder 0.5B');
    expect(pick(3, 4000000000, speed: true)?.model.name, 'Qwen 2.5 Coder 0.5B');
    expect(pick(3, 400000000), isNull);
  });

  test('only recommends a vision model when the camera requirements fit', () {
    StarterChoice? pick(double ram) => recommendStarter(
          use: StarterUse.camera,
          preferSpeed: true,
          availableRam: ram,
          totalRam: 4,
          freeBytes: 2000000000,
        );
    expect(pick(3)?.model.hasVisionProjector, isTrue);
    expect(pick(1.9), isNull);
  });
}
