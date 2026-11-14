import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/auto_context.dart';

void main() {
  const gb = 1024 * 1024 * 1024;
  test('never raises the requested size', () {
    expect(autoContextSize(requested: 2048, availableGb: 12, modelBytes: gb), 2048);
  });
  test('lowers when memory is tight', () {
    final c = autoContextSize(requested: 8192, availableGb: 3, modelBytes: 2 * gb);
    expect(c, lessThan(8192));
    expect(c, greaterThanOrEqualTo(512));
  });
  test('floors at minimum when model barely fits', () {
    expect(autoContextSize(requested: 4096, availableGb: 2, modelBytes: 2 * gb), 512);
  });
  test('unknown inputs keep the request', () {
    expect(autoContextSize(requested: 4096, availableGb: 0, modelBytes: gb), 4096);
  });
}
