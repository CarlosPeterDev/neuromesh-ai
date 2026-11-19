import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../ffi/sd_ffi_bindings.dart';
import '../core/redact.dart';
import '../core/build_flavor.dart';
import 'app_log_service.dart';
import 'device_bridge.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'local_image_service.dart';
import 'model_load_diagnostics.dart';
import 'telegram_report_delivery.dart';

class DiagnosticsService {
  static const repoIssues =
      'https://github.com/carlospeter582011-prog/neuromesh-ai/issues/new';

  static Future<String> buildReport({bool includeRecentErrors = false}) async {
    final report = StringBuffer()
      ..writeln('NeuroMesh AI diagnostic report')
      ..writeln('Report format: 2')
      ..writeln(
          'Build channel: ${kPlayBuild ? 'Google Play' : kProBuild ? 'Pro' : 'Standard'}')
      ..writeln('Created (UTC): ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln(
        'OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('CPU cores: ${Platform.numberOfProcessors}');
    try {
      final info = await PackageInfo.fromPlatform();
      report.writeln('App version: ${info.version}+${info.buildNumber}');
    } catch (_) {
      report.writeln('App version: unavailable');
    }
    if (Platform.isAndroid) {
      try {
        final android = await DeviceInfoPlugin().androidInfo;
        report
          ..writeln('Device: ${android.manufacturer} ${android.model}')
          ..writeln('Android release: ${android.version.release}')
          ..writeln('Android SDK: ${android.version.sdkInt}')
          ..writeln('ABIs: ${android.supportedAbis.join(', ')}')
          ..writeln('Hardware: ${android.hardware}')
          ..writeln('Board: ${android.board}')
          ..writeln('Physical device: ${android.isPhysicalDevice}');
      } catch (_) {
        report.writeln('Android device details: unavailable');
      }
    }
    if (Get.isRegistered<DeviceBridge>()) {
      final status = await Get.find<DeviceBridge>().status().timeout(
            const Duration(seconds: 2),
            onTimeout: () => {},
          );
      for (final (key, label) in [
        ('ramTotal', 'Total RAM (MiB)'),
        ('ramFree', 'Available RAM (MiB)'),
        ('ramLowThreshold', 'Low memory threshold (MiB)'),
        ('storageFree', 'Available storage on app cache volume (MiB)'),
        ('storageTotal', 'App cache volume total (MiB)'),
        ('level', 'Battery (%)'),
        ('thermal', 'Thermal status'),
      ]) {
        final value = status[key];
        if (value is! num || value < 0) continue;
        final display =
            label.endsWith('(MiB)') ? (value / (1024 * 1024)).round() : value;
        report.writeln('$label: $display');
      }
      if (status['lowMemory'] case final bool lowMemory) {
        report.writeln('Android reports memory pressure: $lowMemory');
      }
    }
    if (Get.isRegistered<InferenceService>()) {
      final service = Get.find<InferenceService>();
      report.writeln(
        'Active text model: ${service.isModelLoaded.value ? service.loadedModelName.value : 'none'}',
      );
      if (service.isModelLoaded.value) {
        report
          ..writeln('Text runtime: ${service.loadedModelRuntime.value}')
          ..writeln('Text backend: ${service.loadedBackend.value}')
          ..writeln('GPU layers: ${service.gpuLayersUsed.value}')
          ..writeln('Context size: ${service.contextTokensTotal.value}');
      }
    }
    if (Get.isRegistered<LocalImageService>()) {
      final service = Get.find<LocalImageService>();
      if (service.isModelLoaded.value) {
        report
          ..writeln('Active image model: ${service.loadedModelName.value}')
          ..writeln(
            'Image backend: ${service.currentBackend.value.displayName}',
          );
      }
    }
    if (Get.isRegistered<HiveService>()) {
      final hive = Get.find<HiveService>();
      for (final (title, key) in [
        ('Last model load failure', ModelLoadDiagnostics.failureKey),
        ('Unfinished load checkpoint', ModelLoadDiagnostics.pendingKey),
      ]) {
        final snapshot = hive.getSetting<Map>(key);
        if (snapshot == null) continue;
        report
          ..writeln()
          ..writeln(title);
        if (key == ModelLoadDiagnostics.pendingKey) {
          report.writeln(
            'The load is in progress or the app closed before it completed. The cause is unknown.',
          );
        }
        for (final entry in snapshot.entries) {
          if (entry.key != 'timeline') {
            report.writeln('${entry.key}: ${entry.value}');
          }
        }
        if (snapshot['timeline'] case final List events
            when events.isNotEmpty) {
          report.writeln('Model load timeline (milliseconds since start)');
          for (final event in events.whereType<Map>()) {
            report.writeln('+ ${event['elapsedMs']} ms  ${event['stage']}');
          }
        }
      }
    }
    if (includeRecentErrors && Get.isRegistered<AppLogService>()) {
      final entries = Get.find<AppLogService>()
          .entries
          .where((entry) =>
              entry.isImportant ||
              entry.message.startsWith('[Inference]') ||
              entry.message.startsWith('[LocalImageService]') ||
              entry.message.startsWith('[ModelController]'))
          .take(80)
          .toList();
      report
        ..writeln()
        ..writeln('Recent app errors, warnings and model runtime logs');
      for (final entry in entries.reversed) {
        final line = diagnosticText(entry.format());
        report.writeln(
          line.length <= 2000 ? line : '${line.substring(0, 2000)}…',
        );
      }
    }
    return diagnosticText(report.toString());
  }

  static final Uri? _submissionEndpoint = _parseEndpoint(
    const String.fromEnvironment('NEUROMESH_REPORT_ENDPOINT'),
  );

  static final TelegramReportDelivery? _buildDestination =
      TelegramReportDelivery.parse(
    const String.fromEnvironment('NEUROMESH_REPORT_BOT_TOKEN'),
    const String.fromEnvironment('NEUROMESH_REPORT_CHAT_ID'),
  );

  static bool get canSendReport =>
      _buildDestination != null || _submissionEndpoint != null;
  static const _reportLimit = 256 * 1024;

  static Uri? _parseEndpoint(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasFragment &&
            !uri.hasQuery
        ? uri
        : null;
  }

  static Future<void> sendReport(
    String preview, {
    http.Client? client,
    TelegramReportDelivery? destination,
  }) async {
    final uri = _submissionEndpoint;
    final direct = destination ?? _buildDestination;
    if (uri == null && direct == null) {
      throw const ReportSubmissionError(
          'Report delivery is not configured in this build.');
    }
    final bytes = utf8.encode(preview);
    if (bytes.length > _reportLimit) {
      throw const ReportSubmissionError(
          'This report is too large. Try turning off recent logs.');
    }

    final transport = client ?? http.Client();
    try {
      final response = await (direct != null
              ? direct.send(preview, transport)
              : transport
                  .send(http.Request('POST', uri!)
                    ..followRedirects = false
                    ..headers['Content-Type'] = 'text/plain; charset=utf-8'
                    ..bodyBytes = bytes)
                  .then(http.Response.fromStream))
          .timeout(const Duration(seconds: 25));
      if (response.statusCode == 429) {
        throw const ReportSubmissionError(
            'Too many reports were sent. Try again in a minute.');
      }
      if (response.statusCode == 400 || response.statusCode == 415) {
        throw const ReportSubmissionError(
            'The report service rejected this report format.');
      }
      if (response.statusCode == 413) {
        throw const ReportSubmissionError(
            'This report is too large. Try turning off recent logs.');
      }
      if (response.statusCode == 503) {
        throw const ReportSubmissionError(
            'Support delivery is temporarily unavailable.');
      }
      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        if (result is Map && result['ok'] == true) return;
      }
      throw const ReportSubmissionError(
          'Could not send the report. Try again later.');
    } on ReportSubmissionError {
      rethrow;
    } catch (_) {
      throw const ReportSubmissionError(
          'Delivery could not be confirmed. Check your connection.');
    } finally {
      if (client == null) transport.close();
    }
  }

  /// Opens a public issue draft containing only the description the user wrote.
  static Future<bool> openIssueDraft(String description) {
    final uri = Uri.parse(repoIssues).replace(
      queryParameters: {
        'title': 'Feedback',
        'body': redactSecrets(description),
      },
    );
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class ReportSubmissionError implements Exception {
  const ReportSubmissionError(this.message);

  final String message;
}
