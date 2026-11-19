import 'dart:async';
import 'dart:io' show File, InternetAddressType, NetworkInterface, Platform;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import 'app_log_service.dart';
import 'hive_service.dart';
import 'gguf_metadata.dart';
import '../utils/cluster_plan.dart';
import 'inference_service.dart';
import '../controllers/model_controller.dart';

/// What this phone does in a phone cluster.
enum ClusterRole {
  off,

  /// Runs the model, with part of it on the workers.
  master,

  /// Lends its processor and memory to a master.
  worker,
}

/// One phone's part of the loaded model.
class ClusterShare {
  final String name;
  final double mb;
  final bool isThisPhone;
  const ClusterShare(this.name, this.mb, {this.isThisPhone = false});
}

/// A phone the master can put layers on, for planning a load.
class _Phone {
  final ClusterWorker? worker; // null: the master itself
  final double capacityMb;
  final double speed; // GB/s
  final double roundTripMs;
  double assignedMb = 0;
  _Phone(this.worker, this.capacityMb, this.speed, {this.roundTripMs = 0});
}

/// Phone cluster: spread a GGUF model across phones on the same Wi-Fi.
/// The master runs the model; workers hold part of its layers.
class ClusterService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  static bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Running a model across workers is Android-only for now; iOS devices
  /// can be workers (their GPU serves a master's layers).
  static bool get canBeMaster => !kIsWeb && Platform.isAndroid;

  /// iOS can't stop the worker without closing the app.
  static bool get workerStopsWithApp => !kIsWeb && Platform.isIOS;

  /// QR codes a worker shows: neuromesh://worker?host=…&port=…
  static const _qrScheme = 'neuromesh';

  /// Speed assumed for workers paired before they reported one (GB/s).
  static const _unknownSpeed = 4.0;

  /// Workers the master can use on its next GGUF load.
  final workers = <ClusterWorker>[].obs;

  /// Master mode: use [workers] when loading GGUF models.
  final enabled = false.obs;

  final found = <ClusterWorker>[].obs;
  final profile = ClusterProfile.automatic.obs;
  final loadWeights = <String, int>{}.obs;
  static const localDeviceKey = 'local';

  static String workerKey(ClusterWorker worker) =>
      'worker:${worker.id ?? worker.endpoint}';

  int weightFor(String device) => loadWeights[device] ?? 50;

  Future<void> setLoadProfile(ClusterProfile value) async {
    profile.value = value;
    await _hive.setSetting('cluster_load_profile', value.name);
  }

  Future<void> setLoadWeights(Map<String, int> values) async {
    loadWeights.assignAll(values.map((key, value) => MapEntry(key, value.clamp(0, 100))));
    await _hive.setSetting('cluster_load_weights', Map<String, int>.of(loadWeights));
    await setLoadProfile(ClusterProfile.manual);
  }

  final isScanning = false.obs;

  /// This phone's worker service.
  final worker = const ClusterWorkerStatus(state: 'stopped').obs;
  final _workerRequested = false.obs;

  /// The API server is running (other devices, e.g. a PC, use the model).
  final serving = false.obs;

  /// This phone's Wi-Fi address, or null when it isn't on Wi-Fi.
  final wifiAddress = RxnString();

  /// How the loaded model is spread across phones; empty when it isn't.
  final split = <ClusterShare>[].obs;

  String deviceName = '';
  double? _localSpeed;
  Timer? _statusTimer;

  ClusterRole get role => _workerRequested.value || worker.value.running
      ? ClusterRole.worker
      : enabled.value
          ? ClusterRole.master
          : ClusterRole.off;

  /// "Pixel 8 72% · POCO F1 28%", or null when the model isn't split.
  String? get splitSummary {
    final total = split.fold<double>(0, (a, s) => a + s.mb);
    if (split.length < 2 || total <= 0) return null;
    return split.map((s) => '${s.name} ${(s.mb / total * 100).round()}%').join(' · ');
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value = _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ?? false;
    final saved = _hive.getSetting<List>(AppConstants.keyClusterWorkers) ?? const [];
    workers.assignAll(saved.whereType<Map>().map(ClusterWorker.fromMap));
    final savedProfile = _hive.getSetting<String>('cluster_load_profile');
    profile.value = ClusterProfile.values.firstWhere((value) => value.name == savedProfile,
        orElse: () => ClusterProfile.automatic);
    final weights = _hive.getSetting<Map>('cluster_load_weights') ?? {};
    loadWeights.assignAll({
      for (final entry in weights.entries)
        if (entry.key is String && entry.value is int)
          entry.key as String: (entry.value as int).clamp(0, 100),
    });
    if (isSupported) {
      if (Platform.isIOS) {
        DeviceInfoPlugin().iosInfo.then((info) => deviceName = info.modelName);
      } else {
        DeviceInfoPlugin().androidInfo.then((info) => deviceName = info.model);
      }
      refreshWorkerStatus().then((_) {
        if (worker.value.running) _watchWorker();
      });
      // A worker runs at full speed only while NeuroMesh AI is on screen (it
      // borrows the app's priority), so keep the screen on while sharing.
      ever<ClusterWorkerStatus>(worker, (_) => _updateKeepScreenOn());
      ever<bool>(serving, (_) => _updateKeepScreenOn());
      refreshWifiAddress();
      _startWatchdog();
    }
  }

  @override
  void onClose() {
    _statusTimer?.cancel();
    _watchdog?.cancel();
    super.onClose();
  }

  Timer? _watchdog;
  bool _reloading = false;
  DateTime _lastReload = DateTime.fromMillisecondsSinceEpoch(0);

  /// While a model is split across phones, checks every few seconds that the
  /// helper phones still answer. If one drops out, the model is loaded again
  /// right away with the phones that are left (or on this phone alone), so
  /// the chat does not stay stuck on a half-dead split.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 12), (_) async {
      if (_reloading || !enabled.value || role != ClusterRole.master) return;
      if (split.length < 2) return;
      if (DateTime.now().difference(_lastReload) < const Duration(seconds: 90)) return;
      if (!Get.isRegistered<ModelController>()) return;
      final inference = Get.find<InferenceService>();
      if (inference.isLoadingModel.value || inference.isGenerating.value) return;
      List<ClusterWorker> lost;
      try {
        lost = await relocateWorkers();
      } catch (_) {
        return;
      }
      if (lost.isEmpty) return;
      final file = _hive.getSetting<String>(AppConstants.keyLocalModelName);
      if (file == null || file.isEmpty) return;
      _reloading = true;
      _lastReload = DateTime.now();
      try {
        showToast('Phone cluster',
            '${lost.map((w) => w.model ?? w.name).join(', ')} left. Reloading the model without it…');
        Get.find<AppLogService>().info('Phone cluster: worker lost, reloading $file');
        await Get.find<ModelController>().loadModel(file);
      } catch (e) {
        Get.find<AppLogService>().error('Cluster auto-reload failed', details: e);
      } finally {
        _reloading = false;
      }
    });
  }

  /// Android throttles a phone whose screen is off (slow cores, low CPU
  /// share), so keep it on while this device works for others: as a worker,
  /// or serving the model over the network.
  bool? _screenKeptOn;
  void _updateKeepScreenOn() {
    final s = worker.value;
    final on = s.running || s.starting || serving.value;
    if (on == _screenKeptOn) return;
    _screenKeptOn = on;
    LlamaCluster.setKeepScreenOn(on).catchError((_) {});
  }

  Future<void> setRole(ClusterRole next) async {
    if (next == role) return;
    if (next != ClusterRole.worker && role == ClusterRole.worker) {
      if (workerStopsWithApp) {
        showToast('Still sharing', 'Close NeuroMesh AI to stop sharing this device.');
        return;
      }
      await stopWorker();
    }
    await _setEnabled(next == ClusterRole.master);
    if (next == ClusterRole.worker) await startWorker();
    await refreshWifiAddress();
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  /// What the master scans to add this phone, once the worker is running.
  String? get workerQrData {
    final host = wifiAddress.value;
    final status = worker.value;
    if (host == null || !status.running) return null;
    return Uri(scheme: _qrScheme, host: 'worker', queryParameters: {
      'host': host,
      'port': '${LlamaCluster.defaultPort}',
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (status.ramMb > 0) 'ram': '${status.ramMb}',
      if (status.bandwidth > 0) 'bw': status.bandwidth.toStringAsFixed(1),
      if (status.id != null) 'id': status.id!,
    }).toString();
  }

  Future<void> startWorker() async {
    if (Platform.isAndroid) {
      // Unrestricted battery keeps Android (Samsung especially) from moving
      // the worker to slow cores once it gets busy.
      final status = await LlamaCluster.workerStatus();
      if (!status.batteryUnrestricted) await LlamaCluster.requestBatteryUnrestricted();
    }
    _workerRequested.value = true;
    worker.value = const ClusterWorkerStatus(state: 'starting');
    await LlamaCluster.startWorker();
    _watchWorker();
  }

  Future<void> stopWorker() async {
    _workerRequested.value = false;
    _statusTimer?.cancel();
    await LlamaCluster.stopWorker();
    await Future.delayed(const Duration(milliseconds: 600));
    await refreshWorkerStatus();
  }

  /// Follows the worker service (its own process) while it runs: whether a
  /// master is connected and how much it holds.
  void _watchWorker() {
    _statusTimer?.cancel();
    var checks = 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await refreshWorkerStatus();
      final s = worker.value;
      // Give the service a few seconds to come up before calling it stopped.
      if (!s.running && !s.starting && ++checks > 3) {
        _workerRequested.value = false;
        _statusTimer?.cancel();
      }
    });
  }

  Future<void> refreshWorkerStatus() async {
    try {
      worker.value = await LlamaCluster.workerStatus();
    } catch (e) {
      Get.find<AppLogService>().error('Cluster worker status failed', details: e);
    }
  }

  /// Finds this device's IPv4 address on Wi-Fi (wlan* on Android, en0 on
  /// iOS), if any.
  Future<void> refreshWifiAddress() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final wifi = interfaces.where((i) => i.name.startsWith('wlan') || i.name == 'en0');
      wifiAddress.value = wifi.isEmpty || wifi.first.addresses.isEmpty
          ? null
          : wifi.first.addresses.first.address;
    } catch (_) {
      wifiAddress.value = null;
    }
  }

  // ── Master: workers ────────────────────────────────────────────────────

  /// Adds the worker from a scanned QR code. Returns an error message, or
  /// null on success.
  Future<String?> addFromQr(String data) async {
    final uri = Uri.tryParse(data.trim());
    final params = uri?.queryParameters ?? const {};
    final host = params['host'];
    final port = int.tryParse(params['port'] ?? '');
    if (uri == null || uri.scheme != _qrScheme || host == null || port == null) {
      return 'That isn\'t a NeuroMesh AI worker code';
    }
    return _add(ClusterWorker(
      name: params['name'] ?? host,
      host: host,
      port: port,
      ramMb: int.tryParse(params['ram'] ?? ''),
      bandwidth: double.tryParse(params['bw'] ?? ''),
      model: params['name'],
      id: params['id'],
    ));
  }

  /// Adds a worker by IP ("192.168.1.20" or "192.168.1.20:50052"). Returns
  /// an error message, or null on success.
  Future<String?> addManual(String input) async {
    final text = input.trim();
    if (text.isEmpty) return 'Enter the worker phone\'s IP address';
    final host = text.contains(':') ? text.substring(0, text.lastIndexOf(':')) : text;
    final port = text.contains(':')
        ? int.tryParse(text.substring(text.lastIndexOf(':') + 1))
        : LlamaCluster.defaultPort;
    if (host.isEmpty || port == null) return 'Use the form 192.168.1.20:50052';
    return _add(ClusterWorker(name: host, host: host, port: port));
  }

  Future<String?> addFound(ClusterWorker w) => _add(w);

  /// Finds saved workers that no longer answer at their address (they moved
  /// to another Wi-Fi, a hotspot, or got a new IP) by their device ID on
  /// the network, and updates them. Returns the ones still unreachable.
  final lastWorkerReply = <String, DateTime>{}.obs;
  final unreachableWorkers = <String>{}.obs;

  final _workerRoundTripMs = <String, double>{};

  Future<List<ClusterWorker>> relocateWorkers() async {
    final snapshot = workers.toList();
    final reachable = await Future.wait(snapshot.map((w) async {
      final clock = Stopwatch()..start();
      try {
        if (!await LlamaCluster.probe(w.endpoint)) return false;
        final observed = clock.elapsedMicroseconds / 1000;
        final previous = _workerRoundTripMs[w.endpoint];
        _workerRoundTripMs[w.endpoint] =
            previous == null ? observed : previous * 0.6 + observed * 0.4;
        lastWorkerReply[w.endpoint] = DateTime.now();
        unreachableWorkers.remove(w.endpoint);
        return true;
      } catch (_) {
        return false;
      }
    }));
    final missing = [
      for (var i = 0; i < snapshot.length; i++)
        if (!reachable[i]) snapshot[i],
    ];
    unreachableWorkers.addAll(missing.map((w) => w.endpoint));
    if (missing.isEmpty) return const [];
    final seen = await LlamaCluster.discover();
    var moved = 0;
    final unreachable = <ClusterWorker>[];
    for (final w in missing) {
      final match = seen.firstWhereOrNull((s) => w.id != null && s.id == w.id);
      final i = workers.indexWhere((x) => x.endpoint == w.endpoint);
      if (match == null || match.endpoint == w.endpoint || i < 0) {
        unreachable.add(w);
        continue;
      }
      workers[i] = w.movedTo(match.host, match.port);
      lastWorkerReply.remove(w.endpoint);
      unreachableWorkers.remove(w.endpoint);
      lastWorkerReply[match.endpoint] = DateTime.now();
      moved++;
    }
    if (moved > 0) {
      await _save();
      Get.find<AppLogService>().info('Phone cluster: found $moved worker(s) at a new address');
    }
    return unreachable;
  }

  Future<String?> _add(ClusterWorker worker) async {
    if (!await LlamaCluster.probe(worker.endpoint)) {
      return 'Can\'t reach ${worker.endpoint}. Check that the phone is a worker '
          'and on the same Wi-Fi.';
    }
    workers.removeWhere((w) => w.endpoint == worker.endpoint);
    workers.add(worker);
    lastWorkerReply[worker.endpoint] = DateTime.now();
    unreachableWorkers.remove(worker.endpoint);
    found.removeWhere((w) => w.endpoint == worker.endpoint);
    await _save();
    return null;
  }

  Future<void> remove(ClusterWorker w) async {
    workers.removeWhere((s) => s.endpoint == w.endpoint);
    lastWorkerReply.remove(w.endpoint);
    unreachableWorkers.remove(w.endpoint);
    await _save();
  }

  bool isAdded(ClusterWorker w) => workers.any((s) => s.endpoint == w.endpoint);

  /// Looks for workers on the Wi-Fi (doesn't work on every router).
  Future<void> scanNearby() async {
    if (isScanning.value) return;
    isScanning.value = true;
    try {
      final list = await LlamaCluster.discover();
      found.assignAll(list.where((w) => !isAdded(w)));
    } finally {
      isScanning.value = false;
    }
  }

  Future<void> _setEnabled(bool value) async {
    enabled.value = value;
    await _hive.setSetting(AppConstants.keyClusterEnabled, value);
  }

  Future<void> _save() => _hive.setSetting(
      AppConstants.keyClusterWorkers, [for (final w in workers) w.toMap()]);

  // ── Master: loading ────────────────────────────────────────────────────

  /// Plans a GGUF load right before it starts and hands the plan to the
  /// native engine (or turns cluster mode off for it). Returns the number of
  /// workers used; throws with a readable message if the model won't fit
  /// or a worker can't be reached.
  ///
  /// If the model fits on this phone, asks whether to keep it here (faster:
  /// no Wi-Fi in the loop) or share it with the workers anyway. Otherwise
  /// the fastest phones are filled first, up to their free memory: phones
  /// take turns on every token, so the most work belongs on the fastest one,
  /// and phones that aren't needed are left out (one less Wi-Fi hop each).
  final _activeWorkerEndpoints = <String>{};

  Future<bool> activeWorkerDisconnected() async {
    if (_activeWorkerEndpoints.isEmpty) return false;
    final endpoints = List.of(_activeWorkerEndpoints);
    final online = await Future.wait(endpoints.map((endpoint) async {
      try {
        return await LlamaCluster.probe(endpoint)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        return false;
      }
    }));
    return online.contains(false);
  }

  Future<({int workers, int context})> applyForNextLoad(
    String modelPath, {
    required int context,
    required bool autoContext,
    bool safeRetry = false,
  }) async {
    clearSplit();
    Future<({int workers, int context})> local(int tokens) async {
      if (isSupported) await LlamaCluster.clear();
      return (workers: 0, context: tokens);
    }

    if (!isSupported || !enabled.value || workers.isEmpty) {
      return local(context);
    }

    final activeProfile = profile.value;
    final offline = await relocateWorkers();
    final available = workers.where((w) =>
        !offline.any((o) => o.endpoint == w.endpoint) &&
        (activeProfile != ClusterProfile.manual || weightFor(workerKey(w)) > 0)).toList();
    if (offline.isNotEmpty) {
      final names = offline.map((w) => w.model ?? w.name).join(', ');
      showToast('Phone cluster', 'Not reachable, loading without: $names');
    }

    final masterWeight = weightFor(localDeviceKey);
    if (activeProfile == ClusterProfile.manual &&
        available.isEmpty && masterWeight == 0) {
      throw StateError('No enabled devices are reachable. Increase a device’s cluster weight.');
    }

    const bytesPerMb = 1024 * 1024;
    final modelMb = await File(modelPath).length() / bytesPerMb;
    final metadata = await readGgufInfo(modelPath);
    final masterCapacity = await LlamaCluster.localFreeRamMb() * 0.7;
    if (masterCapacity <= 0) {
      throw StateError('Could not measure free memory on the master. Retry after checking the cluster.');
    }
    final mayEstimate = metadata != null && metadata.trainedContext >= 512 &&
        metadata.kvCacheBytes(512) > 0;
    final estimatedOverheadMb = !mayEstimate
        ? modelMb * 0.1
        : (metadata.estimateBytes(512) - metadata.fileBytes) / bytesPerMb;
    // The master always owns the output weights and runs the session, even
    // when the user assigns every transformer layer to workers.
    final reserveMb = math.min(estimatedOverheadMb, 256.0 + math.min(modelMb * 0.08, 512.0));
    if (masterCapacity <= reserveMb) {
      throw StateError('The master needs more free memory for the output and session buffers.');
    }
    _localSpeed ??= await LlamaCluster.benchmark();
    final master = _Phone(null, masterCapacity - reserveMb, _localSpeed!);
    final phones = [
      master,
      for (final w in available)
        _Phone(w, (w.ramMb ?? 2000) * 0.75, w.bandwidth ?? _unknownSpeed,
            roundTripMs: _workerRoundTripMs[w.endpoint] ?? 5),
    ];
    final capacity = phones.fold<double>(reserveMb, (total, phone) {
      if (activeProfile == ClusterProfile.manual && phone.worker == null &&
          masterWeight == 0) return total;
      return total + phone.capacityMb;
    });
    var tokens = context;
    if (!safeRetry) {
      switch (activeProfile) {
        case ClusterProfile.speed:
          tokens = math.min(tokens, 2048);
        case ClusterProfile.capacity:
          tokens = 512;
        case ClusterProfile.context:
          if (mayEstimate) {
            tokens = math.min(metadata.trainedContext, 32768);
          }
        case ClusterProfile.automatic:
        case ClusterProfile.manual:
          break;
      }
    }
    if (mayEstimate) {
      tokens = math.min(tokens, metadata.trainedContext);
      if (autoContext || activeProfile == ClusterProfile.context) {
        final fitting = metadata.maxContextFitting((capacity * bytesPerMb).floor());
        if (fitting != null) tokens = math.min(tokens, fitting);
      }
    }
    final needMb = mayEstimate ? metadata.estimateBytes(tokens) / bytesPerMb
        : modelMb * 1.1;
    if (needMb > capacity) {
      throw Exception('About ${_gb(needMb)} is needed at $tokens tokens. '
          'Enabled devices offer about ${_gb(capacity)}. '
          'Lower the context window, enable more devices, or choose a smaller model.');
    }

    if (available.isEmpty) return local(tokens);
    if (needMb <= masterCapacity) {
      if (activeProfile == ClusterProfile.speed ||
          activeProfile == ClusterProfile.automatic) return local(tokens);
    }

    final layerMemoryMb = needMb - reserveMb;
    if (activeProfile == ClusterProfile.speed ||
        (activeProfile == ClusterProfile.automatic &&
            needMb > masterCapacity)) {
      final shares = placeSequentialLayers([
        for (final p in phones)
          (
            capacityMb: p.capacityMb,
            bandwidthGbps: p.speed,
            latencyMs: p.roundTripMs
          ),
      ], layerMemoryMb);
      for (var i = 0; i < phones.length; i++) {
        phones[i].assignedMb = shares[i];
      }
    } else {
      final shares = distributeClusterLoad([
        for (final phone in phones)
          (
            capacity: phone.capacityMb,
            weight: switch (activeProfile) {
              ClusterProfile.manual => weightFor(phone.worker == null
                  ? localDeviceKey : workerKey(phone.worker!)).toDouble(),
              ClusterProfile.context || ClusterProfile.capacity => phone.capacityMb,
              _ => phone.speed,
            },
          )
      ], layerMemoryMb);
      if (shares == null) {
        throw StateError('The selected devices do not have enough available memory.');
      }
      for (var i = 0; i < phones.length; i++) {
        phones[i].assignedMb = shares[i];
      }
    }

    final used = phones.where((p) => p.worker != null && p.assignedMb > 0).toList();
    if (used.isEmpty) return local(tokens);
    try {
      await LlamaCluster.setCluster(
        [for (final p in used) p.worker!],
        weights: [for (final p in used) p.assignedMb],
        localWeight: master.assignedMb,
      );
    } on PlatformException catch (e) {
      throw Exception(
          '${e.message ?? 'A worker is unreachable'}. Turn on Worker on that '
          'phone, or set this phone\'s Phone cluster to Off.');
    }
    _activeWorkerEndpoints.addAll(used.map((phone) => phone.worker!.endpoint));
    return (workers: used.length, context: tokens);
  }

  /// LiteRT models can't be split across phones (the cluster is llama.cpp).
  /// When this phone is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null) return true;
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle: '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across phones. It will run '
          'on this phone only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx, label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this phone's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath) async {
    final buffers = await LlamaCluster.lastLoadBuffers();
    final remote = <String, double>{};
    for (final b in buffers) {
      final open = b.name.indexOf('[');
      if (open < 0) continue;
      final endpoint = b.name.substring(open + 1, b.name.lastIndexOf(']'));
      final name = workers.firstWhereOrNull((w) => w.endpoint == endpoint)?.model ?? endpoint;
      remote[name] = (remote[name] ?? 0) + b.mb;
    }
    final fileMb = await File(modelPath).length() / (1024 * 1024);
    final remoteMb = remote.values.fold<double>(0, (a, b) => a + b);
    split.assignAll([
      ClusterShare(deviceName.isEmpty ? 'This phone' : deviceName,
          math.max(0, fileMb - remoteMb), isThisPhone: true),
      for (final e in remote.entries) ClusterShare(e.key, e.value),
    ]);
  }

  void clearSplit() {
    split.clear();
    _activeWorkerEndpoints.clear();
  }

  static String _gb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
}
