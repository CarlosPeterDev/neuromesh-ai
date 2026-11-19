import 'dart:math' as math;

enum ClusterProfile { automatic, speed, context, capacity, manual }

/// Distributes a memory budget by relative weight, spilling a capped device's
/// share onto the remaining devices. Zero-weight devices receive no layers.
List<double>? distributeClusterLoad(
    List<({double capacity, double weight})> devices, double requiredMb) {
  final shares = List<double>.filled(devices.length, 0);
  var open = [
    for (var i = 0; i < devices.length; i++)
      if (devices[i].weight > 0 && devices[i].capacity > 0) i,
  ];
  final capacity = open.fold<double>(0, (sum, i) => sum + devices[i].capacity);
  if (capacity < requiredMb) return null;
  var remaining = requiredMb;
  while (open.isNotEmpty && remaining > 0) {
    final weight = open.fold<double>(0, (sum, i) => sum + devices[i].weight);
    final capped = open
        .where((i) =>
            remaining * devices[i].weight / weight >= devices[i].capacity)
        .toList();
    if (capped.isEmpty) {
      for (final i in open) {
        shares[i] = math.min(
            devices[i].capacity, remaining * devices[i].weight / weight);
      }
      break;
    }
    for (final i in capped) {
      shares[i] = devices[i].capacity;
      remaining -= shares[i];
    }
    open = open.where((i) => !capped.contains(i)).toList();
  }
  return shares;
}
