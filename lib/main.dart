import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
// import 'firebase_options.dart';
import 'controllers/settings_controller.dart';
import 'controllers/cloud_model_controller.dart';
import 'controllers/server_controller.dart';
import 'controllers/model_controller.dart';
import 'core/theme.dart';
//////
import 'core/routes.dart';
import 'views/home_view.dart' show homeRouteObserver;
import 'widgets/startup_gate.dart';
import 'services/chat_tool_service.dart';
import 'services/chat_voice_tools.dart' show registerVoiceModelStatus;
import 'services/skills_service.dart';
import 'services/toolbox_service.dart';
import 'services/rag_service.dart';
import 'services/favorites_service.dart';
import 'services/memory_service.dart';
import 'services/web_search_service.dart';
import 'services/device_bridge.dart';
import 'services/relay_service.dart';
import 'services/download_queue.dart';
import 'services/voice_models.dart';
import 'services/voice_service.dart';
import 'services/voice_clone_store.dart';
import 'services/voice_worker.dart';
import 'services/hive_service.dart';
import 'services/inference_service.dart';
import 'services/cluster_service.dart';
import 'services/cloud_service.dart';
import 'services/download_service.dart';
import 'services/update_service.dart';
import 'services/device_info_service.dart';
import 'services/local_image_service.dart';
import 'services/app_log_service.dart';
import 'services/crash_reporting_service.dart';
import 'services/image_generation_notification_service.dart';
import 'core/constants.dart';

void main() {
  final appLogBuffer = <String>[];

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Register logger first so everything routes to it
    final appLog = AppLogService();
    Get.put(appLog);

    // Flush buffered prints
    for (final line in appLogBuffer) {
      appLog.info(line);
    }
    appLogBuffer.clear();

    appLog.info('App started');

    // Initialize Firebase before any Firebase-dependent services
    try {
      // await Firebase.initializeApp(
      //   options: DefaultFirebaseOptions.currentPlatform,
      // );
    } catch (e) {
      appLog.error('[Firebase] Initialization failed', details: e);
    }

    // Support phones and tablets in portrait or landscape.
    if (!kIsWeb) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    runApp(StartupGate(
      openStorage: () async {
        await Hive.initFlutter();
        await Get.putAsync(() => HiveService().init(), permanent: true);
      },
      startApp: () async {
        await Get.putAsync(() => DeviceInfoService().init().timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                appLog.warning('Device information timed out');
                return DeviceInfoService();
              },
            ));
        await _autoConfigureForDevice();
        Get.put(SettingsController());
        Get.put(CloudModelController());

        if (ClusterService.isSupported)
          Get.put(ClusterService(), permanent: true);
        Get.put(InferenceService());
        Get.put(ChatToolService());
        registerVoiceModelStatus(Get.find<ChatToolService>());
        final skills = await Get.putAsync(() => SkillsService().init());
        skills.registerTools(Get.find<ChatToolService>());
        Get.put(ToolboxService());
        Get.put(RagService());
        Get.put(FavoritesService(), permanent: true);
        MemoryService.ensure();
        Get.put(WebSearchService());
        Get.put(DeviceBridge(), permanent: true);
        Get.put(VoiceModelStore(), permanent: true);
        Get.put(VoiceService(), permanent: true);
        Get.put(VoiceCloneStore(), permanent: true);
        Get.put(VoiceWorkerServer(), permanent: true);
        Get.put(CloudService());
        Get.put(DownloadService());
        if (UpdateService.isSupported)
          Get.put(UpdateService(), permanent: true);
        Get.put(LocalImageService());
        final crashReporting =
            await Get.putAsync(() => CrashReportingService().init().timeout(
                  const Duration(seconds: 10),
                  onTimeout: () {
                    appLog.error('CrashReportingService.init timed out');
                    return CrashReportingService();
                  },
                ));
        FlutterError.onError = (details) {
          FlutterError.presentError(details);
          appLog.error(
            details.exceptionAsString(),
            details: details.stack?.toString() ?? 'No stack',
          );
          crashReporting.recordFlutterFatal(details);
        };
        PlatformDispatcher.instance.onError = (error, stack) {
          appLog.error(
            error.toString(),
            details: stack.toString(),
          );
          crashReporting.recordFatal(error, stack,
              reason: 'platform_dispatcher');
          return true;
        };
        final imageNotifications =
            Get.put(ImageGenerationNotificationService());
        try {
          await imageNotifications.init();
          await imageNotifications.configureBackgroundService();
        } catch (e) {
          appLog.error('[Notifications] Init failed', details: e);
        }
        appLog.info('Notifications initialized');
        Get.put(ServerController(), permanent: true);
        Get.put(RelayService(), permanent: true);
        Get.put(ModelController());
        Get.put(DownloadQueue(), permanent: true);
        appLog.info('All services initialized, launching app');

        // Keep last model as a quick-load option, but do not auto-load on startup.
        _validateLastModel();

        return const NeuroMeshApp();
      },
      onError: (error, stack) =>
          appLog.error('Application startup failed', details: error),
    ));
  }, (error, stack) async {
    if (Get.isRegistered<AppLogService>()) {
      Get.find<AppLogService>().error(
        'Uncaught zone error: $error',
        details: stack.toString(),
      );
    }
    if (Get.isRegistered<CrashReportingService>()) {
      await Get.find<CrashReportingService>()
          .recordFatal(error, stack, reason: 'run_zoned_guarded');
    }
  }, zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {
      if (Get.isRegistered<AppLogService>()) {
        Get.find<AppLogService>().info(line);
      } else {
        appLogBuffer.add(line);
      }
      parent.print(zone, line);
    },
  ));
}

