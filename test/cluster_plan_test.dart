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
  test('a high-latency worker is skipped when faster placement can fit', () {
    final shares = placeSequentialLayers([
      (capacityMb: 650.0, bandwidthGbps: 5.0, latencyMs: 0.0),
      (capacityMb: 500.0, bandwidthGbps: 8.0, latencyMs: 3.0),
      (capacityMb: 300.0, bandwidthGbps: 30.0, latencyMs: 90.0),
    ], 1000);
    expect(shares, [500.0, 500.0, 0.0]);
  });
}
