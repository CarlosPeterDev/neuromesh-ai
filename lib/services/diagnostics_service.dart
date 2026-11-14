import 'dart:io';

import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/chat_io.dart';
import 'app_log_service.dart';
import 'device_bridge.dart';
import 'device_info_service.dart';
import 'inference_service.dart';

class DiagnosticsService {
  static const repoIssues =
      'https://github.com/carlospeter582011-prog/neuromesh-ai/issues/new';

  static Future<String> buildReport({String note = ''}) async {
    final info = await PackageInfo.fromPlatform();
    final b = StringBuffer()
      ..writeln('NeuroMesh AI diagnostic report')
      ..writeln('Version: ${info.version}+${info.buildNumber}')
      ..writeln('OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    if (Get.isRegistered<DeviceInfoService>()) {
      b.writeln('RAM: ${Get.find<DeviceInfoService>().totalRamGB.value.toStringAsFixed(1)} GB');
    }
    if (Get.isRegistered<InferenceService>()) {
      final inf = Get.find<InferenceService>();
      b.writeln('Model loaded: ${inf.isModelLoaded.value ? inf.loadedModelName.value : 'none'}');
    }
    if (Get.isRegistered<DeviceBridge>()) {
      final d = Get.find<DeviceBridge>();
      b.writeln('Battery: ${d.batteryLevel.value}% charging=${d.charging.value} thermal=${d.thermal.value}');
    }
    if (note.trim().isNotEmpty) b..writeln()..writeln('Note: ${note.trim()}');
    b..writeln()..writeln('--- Recent log (secrets removed) ---');
    if (Get.isRegistered<AppLogService>()) {
      final entries = Get.find<AppLogService>().entries.take(80).toList();
      for (final e in entries.reversed) {
        b.writeln(sanitizeLog(e.format()));
      }
    }
    return b.toString();
  }

  static Future<void> shareReport({String note = ''}) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/neuromesh-diagnostics.txt');
    await f.writeAsString(await buildReport(note: note));
    await Share.shareXFiles([XFile(f.path)]);
  }

  /// Opens a prefilled GitHub issue form. No account is needed to prepare it.
  static Future<bool> openIssueDraft(String description) async {
    final report = await buildReport();
    // URLs have a length limit; keep the tail of the log out of the link.
    final body = '$description\n\n```\n${report.length > 3000 ? report.substring(0, 3000) : report}\n```';
    final uri = Uri.parse(repoIssues).replace(queryParameters: {
      'title': 'Feedback',
      'body': body,
    });
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
