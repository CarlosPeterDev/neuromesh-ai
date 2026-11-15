import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:timezone/timezone.dart' as tz;

import '../controllers/chat_controller.dart';
import '../controllers/model_controller.dart';
import 'hive_service.dart';
import 'inference_service.dart';

/// A prompt the app runs by itself at a set time, like a local "Spark".
class ScheduledTask {
  final String id;
  String title;
  String prompt;

  /// once | daily | weekly | every
  String kind;
  int hour;
  int minute;
  List<int> days; // 1 = Monday … 7 = Sunday
  int everyMin;
  int onceAt; // epoch ms
  bool enabled;
  int lastRun; // epoch ms, 0 = never
  String lastResult;
  int anchor; // epoch ms the task was created

  ScheduledTask({
    required this.id,
    required this.title,
    required this.prompt,
    this.kind = 'daily',
    this.hour = 8,
    this.minute = 0,
    List<int>? days,
    this.everyMin = 60,
    this.onceAt = 0,
    this.enabled = true,
    this.lastRun = 0,
    this.lastResult = '',
    int? anchor,
  })  : days = days ?? [1, 2, 3, 4, 5, 6, 7],
        anchor = anchor ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'prompt': prompt,
        'kind': kind,
        'hour': hour,
        'minute': minute,
        'days': days,
        'everyMin': everyMin,
        'onceAt': onceAt,
        'enabled': enabled,
        'lastRun': lastRun,
        'lastResult': lastResult,
        'anchor': anchor,
      };

  factory ScheduledTask.fromMap(Map m) => ScheduledTask(
        id: '${m['id']}',
        title: '${m['title'] ?? ''}',
        prompt: '${m['prompt'] ?? ''}',
        kind: '${m['kind'] ?? 'daily'}',
        hour: (m['hour'] as num?)?.toInt() ?? 8,
        minute: (m['minute'] as num?)?.toInt() ?? 0,
        days: (m['days'] as List?)?.map((e) => (e as num).toInt()).toList(),
        everyMin: (m['everyMin'] as num?)?.toInt() ?? 60,
        onceAt: (m['onceAt'] as num?)?.toInt() ?? 0,
        enabled: m['enabled'] != false,
        lastRun: (m['lastRun'] as num?)?.toInt() ?? 0,
        lastResult: '${m['lastResult'] ?? ''}',
        anchor: (m['anchor'] as num?)?.toInt(),
      );

  /// The next time this should run, or null if it never will again.
  DateTime? nextRun() {
    final from = DateTime.fromMillisecondsSinceEpoch(lastRun > anchor ? lastRun : anchor);
    switch (kind) {
      case 'once':
        return lastRun > 0 ? null : DateTime.fromMillisecondsSinceEpoch(onceAt);
      case 'every':
        return from.add(Duration(minutes: everyMin < 1 ? 1 : everyMin));
      case 'weekly':
      case 'daily':
        final allowed = kind == 'daily' ? [1, 2, 3, 4, 5, 6, 7] : days;
        if (allowed.isEmpty) return null;
        for (var i = 0; i < 9; i++) {
          final d = DateTime(from.year, from.month, from.day + i, hour, minute);
          if (d.isAfter(from) && allowed.contains(d.weekday)) return d;
        }
        return null;
    }
    return null;
  }

  String get whenText {
    String two(int n) => n.toString().padLeft(2, '0');
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    switch (kind) {
      case 'once':
        final d = DateTime.fromMillisecondsSinceEpoch(onceAt);
        return 'Once, ${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
      case 'every':
        return everyMin % 60 == 0 && everyMin >= 60
            ? 'Every ${everyMin ~/ 60} h'
            : 'Every $everyMin min';
      case 'weekly':
        final ds = [...days]..sort();
        return '${ds.map((d) => names[d - 1]).join(', ')} at ${two(hour)}:${two(minute)}';
      default:
        return 'Every day at ${two(hour)}:${two(minute)}';
    }
  }
}

/// Parses short phrases the AI uses: "daily 08:00", "in 30 minutes",
/// "every 2 hours", "weekly mon,thu 09:00", "once 2026-12-01 18:30".
ScheduledTask? parseWhen(String when, {required String id, required String title, required String prompt}) {
  final w = when.toLowerCase().trim();
  final time = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(w);
  final h = time == null ? 8 : int.parse(time.group(1)!).clamp(0, 23);
  final m = time == null ? 0 : int.parse(time.group(2)!).clamp(0, 59);
  final inM = RegExp(r'in\s+(\d+)\s*(min|minute|minutes|h|hour|hours)').firstMatch(w);
  if (inM != null) {
    final n = int.parse(inM.group(1)!);
    final mins = inM.group(2)!.startsWith('h') ? n * 60 : n;
    return ScheduledTask(
        id: id,
        title: title,
        prompt: prompt,
        kind: 'once',
        onceAt: DateTime.now().add(Duration(minutes: mins)).millisecondsSinceEpoch);
  }
  final ev = RegExp(r'every\s+(\d+)\s*(min|minute|minutes|h|hour|hours)').firstMatch(w);
  if (ev != null) {
    final n = int.parse(ev.group(1)!);
    final mins = ev.group(2)!.startsWith('h') ? n * 60 : n;
    return ScheduledTask(id: id, title: title, prompt: prompt, kind: 'every', everyMin: mins < 1 ? 1 : mins);
  }
  final date = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(w);
  if (date != null) {
    final d = DateTime(int.parse(date.group(1)!), int.parse(date.group(2)!),
        int.parse(date.group(3)!), h, m);
    return ScheduledTask(
        id: id, title: title, prompt: prompt, kind: 'once', onceAt: d.millisecondsSinceEpoch);
  }
  const names = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  final days = <int>[
    for (var i = 0; i < 7; i++)
      if (w.contains(names[i])) i + 1
  ];
  if (w.contains('week') || days.isNotEmpty) {
    return ScheduledTask(
        id: id,
        title: title,
        prompt: prompt,
        kind: 'weekly',
        hour: h,
        minute: m,
        days: days.isEmpty ? [DateTime.now().weekday] : days);
  }
  if (w.contains('daily') || w.contains('every day') || time != null) {
    return ScheduledTask(id: id, title: title, prompt: prompt, kind: 'daily', hour: h, minute: m);
  }
  return null;
}

