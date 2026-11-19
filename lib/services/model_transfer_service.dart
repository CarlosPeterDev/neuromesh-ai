import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../controllers/model_controller.dart';
import 'download_service.dart';
import 'cluster_backup.dart';
import 'lan_network.dart';
import 'voice_models.dart';

/// Moving models between devices on the same network (and voice models to and
/// from .zip files). Nothing here talks to the internet.

String formatTransferBytes(num b) {
  if (b >= 1024 * 1024 * 1024) return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${b.round()} B';
}

/// One file inside a shared model.
class TransferFile {
  /// Path inside the model folder (or the file name for single-file models).
  final String rel;
  final int size;

  /// Server-side id used to ask for the file.
  final int fid;
  const TransferFile(this.rel, this.size, this.fid);

  Map<String, dynamic> toJson() => {'p': rel, 's': size, 'i': fid};

  factory TransferFile.fromJson(Map<String, dynamic> j) => TransferFile(
      (j['p'] ?? '').toString(),
      (j['s'] as num?)?.toInt() ?? 0,
      (j['i'] as num?)?.toInt() ?? -1);
}

/// One model the sender offers: a single file (GGUF…), or a folder
/// (.sdbundle image models, voice models).
class TransferItem {
  final String id;

  /// 'llm', 'image', 'vision' or 'voice'.
  final String kind;
  final String name;

  /// Set for voice models: the catalogue id.
  final String? voiceId;

  /// True when the model is a folder.
  final bool isDir;
  final List<TransferFile> files;
  const TransferItem({
    required this.id,
    required this.kind,
    required this.name,
    required this.voiceId,
    required this.isDir,
    required this.files,
  });

  int get size => files.fold<int>(0, (a, f) => a + f.size);

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'name': name,
        'voiceId': voiceId,
        'dir': isDir,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory TransferItem.fromJson(Map<String, dynamic> j) => TransferItem(
        id: (j['id'] ?? '').toString(),
        kind: (j['kind'] ?? 'llm').toString(),
        name: (j['name'] ?? '').toString(),
        voiceId: j['voiceId']?.toString(),
        isDir: j['dir'] == true,
        files: [
          for (final f in (j['files'] as List? ?? const []))
            TransferFile.fromJson(Map<String, dynamic>.from(f as Map)),
        ],
      );
}

bool _skipName(String path) {
  final l = path.toLowerCase();
  return l.endsWith('.part') ||
      l.endsWith('.tmp') ||
      l.endsWith('.download') ||
      l.endsWith('.downloading') ||
      l.endsWith('.transfer');
}

const _modelExts = [
  '.gguf',
  '.litertlm',
  '.safetensors',
  '.coreml',
  '.mlpackage',
  '.mlmodelc',
  '.sdbundle',
];

/// A relative path from the other device is only accepted when it can't
/// escape the target folder.
String? _safeRel(String rel) {
  if (rel.isEmpty || rel.startsWith('/') || rel.startsWith('\\') || rel.contains(':')) {
    return null;
  }
  final parts = rel.split(RegExp(r'[\\/]'));
  for (final p in parts) {
    if (p.isEmpty || p == '.' || p == '..') return null;
  }
  return parts.join('/');
}

String? _safeName(String name) {
  if (name.isEmpty || name == '.' || name == '..') return null;
  if (name.contains('/') || name.contains('\\') || name.contains(':')) return null;
  return name;
}

Future<String?> lanAddress() async {
  try {
    final ifs = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    String? fallback;
    for (final i in ifs) {
      for (final a in i.addresses) {
        final ip = a.address;
        if (!isPrivateLanAddress(ip)) continue;
        final n = i.name.toLowerCase();
        if (n.startsWith('wlan') || n == 'en0' || n.startsWith('wi')) return ip;
        fallback ??= ip;
      }
    }
    return fallback;
  } catch (_) {
    return null;
  }
}

String _randomToken() {
  final r = math.Random.secure();
  const chars = 'abcdefghijkmnopqrstuvwxyz23456789';
  return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
}

