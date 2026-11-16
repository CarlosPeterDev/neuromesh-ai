import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/build_flavor.dart';
import 'agent_service.dart';
import 'device_bridge.dart';

/// A small Alpine Linux that the AI can run commands in (Pro build only).
/// It runs through proot, with no root and no extra Android permissions.
/// Not part of the Google Play build: it downloads packages and runs them.
class SandboxService extends GetxService {
  static const rootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz';

  final installed = false.obs;
  final busy = false.obs;
  final status = ''.obs;

  String _libDir = '';

  static bool get supported => kProBuild && !kIsWeb && Platform.isAndroid;

  Future<Directory> _root() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/alpine');
  }

  @override
  Future<void> onInit() async {
    super.onInit();
    if (!supported) return;
    _libDir = await Get.find<DeviceBridge>().nativeLibDir();
    installed.value = File('${(await _root()).path}/rootfs/bin/sh').existsSync() ||
        Link('${(await _root()).path}/rootfs/bin/sh').existsSync();
  }

  bool get hasProot => _libDir.isNotEmpty && File('$_libDir/libproot.so').existsSync();

  /// Downloads Alpine (about 4 MB) and prepares it.
  Future<void> install() async {
    if (!supported) throw Exception('The Linux sandbox is only in the Pro build.');
    if (!hasProot) throw Exception('This build does not include proot.');
    busy.value = true;
    try {
      final root = await _root();
      await root.create(recursive: true);
      final rootfs = Directory('${root.path}/rootfs');
      if (await rootfs.exists()) await rootfs.delete(recursive: true);
      await rootfs.create(recursive: true);
      status.value = 'Downloading Alpine Linux…';
      final tgz = File('${root.path}/rootfs.tar.gz');
      final res = await http.get(Uri.parse(rootfsUrl)).timeout(const Duration(minutes: 5));
      if (res.statusCode != 200) throw Exception('Download failed (${res.statusCode}).');
      await tgz.writeAsBytes(res.bodyBytes);
      status.value = 'Unpacking…';
      final r = await Process.run('tar', ['-xzf', tgz.path, '-C', rootfs.path]);
      if (r.exitCode != 0) throw Exception('Unpack failed: ${r.stderr}');
      await tgz.delete();
      await File('${rootfs.path}/etc/resolv.conf').writeAsString('nameserver 1.1.1.1\nnameserver 8.8.8.8\n');
      await Directory('${root.path}/tmp').create(recursive: true);
      installed.value = true;
      status.value = 'Ready';
    } finally {
      busy.value = false;
    }
  }

  Future<void> uninstall() async {
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
    installed.value = false;
    status.value = '';
  }

  /// Runs [command] inside Alpine. The AI's workspace is /workspace.
  Future<String> run(String command, {int timeoutSec = 120}) async {
    if (!installed.value) return 'Error: the Linux sandbox is not installed. Turn it on in Chat tools.';
    final root = await _root();
    final work = (await Get.find<AgentService>().filesDir()).path;
    final libs = '${root.path}/lib';
    await Directory(libs).create(recursive: true);
    // proot needs libtalloc.so.2; the APK can only carry names ending in .so.
    final talloc = File('$libs/libtalloc.so.2');
    if (!await talloc.exists() && File('$_libDir/libtalloc.so').existsSync()) {
      await File('$_libDir/libtalloc.so').copy(talloc.path);
    }
    final args = [
      '-r', '${root.path}/rootfs',
      '-0',
      '--link2symlink',
      '-w', '/workspace',
      '-b', '/dev', '-b', '/proc', '-b', '/sys',
      '-b', '$work:/workspace',
      '/bin/sh', '-c', command,
    ];
    final env = {
      'PROOT_LOADER': '$_libDir/libproot_loader.so',
      'PROOT_TMP_DIR': '${root.path}/tmp',
      'LD_LIBRARY_PATH': '$libs:$_libDir',
      'HOME': '/root',
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'TERM': 'xterm',
    };
    Process p;
    try {
      p = await Process.start('$_libDir/libproot.so', args, environment: env, includeParentEnvironment: false);
    } catch (e) {
      return 'Error: could not start the sandbox: $e';
    }
    final out = StringBuffer();
    void add(List<int> b) {
      if (out.length < 16000) out.write(utf8.decode(b, allowMalformed: true));
    }

    final subs = [p.stdout.listen(add), p.stderr.listen(add)];
    var timedOut = false;
    final code = await p.exitCode.timeout(Duration(seconds: timeoutSec), onTimeout: () {
      timedOut = true;
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
    for (final s in subs) {
      await s.cancel();
    }
    var text = out.toString().trim();
    if (text.length > 6000) text = '${text.substring(0, 6000)}\n… (output cut)';
    return '${timedOut ? '[timed out after $timeoutSec s]\n' : ''}${text.isEmpty ? '(no output)' : text}\n[exit code $code]';
  }
}

/// Gives the AI a `run_shell` tool that works inside the Alpine sandbox.
void registerSandboxShell(AgentService agent) {
  if (!SandboxService.supported) return;
  agent.addTool(AgentTool(
    'run_shell',
    'Run a shell command in a small Alpine Linux (apk, sh, busybox). /workspace is the shared file area. '
        'You can install tools with "apk add python3 nodejs git curl". Times out after 120 seconds.',
    '{"command":"string"}',
    (args) async => Get.find<SandboxService>().run((args['command'] ?? '').toString()),
    needsConfirm: true,
  ));
}
