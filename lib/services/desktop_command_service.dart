import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'hive_service.dart';

bool get hasDesktopShell =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

enum DesktopApproval { eachCommand, approvedTypes, allowAll, blocked }

/// Types that can be approved without approving arbitrary shell syntax.
String? desktopCommandType(String command) {
  final input = command.trim();
  if (RegExp(r'^(pwd|whoami|Get-Location|Get-ChildItem|dir)$',
          caseSensitive: false)
      .hasMatch(input)) return input.toLowerCase();
  if (RegExp(r'^ls(?: +-[alh1]+)*$').hasMatch(input)) return 'ls';
  return null;
}

bool validDesktopVmHost(String host) => RegExp(
      r'^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$',
    ).hasMatch(host);

class DesktopCommandService extends GetxService {
  DesktopCommandService(this._hive);

  final HiveService _hive;
  final vmHost = ''.obs;
  final target = 'local'.obs;
  final approvals = <String, String>{}.obs;
  final approvedTypes = <String, List<String>>{}.obs;

  String get scope => target.value == 'vm' ? 'vm:${vmHost.value}' : 'local';
  DesktopApproval get approval =>
      DesktopApproval.values.firstWhere((mode) => mode.name == approvals[scope],
          orElse: () => DesktopApproval.eachCommand);
  List<String> get types => approvedTypes[scope] ?? const [];

  @override
  void onInit() {
    super.onInit();
    vmHost.value = _hive.getSetting<String>('desktop_vm_host') ?? '';
    final saved = _hive.getSetting<Map>('desktop_command_approvals') ?? {};
    approvals.assignAll({
      for (final entry in saved.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    });
    // Preserve an explicit legacy block. Unrestricted desktop access now
    // requires acknowledgement through the desktop settings screen.
    final legacy = _hive.getSetting<Map>('agent_tool_policy') ?? {};
    if (!approvals.containsKey('local') &&
        legacy['built-in::run_shell'] == 'block') {
      approvals['local'] = DesktopApproval.blocked.name;
    }
    final types = _hive.getSetting<Map>('desktop_command_types') ?? {};
    approvedTypes.assignAll({
      for (final entry in types.entries)
        if (entry.key is String && entry.value is List)
          entry.key as String:
              (entry.value as List).whereType<String>().toList(),
    });
    if (validDesktopVmHost(vmHost.value) &&
        _hive.getSetting<String>('desktop_command_target') == 'vm') {
      target.value = 'vm';
    }
  }

  Future<void> useTarget({required bool vm, String? host}) async {
    if (vm) {
      final newHost = (host ?? vmHost.value).trim();
      if (!validDesktopVmHost(newHost)) {
        throw const FormatException('Enter an SSH host alias or user@host.');
      }
      await _hive.setSetting('desktop_vm_host', newHost);
      vmHost.value = newHost;
    }
    target.value = vm ? 'vm' : 'local';
    await _hive.setSetting('desktop_command_target', target.value);
  }

  Future<void> setApproval(DesktopApproval mode) async {
    approvals[scope] = mode.name;
    await _hive.setSetting(
        'desktop_command_approvals', Map<String, String>.of(approvals));
  }

  Future<void> allowType(String type) async {
    approvedTypes[scope] = {...types, type}.toList()..sort();
    approvals[scope] = DesktopApproval.approvedTypes.name;
    await _hive.settingsBox.putAll({
      'desktop_command_types': Map<String, List<String>>.of(approvedTypes),
      'desktop_command_approvals': Map<String, String>.of(approvals),
    });
  }

  Future<void> revokeType(String type) async {
    approvedTypes[scope] = types.where((saved) => saved != type).toList();
    await _hive.setSetting(
        'desktop_command_types', Map<String, List<String>>.of(approvedTypes));
  }

  Future<String> execute(
    Map<String, dynamic> args,
    Future<Directory> Function() workspace,
    Future<bool> Function(String, String, Map<String, dynamic>) confirm,
  ) async {
    final command = (args['command'] ?? '').toString().trim();
    if (command.isEmpty) return 'Error: empty command.';
    final activeScope = scope;
    final onVm = target.value == 'vm';
    final host = vmHost.value;
    if (onVm && !validDesktopVmHost(host))
      return 'Error: configure a VM first.';
    final requested = (args['cwd'] ?? '').toString().trim();
    final cwd = onVm
        ? (requested.isEmpty ? '.' : requested)
        : (requested.isEmpty ? (await workspace()).path : requested);
    if (!onVm && !await Directory(cwd).exists()) {
      return 'Error: the requested working folder does not exist.';
    }
    final mode = approval;
    if (mode == DesktopApproval.blocked) return 'Desktop commands are blocked.';
    final type = desktopCommandType(command);
    // A different folder can change behavior. Remember types only for the
    // default workspace or VM home directory.
    final typeCanBeSaved = type != null && requested.isEmpty;
    final allowed = mode == DesktopApproval.allowAll ||
        (mode == DesktopApproval.approvedTypes &&
            typeCanBeSaved &&
            types.contains(type));
    if (!allowed &&
        !await confirm('run_shell', 'desktop', {
          'command': command,
          'cwd': cwd,
          'target': onVm ? 'SSH VM ($host)' : 'This computer',
          if (typeCanBeSaved) 'type': type,
          'scope': activeScope,
        })) return 'The user denied this command.';
    if (scope != activeScope || approval == DesktopApproval.blocked) {
      return 'Desktop access changed. Request approval again.';
    }

    final remoteCommand = cwd == '.'
        ? command
        : "cd '${cwd.replaceAll("'", "'\\''")}' && $command";
    final executable = onVm
        ? 'ssh'
        : Platform.isWindows
            ? 'powershell.exe'
            : 'bash';
    final arguments = onVm
        ? [
            '-o',
            'BatchMode=yes',
            '-o',
            'StrictHostKeyChecking=yes',
            host,
            remoteCommand
          ]
        : Platform.isWindows
            ? ['-NoProfile', '-NonInteractive', '-Command', command]
            : ['--noprofile', '--norc', '-c', command];
    try {
      final process = await Process.start(executable, arguments,
          workingDirectory: onVm ? null : cwd,
          environment: !onVm && !Platform.isWindows ? {'BASH_ENV': ''} : null,
          runInShell: false);
      final output = StringBuffer();
      void append(String chunk) {
        if (output.length < 16000) output.write(chunk);
      }

      final streams = [
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .forEach(append),
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .forEach(append),
      ];
      await process.stdin.close();
      final code = await process.exitCode.timeout(const Duration(seconds: 120),
          onTimeout: () {
        process.kill();
        return -1;
      });
      await Future.wait(streams)
          .timeout(const Duration(seconds: 2), onTimeout: () => []);
      var result = output.toString().trim();
      if (result.length > 5900)
        result = '${result.substring(0, 5900)}\n… (output cut)';
      return '${code == -1 ? '[timed out after 120 s]\n' : ''}'
          '${result.isEmpty ? '(no output)' : result}\n[exit code $code]';
    } on ProcessException catch (error) {
      return 'Error: could not start $executable: ${error.message}';
    }
  }
}