bool _sameToken(String? a, String b) {
  if (a == null || a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// ───────────────────────── Sender ─────────────────────────

class ModelTransferServer {
  HttpServer? _server;
  String token = '';
  String host = '127.0.0.1';
  final _table = <int, File>{};
  Directory? _backupDirectory;
  Uint8List? _backupKey;
  Map<ClusterBackupPart, File> _backups = {};
  List<TransferItem> _offer = const [];
  int bytesServed = 0;
  int activeRequests = 0;
  void Function()? onChange;
  final _tick = Stopwatch()..start();

  bool get running => _server != null;
  int get port => _server?.port ?? 0;

  /// What the receiver types or scans.
  String get url => 'http://$host:$port/?token=$token'
      '${_backupKey == null ? '' : '#backup=${base64Url.encode(_backupKey!).replaceAll('=', '')}'}';

  Future<String> start({
    bool includeModels = true,
    Set<ClusterBackupPart> backupParts = const {},
  }) async {
    await stop();
    token = _randomToken();
    final ip = await lanAddress();
    if (ip == null) throw StateError('Connect to a private Wi-Fi network first.');
    host = ip;
    bytesServed = 0;
    try {
      if (backupParts.isNotEmpty) {
        final cache = await getTemporaryDirectory();
        _backupDirectory = await cache.createTemp('cluster-backup-');
        _backupKey = ClusterBackup.randomBytes(32);
        for (final part in backupParts) {
          final file = File('${_backupDirectory!.path}/${part.name}.bin');
          if (part == ClusterBackupPart.files) {
            await ClusterBackup.writeWorkspace(file, _backupKey!);
          } else {
            final packet = await ClusterBackup.build(part, _backupKey!);
            await file.writeAsBytes(packet, flush: true);
          }
          _backups[part] = file;
        }
      }
      _offer = await collectItems(includeModels: includeModels);
      if (_offer.isEmpty) throw StateError('There is nothing selected to share.');
      final server = await HttpServer.bind(InternetAddress(host), 0);
      _server = server;
      server.listen((req) => _handle(req), onError: (_) {});
      return url;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _table.clear();
    _offer = const [];
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
    final directory = _backupDirectory;
    _backupDirectory = null;
    _backupKey = null;
    _backups = {};
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  void _notify({bool force = false}) {
    if (force || _tick.elapsedMilliseconds > 400) {
      _tick.reset();
      onChange?.call();
    }
  }

  /// Everything installed on this device that can be sent.
  Future<List<TransferItem>> collectItems({bool includeModels = true}) async {
    final out = <TransferItem>[];
    final table = <int, File>{};
    var fid = 0;

    Future<List<TransferFile>> filesOf(Directory d,
        {bool skipComplete = false}) async {
      final list = <TransferFile>[];
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = e.path.substring(d.path.length + 1).replaceAll('\\', '/');
        if (_skipName(rel)) continue;
        if (skipComplete && rel == '.complete') continue;
        table[fid] = e;
        list.add(TransferFile(rel, await e.length(), fid));
        fid++;
      }
      return list;
    }

    if (includeModels) {
    // Text, vision and image models.
    final dl = Get.find<DownloadService>();
    final modelsDir = Directory(await dl.modelsDir);
    if (await modelsDir.exists()) {
      final entries = modelsDir.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        final name = e.path.split(Platform.pathSeparator).last;
        final lower = name.toLowerCase();
        if (!_modelExts.any(lower.endsWith)) continue;
        final kind = lower.endsWith('.sdbundle') || lower.endsWith('.safetensors')
            ? 'image'
            : lower.contains('mmproj')
                ? 'vision'
                : 'llm';
        if (e is File) {
          table[fid] = e;
          out.add(TransferItem(
              id: 'm${out.length}',
              kind: kind,
              name: name,
              voiceId: null,
              isDir: false,
              files: [TransferFile(name, await e.length(), fid)]));
          fid++;
        } else if (e is Directory) {
          final files = await filesOf(e);
          if (files.isEmpty) continue;
          out.add(TransferItem(
              id: 'm${out.length}',
              kind: kind,
              name: name,
              voiceId: null,
              isDir: true,
              files: files));
        }
      }
    }

    // Voice models.
    final store = Get.find<VoiceModelStore>();
    for (final m in kVoiceModels) {
      if (!store.installed.contains(m.id)) continue;
      final d = Directory(await store.dirFor(m));
      if (!await d.exists()) continue;
      final files = await filesOf(d, skipComplete: true);
      if (files.isEmpty) continue;
      out.add(TransferItem(
          id: 'v${out.length}',
          kind: 'voice',
          name: m.title,
          voiceId: m.id,
          isDir: true,
          files: files));
    }

    }
    for (final item in _backups.entries) {
      final id = fid++;
      table[id] = item.value;
      out.add(TransferItem(
        id: item.key.transferId,
        kind: 'backup',
        name: item.key.label,
        voiceId: null,
        isDir: false,
        files: [TransferFile('backup.bin', await item.value.length(), id)],
      ));
    }

    _table
      ..clear()
      ..addAll(table);
    return out;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (!_sameToken(req.uri.queryParameters['token'], token)) {
        res.statusCode = HttpStatus.forbidden;
        await res.close();
        return;
      }
      switch (req.uri.path) {
        case '/list':
          final body = utf8.encode(jsonEncode({
            'app': 'neuromesh',
            'items': _offer.map((i) => i.toJson()).toList(),
          }));
          res.headers.contentType = ContentType.json;
          res.contentLength = body.length;
          res.add(body);
          await res.close();
          return;
        case '/file':
          await _serveFile(req);
          return;
        default:
          res.statusCode = HttpStatus.notFound;
          await res.close();
      }
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _serveFile(HttpRequest req) async {
    final res = req.response;
    final fid = int.tryParse(req.uri.queryParameters['fid'] ?? '');
    final file = fid == null ? null : _table[fid];
    if (file == null || !await file.exists()) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final len = await file.length();
    var start = 0;
    var end = len - 1;
    var status = HttpStatus.ok;
    final range = req.headers.value('range');
    if (range != null && len > 0) {
      final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (m != null) {
        final a = m.group(1) ?? '';
        final b = m.group(2) ?? '';
        if (a.isNotEmpty) {
          start = int.parse(a);
          if (b.isNotEmpty) end = math.min(int.parse(b), len - 1);
        } else if (b.isNotEmpty) {
          start = math.max(0, len - int.parse(b));
        }
        if (start > end || start >= len) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set('Content-Range', 'bytes */$len');
          await res.close();
          return;
        }
        status = HttpStatus.partialContent;
      }
    }
    res.statusCode = status;
    res.headers.set('Accept-Ranges', 'bytes');
    res.headers.contentType = ContentType.binary;
    if (status == HttpStatus.partialContent) {
      res.headers.set('Content-Range', 'bytes $start-$end/$len');
    }
    res.contentLength = len == 0 ? 0 : end - start + 1;
    if (len == 0) {
      await res.close();
      return;
    }
    activeRequests++;
    _notify(force: true);
    try {
      await res.addStream(file.openRead(start, end + 1).map((c) {
        bytesServed += c.length;
        _notify();
        return c;
      }));
      await res.close();
    } finally {
      activeRequests--;
      _notify(force: true);
    }
  }
}

/// ───────────────────────── Receiver ─────────────────────────

class TransferCancelled implements Exception {
  @override
  String toString() => 'Cancelled';
}

class TransferProgress {
  final int done;
  final int total;
  final String current;
  const TransferProgress(this.done, this.total, this.current);
  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

class ModelTransferClient {
  final Uri base;
  final String token;
  http.Client? _client;
  bool _cancel = false;
  int _done = 0;
  int _total = 0;
  String _current = '';
  void Function(TransferProgress)? _onProgress;
  final _tick = Stopwatch()..start();

  final Uint8List? _backupKey;
  ModelTransferClient._(this.base, this.token, this._backupKey);

  /// Accepts the URL shown on the sender (scanned or typed).
  static ModelTransferClient? parse(String text) {
    var s = text.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null ||
        u.scheme != 'http' ||
        !isPrivateLanAddress(u.host) ||
        !u.hasPort || u.port < 1 || u.port > 65535 ||
        u.userInfo.isNotEmpty ||
        (u.path.isNotEmpty && u.path != '/')) {
      return null;
    }
    final params = u.queryParametersAll;
    if (params.length != 1 || params['token']?.length != 1) return null;
    final t = params['token']!.single;
    if (!RegExp(r'^[abcdefghijkmnopqrstuvwxyz23456789]{12}$').hasMatch(t)) {
      return null;
    }
    Uint8List? key;
    if (u.hasFragment) {
      final match = RegExp(r'^backup=([A-Za-z0-9_-]{43})$').firstMatch(u.fragment);
      if (match == null) return null;
      try {
        key = base64Url.decode(base64Url.normalize(match.group(1)!));
      } on FormatException {
        return null;
      }
    }
    return ModelTransferClient._(
        Uri(scheme: 'http', host: u.host, port: u.port), t, key);
  }

  Uri _uri(String path, [Map<String, String> extra = const {}]) =>
      base.replace(path: path, queryParameters: {'token': token, ...extra});

  void cancel() {
    _cancel = true;
    _client?.close();
  }

  Future<List<TransferItem>> fetchList() async {
    final c = lanHttpClient();
    try {
      final req = http.Request('GET', _uri('/list'))..followRedirects = false;
      final response = await c.send(req).timeout(const Duration(seconds: 15));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const FormatException('The sender tried to redirect the connection.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('The sender’s file list is too large.');
        }
        bytes.add(chunk);
      }
      final res = http.Response.bytes(bytes.takeBytes(), response.statusCode);
      if (res.statusCode == 403) {
        throw Exception('The code was not accepted. Check it on the other device.');
      }
      if (res.statusCode != 200) {
        throw Exception('The other device answered ${res.statusCode}.');
      }
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is! Map || j['app'] != 'neuromesh') {
        throw Exception('That is not a NeuroMesh AI device.');
      }
      final items = [
        for (final i in (j['items'] as List? ?? const []))
          TransferItem.fromJson(Map<String, dynamic>.from(i as Map)),
      ];
      if (items.map((item) => item.id).toSet().length != items.length) {
        throw const FormatException('The sender listed duplicate items.');
      }
      return items.where((item) => item.kind != 'backup' ||
          (_backupKey != null &&
              ClusterBackupPart.fromTransferId(item.id) != null)).toList();
    } finally {
      c.close();
    }
  }

  Future<String?> _destFor(TransferItem it) async {
    if (it.voiceId != null) {
      final m = kVoiceModels.where((m) => m.id == it.voiceId);
      if (m.isEmpty) return null;
      return Get.find<VoiceModelStore>().dirFor(m.first);
    }
    final name = _safeName(it.name);
    if (name == null) return null;
    return '${await Get.find<DownloadService>().modelsDir}/$name';
  }

  /// True when this device already has the model complete.
  Future<bool> haveLocally(TransferItem it) async {
    if (it.kind == 'backup') return false;
    try {
      final dest = await _destFor(it);
      if (dest == null) return false;
      if (!it.isDir) {
        final f = File(dest);
        return await f.exists() && await f.length() == it.size;
      }
      for (final f in it.files) {
        final rel = _safeRel(f.rel);
        if (rel == null) return false;
        final lf = File('$dest/$rel');
        if (!await lf.exists() || await lf.length() != f.size) return false;
      }
      return it.voiceId == null || await File('$dest/.complete').exists();
    } catch (_) {
      return false;
    }
  }

  void _report({bool force = false}) {
    if (force || _tick.elapsedMilliseconds > 250) {
      _tick.reset();
      _onProgress?.call(TransferProgress(_done, _total, _current));
    }
  }

  /// Downloads the chosen models. Throws [TransferCancelled] when stopped.
  /// Returns the names that could not be received, with the reason.
  Future<List<String>> download(List<TransferItem> items,
      {required void Function(TransferProgress) onProgress}) async {
    _cancel = false;
    _onProgress = onProgress;
    _done = 0;
    _total = items.fold<int>(0, (a, i) => a + i.size);
    final failures = <String>[];
    _client = lanHttpClient();
    try {
      for (final it in items) {
        if (_cancel) throw TransferCancelled();
        _current = it.name;
        _report(force: true);
        try {
          await _receive(it);
        } on TransferCancelled {
          rethrow;
        } catch (e) {
          if (_cancel) throw TransferCancelled();
          failures.add('${it.name}: $e');
        }
      }
    } on http.ClientException {
      if (_cancel) throw TransferCancelled();
      rethrow;
    } finally {
      _client?.close();
      _client = null;
      _report(force: true);
      try {
        if (Get.isRegistered<ModelController>()) {
          await Get.find<ModelController>().refreshDownloaded();
        }
        await Get.find<VoiceModelStore>().scan();
      } catch (_) {}
    }
    return failures;
  }

  Future<void> _receive(TransferItem it) async {
    if (it.kind == 'backup') {
      final key = _backupKey;
      final part = ClusterBackupPart.fromTransferId(it.id);
      if (key == null ||
          part == null ||
          it.files.length != 1 ||
          it.size < 28 ||
          (part != ClusterBackupPart.files &&
              it.size > ClusterBackup.maxBytes + 28)) {
        throw const FormatException('Invalid backup or missing backup key.');
      }
      final cache = await getTemporaryDirectory();
      final dir = await cache.createTemp('cluster-restore-');
      try {
        final file = File('${dir.path}/backup.bin');
        await _getFile(it.files.single, file);
        if (part == ClusterBackupPart.files) {
          await ClusterBackup.restoreWorkspace(file, key);
        } else {
          await ClusterBackup.restore(part, key, await file.readAsBytes());
        }
      } finally {
        await dir.delete(recursive: true);
      }
      return;
    }
    final dest = await _destFor(it);
    if (dest == null) {
      throw Exception(it.voiceId != null
          ? 'this voice model is not in this version of the app'
          : 'unsafe file name');
    }
    if (await haveLocally(it)) {
      _done += it.size;
      _report();
      return;
    }
    if (!it.isDir) {
      if (it.files.isEmpty) throw Exception('nothing to download');
      final f = File(dest);
      await _getFile(it.files.first, f);
      return;
    }
    final tmp = Directory('$dest.transfer');
    for (final f in it.files) {
      final rel = _safeRel(f.rel);
      if (rel == null) throw Exception('unsafe path "${f.rel}"');
      await _getFile(f, File('${tmp.path}/$rel'));
    }
    final d = Directory(dest);
    if (await d.exists()) await d.delete(recursive: true);
    await tmp.rename(dest);
    if (it.voiceId != null) {
      await File('$dest/.complete').writeAsString('ok');
    }
  }

  Future<void> _getFile(TransferFile f, File dest) async {
    if (await dest.exists() && await dest.length() == f.size) {
      _done += f.size;
      _report();
      return;
    }
    await dest.parent.create(recursive: true);
    final part = File('${dest.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > f.size) {
      await part.delete();
      have = 0;
    }
    if (have < f.size || f.size == 0) {
      final req = http.Request('GET', _uri('/file', {'fid': '${f.fid}'}))
        ..followRedirects = false;
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      final res = await _client!.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 && res.statusCode != 206) {
        throw Exception('the other device answered ${res.statusCode}');
      }
      if (res.statusCode == 206 &&
          res.headers['content-range'] != 'bytes $have-${f.size - 1}/${f.size}') {
        throw const FormatException('The sender returned an unexpected byte range.');
      }
      if (res.statusCode == 200) have = 0; // the sender ignored the range
      _done += have;
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
          if (_cancel) throw TransferCancelled();
          if (have + chunk.length > f.size) {
            throw const FormatException('The sender exceeded the expected file size.');
          }
          sink.add(chunk);
          have += chunk.length;
          _done += chunk.length;
          _report();
        }
      } finally {
        await sink.close();
      }
    } else {
      _done += have;
    }
    if (await part.length() != f.size) {
      throw Exception('incomplete download of ${f.rel}; try again to resume');
    }
    if (await dest.exists()) await dest.delete();
    await part.rename(dest.path);
  }
}

