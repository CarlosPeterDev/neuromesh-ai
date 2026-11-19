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

/// Estimates sequential layer time from memory bandwidth and the fixed RPC
/// cost of adding a device. Probes measure reachability and connection latency,
/// while advertised bandwidth is a memory benchmark, not generation speed.
List<double> placeSequentialLayers(
    List<({double capacityMb, double bandwidthGbps, double latencyMs})> phones,
    double requiredMb) {
  if (phones.isEmpty) return [];
  List<double>? best;
  var bestCost = double.infinity;
  final bySpeed = List.generate(phones.length, (i) => i)
    ..sort(
        (a, b) => phones[b].bandwidthGbps.compareTo(phones[a].bandwidthGbps));

  void compare(List<int> devices) {
    final shares = List<double>.filled(phones.length, 0);
    var remaining = requiredMb;
    var cost = 0.0;
    for (final index in devices) {
      final p = phones[index];
      final share = math.min(remaining, p.capacityMb);
      if (share <= 0) continue;
      shares[index] = share;
      remaining -= share;
      // MB / GB per second approximates milliseconds. Include a small fixed
      // network penalty even when a TCP probe completed below clock resolution.
      cost += share / math.max(p.bandwidthGbps, 0.5);
      if (index != 0) cost += math.max(p.latencyMs * 4, 4);
    }
    if (remaining <= 1e-6 && cost < bestCost) {
      best = shares;
      bestCost = cost;
    }
  }

  // Check all worker combinations for small clusters. Larger clusters use
  // device prefixes to keep planning time bounded.
  if (phones.length <= 9) {
    for (var mask = 0; mask < (1 << (phones.length - 1)); mask++) {
      compare([
        for (final index in bySpeed)
          if (index == 0 || (mask & (1 << (index - 1))) != 0) index,
      ]);
    }
  } else {
    for (var count = 1; count <= bySpeed.length; count++) {
      compare(bySpeed.take(count).toList());
    }
  }
  return best ?? List<double>.filled(phones.length, 0);
}