/// Validates that remembered models still exist on disk.
/// Does NOT auto-load — the HomeView will ask the user on first launch.
void _validateLastModel() async {
  final hive = Get.find<HiveService>();
  final downloadService = Get.find<DownloadService>();

  // Validate last text/LLM model
  final textModelName = hive.getSetting<String>(AppConstants.keyLocalModelName);
  final textModelPath = hive.getSetting<String>(AppConstants.keyLocalModelPath);
  if (textModelName != null &&
      textModelName.isNotEmpty &&
      textModelPath != null &&
      textModelPath.isNotEmpty) {
    if (!await downloadService.isModelDownloaded(textModelName)) {
      await hive.setSetting(AppConstants.keyLocalModelPath, '');
      await hive.setSetting(AppConstants.keyLocalModelName, '');
    }
  }

  // Validate last image model
  final imageModelName =
      hive.getSetting<String>(AppConstants.keyImageModelName);
  final imageModelPath =
      hive.getSetting<String>(AppConstants.keyImageModelPath);
  if (imageModelName != null &&
      imageModelName.isNotEmpty &&
      imageModelPath != null &&
      imageModelPath.isNotEmpty) {
    if (!await downloadService.isModelDownloaded(imageModelName)) {
      await hive.setSetting(AppConstants.keyImageModelPath, '');
      await hive.setSetting(AppConstants.keyImageModelName, '');
    }
  }
}

/// Auto-set optimized inference params based on device RAM (only on first launch).
Future<void> _autoConfigureForDevice() async {
  final hive = Get.find<HiveService>();
  final device = Get.find<DeviceInfoService>();

  // Only auto-configure if user hasn't already set values (first launch)
  final hasConfigured =
      hive.getSetting<bool>('device_auto_configured') ?? false;
  if (hasConfigured) return;

  final defaults = {
    AppConstants.keyContextSize: device.recommendedContextSize,
    AppConstants.keyMaxTokens: device.recommendedMaxTokens,
    AppConstants.keyTemperature: 0.3,
  };
  await hive.settingsBox.putAll({
    for (final entry in defaults.entries)
      if (!hive.settingsBox.containsKey(entry.key)) entry.key: entry.value,
    'device_auto_configured': true,
  });

  Get.find<AppLogService>().info(
      '[AutoConfig] Set context=${device.recommendedContextSize}, '
      'maxTokens=${device.recommendedMaxTokens} for ${device.totalRamGB.value.toStringAsFixed(1)}GB RAM');
}

class NeuroMeshApp extends StatelessWidget {
  const NeuroMeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();
    return Obx(() {
      final themeMode = settings.themeMode.value;
      final scale = settings.fontScale.value; // read here → Obx tracks it
      return GetMaterialApp(
        navigatorObservers: [homeRouteObserver],
        title: 'NeuroMesh AI',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: themeMode,
        initialRoute: AppRoutes.home,
        getPages: AppPages.pages,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
      );
    });
  }
}