/// ───────────────────── Voice models as .zip ─────────────────────

final _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}();

int _crcUpdate(int crc, List<int> data) {
  var c = crc;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c;
}

class _ZipSrc {
  final String name;
  final File? file;
  final List<int>? bytes;
  _ZipSrc.file(this.name, File this.file) : bytes = null;
  _ZipSrc.bytes(this.name, List<int> this.bytes) : file = null;
}

Uint8List _le(int bytes, int value) {
  final b = ByteData(bytes);
  if (bytes == 2) b.setUint16(0, value, Endian.little);
  if (bytes == 4) b.setUint32(0, value, Endian.little);
  return b.buffer.asUint8List();
}

/// Writes an uncompressed (stored) zip. Voice models are already compressed
/// and this needs no extra memory, so it stays fast on phones.
Future<void> _writeStoredZip(File out, List<_ZipSrc> sources) async {
  final sink = out.openWrite();
  final central = BytesBuilder();
  var offset = 0;
  try {
    for (final s in sources) {
      final nameBytes = utf8.encode(s.name);
      var crc = 0xFFFFFFFF;
      var size = 0;
      if (s.bytes != null) {
        crc = _crcUpdate(crc, s.bytes!);
        size = s.bytes!.length;
      } else {
        await for (final chunk in s.file!.openRead()) {
          crc = _crcUpdate(crc, chunk);
          size += chunk.length;
        }
      }
      crc = crc ^ 0xFFFFFFFF;
      if (size > 0xFFFFFFFE || offset > 0xFFFFFFFE) {
        throw Exception('This model is too large for a .zip file (4 GB limit).');
      }
      final header = BytesBuilder()
        ..add(_le(4, 0x04034b50))
        ..add(_le(2, 20))
        ..add(_le(2, 0x0800)) // UTF-8 names
        ..add(_le(2, 0)) // stored
        ..add(_le(2, 0))
        ..add(_le(2, 33)) // 1980-01-01
        ..add(_le(4, crc))
        ..add(_le(4, size))
        ..add(_le(4, size))
        ..add(_le(2, nameBytes.length))
        ..add(_le(2, 0))
        ..add(nameBytes);
      final h = header.toBytes();
      sink.add(h);
      if (s.bytes != null) {
        sink.add(s.bytes!);
      } else {
        await sink.addStream(s.file!.openRead());
      }
      central
        ..add(_le(4, 0x02014b50))
        ..add(_le(2, 20))
        ..add(_le(2, 20))
        ..add(_le(2, 0x0800))
        ..add(_le(2, 0))
        ..add(_le(2, 0))
        ..add(_le(2, 33))
        ..add(_le(4, crc))
        ..add(_le(4, size))
        ..add(_le(4, size))
        ..add(_le(2, nameBytes.length))
        ..add(_le(2, 0))
        ..add(_le(2, 0))
        ..add(_le(2, 0))
        ..add(_le(2, 0))
        ..add(_le(4, 0))
        ..add(_le(4, offset))
        ..add(nameBytes);
      offset += h.length + size;
      if (offset > 0xFFFFFFFE) {
        throw const FormatException('This export exceeds the ZIP size limit (4 GB).');
      }
    }
    if (sources.length > 0xFFFE) throw Exception('Too many files for a .zip.');
    final cd = central.toBytes();
    if (offset + cd.length + 22 > 0xFFFFFFFE) {
      throw const FormatException('This export exceeds the ZIP size limit (4 GB).');
    }
    sink
      ..add(cd)
      ..add(_le(4, 0x06054b50))
      ..add(_le(2, 0))
      ..add(_le(2, 0))
      ..add(_le(2, sources.length))
      ..add(_le(2, sources.length))
      ..add(_le(4, cd.length))
      ..add(_le(4, offset))
      ..add(_le(2, 0));
  } finally {
    await sink.close();
  }
}

