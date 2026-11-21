import 'dart:io';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The relay previously depended on the removed local-image notification
/// service for its foreground isolate. Configure it explicitly when enabled.
Future<void> configureRelayBackgroundService() async {
  if (!Platform.isAndroid) return;
  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher')));
  await notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
          'remote_access', 'Remote access',
          description: 'Keeps user-enabled remote access running',
          importance: Importance.low));
  await FlutterBackgroundService().configure(
      androidConfiguration: AndroidConfiguration(
          onStart: relayBackgroundStart,
          autoStart: false,
          autoStartOnBoot: false,
          isForegroundMode: true,
          notificationChannelId: 'remote_access',
          initialNotificationTitle: 'Remote access is on',
          initialNotificationContent:
              'NeuroMesh is connected to your configured relay.',
          foregroundServiceNotificationId: 4202,
          foregroundServiceTypes: const [AndroidForegroundType.dataSync]),
      iosConfiguration: IosConfiguration(autoStart: false));
}

@pragma('vm:entry-point')
void relayBackgroundStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    service.on('progress').listen((event) =>
        service.setForegroundNotificationInfo(
            title: event?['title'] as String? ?? 'Remote access is on',
            content: event?['content'] as String? ??
                'NeuroMesh remote access is enabled.'));
  }
  service.on('forceStop').listen((_) => service.stopSelf());
}
