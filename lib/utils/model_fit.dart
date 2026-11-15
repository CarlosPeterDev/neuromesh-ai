import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/device_info_service.dart';

/// How well a model fits this phone's memory.
enum ModelFit { recommended, fits, heavy, tooBig, unknown }

double deviceRamGB() => Get.isRegistered<DeviceInfoService>()
    ? Get.find<DeviceInfoService>().totalRamGB.value
    : 0;

/// RAM a GGUF file of [bytes] needs when loaded (weights + cache + overhead).
double needGBForBytes(int bytes) => bytes / 1073741824 * 1.15 + 0.5;

ModelFit fitFor(double needGB, [double? ramGB]) {
  final ram = ramGB ?? deviceRamGB();
  if (ram <= 0 || needGB <= 0) return ModelFit.unknown;
  if (needGB <= ram * 0.4) return ModelFit.recommended;
  if (needGB <= ram * 0.6) return ModelFit.fits;
  if (needGB <= ram * 0.8) return ModelFit.heavy;
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