/// The file names listed in a zip's central directory (to reject unsafe ones
/// before anything is unpacked).
Future<List<String>> _zipNames(File f) async {
  final len = await f.length();
  if (len < 22) throw Exception('That is not a .zip file.');
  final tailLen = math.min(len, 66000);
  final raf = await f.open();
  try {
    await raf.setPosition(len - tailLen);
    final tail = await raf.read(tailLen);
    var e = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 5 && tail[i + 3] == 6) {
        e = i;
        break;
      }
    }
    if (e < 0) throw Exception('That is not a .zip file.');
    final bd = ByteData.sublistView(tail);
    final count = bd.getUint16(e + 10, Endian.little);
    final cdSize = bd.getUint32(e + 12, Endian.little);
    final cdOff = bd.getUint32(e + 16, Endian.little);
    if (count == 0xFFFF || cdOff == 0xFFFFFFFF) {
      throw Exception('Zip64 files are not supported.');
    }
    await raf.setPosition(cdOff);
    final cd = await raf.read(cdSize);
    final cb = ByteData.sublistView(Uint8List.fromList(cd));
    final names = <String>[];
    var p = 0;
    for (var i = 0; i < count; i++) {
      if (p + 46 > cd.length || cb.getUint32(p, Endian.little) != 0x02014b50) break;
      final n = cb.getUint16(p + 28, Endian.little);
      final x = cb.getUint16(p + 30, Endian.little);
      final c = cb.getUint16(p + 32, Endian.little);
      names.add(utf8.decode(cd.sublist(p + 46, p + 46 + n), allowMalformed: true));
      p += 46 + n + x + c;
    }
    return names;
  } finally {
    await raf.close();
  }
}

