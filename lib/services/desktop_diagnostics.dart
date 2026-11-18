import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

Future<Map<String, dynamic>> desktopDiagnostics() async {
  if (Platform.isWindows) return _windowsDiagnostics();
  if (!Platform.isLinux) return {};
  final status = <String, dynamic>{};
  try {
    final memory = await File('/proc/meminfo').readAsString();
    for (final (name, key) in [
      ('MemTotal', 'ramTotal'),
      ('MemAvailable', 'ramFree')
    ]) {
      final value = int.tryParse(RegExp('^$name:\\s+(\\d+)', multiLine: true)
              .firstMatch(memory)
              ?.group(1) ??
          '');
      if (value != null) status[key] = value * 1024;
    }
    final process = await Process.run('df', ['-Pk', Directory.systemTemp.path])
        .timeout(const Duration(seconds: 2));
    if (process.exitCode == 0) {
      final columns = (process.stdout as String)
          .trim()
          .split('\n')
          .last
          .trim()
          .split(RegExp(r'\s+'));
      if (columns.length >= 6) {
        final total = int.tryParse(columns[1]);
        final free = int.tryParse(columns[3]);
        if (total != null && free != null) {
          status.addAll(
              {'storageTotal': total * 1024, 'storageFree': free * 1024});
        }
      }
    }
  } catch (_) {
    // Keep available measurements if one resource could not be sampled.
  }
  return status;
}

Map<String, dynamic> _windowsDiagnostics() {
  final status = <String, dynamic>{};
  final data = calloc<Uint64>(8);
  try {
    final kernel = DynamicLibrary.open('kernel32.dll');
    // MEMORYSTATUSEX starts with two DWORDs, followed by seven DWORDLONGs.
    data.cast<Uint32>().value = 64;
    final memory = kernel.lookupFunction<Int32 Function(Pointer<Uint64>),
        int Function(Pointer<Uint64>)>('GlobalMemoryStatusEx');
    if (memory(data) != 0) {
      status.addAll({'ramTotal': data[1], 'ramFree': data[2]});
    }
    final disk = kernel.lookupFunction<
        Int32 Function(
            Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(
            Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>(
      'GetDiskFreeSpaceExW',
    );
    final path = Directory.systemTemp.path.toNativeUtf16();
    try {
      if (disk(path, data, data + 1, data + 2) != 0) {
        status.addAll({'storageTotal': data[1], 'storageFree': data[0]});
      }
    } finally {
      malloc.free(path);
    }
  } catch (_) {
    // Keep available measurements if one resource could not be sampled.
  } finally {
    calloc.free(data);
  }
  return status;
}