class SchedulerService extends GetxService with WidgetsBindingObserver {
  static const _key = 'scheduled_tasks';
  static const _channel = 'scheduled_tasks';

  final tasks = <ScheduledTask>[].obs;
  final running = ''.obs; // id of the task running now
  final _notes = FlutterLocalNotificationsPlugin();
  Timer? _timer;
  bool _busy = false;

  HiveService get _hive => Get.find<HiveService>();

  @override
  void onInit() {
    super.onInit();
    final raw = _hive.getSetting<List>(_key) ?? const [];
    tasks.value = [for (final e in raw) if (e is Map) ScheduledTask.fromMap(e)];
    if (kIsWeb) return;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => checkDue());
    unawaited(_initNotifications().then((_) => _reschedule()));
    Future.delayed(const Duration(seconds: 6), checkDue);
  }

  @override
  void onClose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) checkDue();
  }

  Future<void> _initNotifications() async {
    try {
      await _notes.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (_) => checkDue(),
      );
      await _notes
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
              _channel, 'Scheduled tasks',
              description: 'Reminders and results for tasks you scheduled',
              importance: Importance.defaultImportance));
    } catch (_) {}
  }

  void _save() {
    _hive.setSetting(_key, [for (final t in tasks) t.toMap()]);
    tasks.refresh();
    unawaited(_reschedule());
  }

  void upsert(ScheduledTask t) {
    final i = tasks.indexWhere((x) => x.id == t.id);
    if (i >= 0) {
      tasks[i] = t;
    } else {
      tasks.add(t);
    }
    _save();
  }

  void remove(String id) {
    tasks.removeWhere((t) => t.id == id);
    _save();
  }

  void setEnabled(String id, bool v) {
    final t = tasks.firstWhereOrNull((x) => x.id == id);
    if (t == null) return;
    t.enabled = v;
    if (v) t.anchor = DateTime.now().millisecondsSinceEpoch;
    _save();
  }

  /// Phone-level reminder at the next run time, so you are told even when the
  /// app is closed (tap it and the task runs).
  Future<void> _reschedule() async {
    try {
      await _notes.cancelAll();
      for (final t in tasks.where((t) => t.enabled)) {
        final n = t.nextRun();
        if (n == null || !n.isAfter(DateTime.now())) continue;
        await _notes.zonedSchedule(
          t.id.hashCode & 0x7fffffff,
          t.title,
          'Scheduled task is ready. Tap to run it.',
          tz.TZDateTime.from(n, tz.UTC),
          const NotificationDetails(
              android: AndroidNotificationDetails(_channel, 'Scheduled tasks')),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    } catch (_) {}
  }

  Future<void> checkDue() async {
    if (_busy || kIsWeb) return;
    final now = DateTime.now();
    for (final t in List.of(tasks.where((t) => t.enabled))) {
      final n = t.nextRun();
      if (n == null || n.isAfter(now)) continue;
      // A recurring task missed by more than 12 h is skipped, not replayed.
      if (t.kind != 'once' && now.difference(n).inHours >= 12) {
        t.lastRun = now.millisecondsSinceEpoch;
        _save();
        continue;
      }
      await runNow(t);
      return; // one at a time; the next tick handles the rest
    }
  }

  Future<void> runNow(ScheduledTask t) async {
    if (_busy) return;
    if (!Get.isRegistered<ChatController>()) return;
    final chat = Get.find<ChatController>();
    if (chat.isLoading.value || chat.isStreaming.value) return; // try later
    _busy = true;
    running.value = t.id;
    var result = '';
    try {
      final inf = Get.find<InferenceService>();
      if (!inf.isModelLoaded.value) {
        final mc = Get.find<ModelController>();
        if (mc.canLoadLastModel) {
          await mc.loadModel(mc.lastLoadedModelName);
          for (var i = 0; i < 240 && inf.isLoadingModel.value; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      }
      if (!inf.isModelLoaded.value) {
        result = 'Could not run: no chat model is loaded.';
      } else {
        chat.createNewChat();
        chat.textController.text = t.prompt;
        await chat.sendMessage();
        for (var i = 0; i < 1800; i++) {
          if (!chat.isLoading.value && !chat.isStreaming.value) break;
          await Future.delayed(const Duration(milliseconds: 500));
        }
        final last = chat.messages.toList().reversed.firstWhereOrNull((m) => m.role == 'assistant');
        result = last?.content ?? '';
        result = result.split('\n').where((l) => !l.startsWith('> 🔧')).join('\n').trim();
      }
    } catch (e) {
      result = 'Failed: $e';
    } finally {
      t.lastRun = DateTime.now().millisecondsSinceEpoch;
      t.lastResult = result;
      running.value = '';
      _busy = false;
      _save();
    }
    try {
      await _notes.show(
        (t.id.hashCode + 1) & 0x7fffffff,
        '${t.title} — done',
        result.length > 140 ? '${result.substring(0, 140)}…' : result,
        const NotificationDetails(android: AndroidNotificationDetails(_channel, 'Scheduled tasks')),
      );
    } catch (_) {}
  }
}