bool _isDesktop() => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

extension VoiceModelPortable on VoiceModelStore {
  Future<Directory> _portableRoot() async =>
      Directory(await dirFor(kVoiceModels.first)).parent;

  /// Packs an installed voice model into a .zip. On desktop it is saved in
  /// the Downloads folder; on phones the share sheet opens so it can be saved
  /// to Files / Downloads, Drive, or sent to another device.
  /// Returns a message to show the user.
  Future<String> exportZip(VoiceModelInfo m) async {
    final dir = Directory(await dirFor(m));
    if (!await dir.exists()) throw Exception('This voice model is not installed.');
    final Directory outDir;
    if (_isDesktop()) {
      outDir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
    } else {
      outDir = await getTemporaryDirectory();
    }
    await outDir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final out = File('${outDir.path}/NeuroMesh-voice-${m.id}-$stamp.zip');
    final partial = File('${out.path}.part');
    final sources = <_ZipSrc>[
      _ZipSrc.bytes(
          'manifest.json',
          utf8.encode(jsonEncode({
            'app': 'neuromesh',
            'type': 'voice-model',
            'id': m.id,
            'dirName': m.dirName,
            'title': m.title,
          }))),
    ];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.substring(dir.path.length + 1).replaceAll('\\', '/');
      if (rel == '.complete' || _skipName(rel)) continue;
      sources.add(_ZipSrc.file('${m.dirName}/$rel', e));
    }
    try {
      await Isolate.run(() => _writeStoredZip(partial, sources));
      await partial.rename(out.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
    if (_isDesktop()) return 'Saved to ${out.path}';
    await Share.shareXFiles([XFile(out.path)], subject: m.title);
    return 'Choose where to save the file (Files, Downloads, Drive…).';
  }

  /// Installs a voice model from a .zip made by [exportZip]. Returns the
  /// model that was installed.
  Future<VoiceModelInfo> importZip(String zipPath) async {
    final zip = File(zipPath);
    if (!await zip.exists()) throw Exception('File not found.');
    final names = await _zipNames(zip);
    if (names.isEmpty) throw Exception('That .zip is empty.');
    for (final n in names) {
      if (n.startsWith('/') ||
          n.startsWith('\\') ||
          n.contains(':') ||
          n.split(RegExp(r'[\\/]')).contains('..')) {
        throw Exception('That .zip contains unsafe paths, so it was not opened.');
      }
    }
    final root = await _portableRoot();
    final tmp = Directory('${root.path}/.import_${DateTime.now().millisecondsSinceEpoch}');
    await tmp.create(recursive: true);
    try {
      final src = zip.path;
      final dst = tmp.path;
      await Isolate.run(() => extractFileToDisk(src, dst));

      VoiceModelInfo? model;
      final manifest = File('${tmp.path}/manifest.json');
      if (await manifest.exists()) {
        try {
          final j = jsonDecode(await manifest.readAsString());
          final id = j is Map ? j['id']?.toString() : null;
          for (final m in kVoiceModels) {
            if (m.id == id) model = m;
          }
        } catch (_) {}
      }
      if (model == null) {
        final tops = names.map((n) => n.split(RegExp(r'[\\/]')).first).toSet();
        for (final m in kVoiceModels) {
          if (tops.contains(m.dirName)) model = m;
        }
      }
      if (model == null) {
        throw Exception(
            'That .zip is not a voice model this version of the app knows.');
      }
      final from = Directory('${tmp.path}/${model.dirName}');
      if (!await from.exists()) {
        throw Exception('The voice model folder is missing inside the .zip.');
      }
      final dest = Directory(await dirFor(model));
      if (await dest.exists()) await dest.delete(recursive: true);
      await from.rename(dest.path);
      await File('${dest.path}/.complete').writeAsString('ok');
      await scan();
      return model;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}
