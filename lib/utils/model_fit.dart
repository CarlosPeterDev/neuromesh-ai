import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/constants.dart';
import '../services/cluster_service.dart';
import '../services/device_info_service.dart';
import '../services/hive_service.dart';

/// How well a model fits this phone's memory.
enum ModelFit { recommended, fits, heavy, tooBig, unknown }

double deviceRamGB() => Get.isRegistered<DeviceInfoService>()
    ? Get.find<DeviceInfoService>().totalRamGB.value
    : 0;

/// Memory (GB) the models can use: this phone's RAM, plus what the connected
/// workers offer when this phone is a cluster master (workers report their
/// free RAM at start; ~75% of it is usable, like the cluster planner assumes).
double availableMemoryGB() {
  var ram = deviceRamGB();
  if (Get.isRegistered<ClusterService>()) {
    final c = Get.find<ClusterService>();
    if (c.role == ClusterRole.master) {
      for (final w in c.workers) {
        ram += (w.ramMb ?? 2000) / 1024 * 0.75;
      }
    }
  }
  return ram;
}

/// Extra GB the attention cache needs at the user's context size.
/// Heuristic: ~0.0005 GB (0.5 MB) per context token for a ~4 GB (7B-class)
/// model, scaled down for smaller weights (clamped 0.15x to 1.5x).
double contextHeadroomGB(double weightsGB) {
  int ctx = 4096;
  if (Get.isRegistered<HiveService>()) {
    final v = Get.find<HiveService>().getSetting<dynamic>(AppConstants.keyContextSize);
    if (v is num && v > 0) ctx = v.toInt();
  }
  final scale = (weightsGB / 4).clamp(0.15, 1.5).toDouble();
  // 4096 tokens is already covered by the fixed overhead in needGBForBytes.
  final extraTokens = ctx > 4096 ? ctx - 4096 : 0;
  return extraTokens * 0.0005 * scale;
}

/// RAM a GGUF file of [bytes] needs when loaded (weights + cache + overhead).
double needGBForBytes(int bytes) => bytes / 1073741824 * 1.15 + 0.5;

/// Fit of a model needing [needGB] against [ramGB] (default: this phone plus
/// cluster workers). A larger context size adds headroom. "Recommended" is
/// only given when the model uses at most 40% of the memory, so huge models
/// never get it.
ModelFit fitFor(double needGB, [double? ramGB]) {
  final ram = ramGB ?? availableMemoryGB();
  if (ram <= 0 || needGB <= 0) return ModelFit.unknown;
  final need = needGB + contextHeadroomGB(needGB);
  if (need <= ram * 0.4) return ModelFit.recommended;
  if (need <= ram * 0.6) return ModelFit.fits;
  if (need <= ram * 0.8) return ModelFit.heavy;
  return ModelFit.tooBig;
}

String fitText(ModelFit f) => switch (f) {
      ModelFit.recommended => 'Recommended',
      ModelFit.fits => 'Fits',
      ModelFit.heavy => 'Heavy',
      ModelFit.tooBig => 'Out of memory',
      ModelFit.unknown => '',
    };

Color fitColor(ModelFit f) => switch (f) {
      ModelFit.recommended => const Color(0xFF2E9E5B),
      ModelFit.fits => const Color(0xFF3B82C4),
      ModelFit.heavy => const Color(0xFFD08A1E),
      ModelFit.tooBig => const Color(0xFFD64545),
      ModelFit.unknown => Colors.grey,
    };

/// Small coloured pill: Recommended / Fits / Heavy / Out of memory.
class FitBadge extends StatelessWidget {
  final ModelFit fit;
  const FitBadge(this.fit, {super.key});

  @override
  Widget build(BuildContext context) {
    if (fit == ModelFit.unknown) return const SizedBox.shrink();
    final c = fitColor(fit);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(fitText(fit),
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c)),
    );
  }
}
