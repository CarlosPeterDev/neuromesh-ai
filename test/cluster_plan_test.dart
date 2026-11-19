import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/cluster_plan.dart';

void main() {
  test('caps a device at its capacity and redistributes the remaining load',
      () {
    final shares = distributeClusterLoad([
      (capacity: 100.0, weight: 80.0),
      (capacity: 500.0, weight: 20.0),
      (capacity: 900.0, weight: 0.0),
    ], 400);
    expect(shares, [100, 300, 0]);
  });

  test('manual weights set the ratio when every device has enough memory', () {
    final shares = distributeClusterLoad([
      (capacity: 1000.0, weight: 30.0),
      (capacity: 1000.0, weight: 70.0),
    ], 800);
    expect(shares, [240, 560]);
  });

  test('does not use excluded memory to make an oversized model fit', () {
    expect(
      distributeClusterLoad([
        (capacity: 100.0, weight: 1.0),
        (capacity: 500.0, weight: 0.0),
      ], 200),
      isNull,
    );
  });
}
