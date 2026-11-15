import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_service.dart';

/// On Windows, Linux and macOS the AI uses the computer's own shell
/// (PowerShell or bash), so no Linux sandbox is needed there.
bool get hasDesktopShell =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

void registerDesktopShell(AgentService agent) {
  if (!hasDesktopShell) return;
  final shellName = Platform.isWindows ? 'PowerShell' : 'bash';
  agent.addTool(AgentTool(
    'run_shell',
    'Run a command in this computer\'s $shellName terminal and return its output. '
        'Working folder is the agent workspace unless cwd is given. Times out after 120 seconds.',
    '{"command":"string","cwd":"optional folder path"}',
    (args) async {
      final cmd = (args['command'] ?? '').toString();
      if (cmd.trim().isEmpty) return 'Error: empty command.';
      var cwd = (args['cwd'] ?? '').toString();
      if (cwd.isEmpty || !Directory(cwd).existsSync()) {
        cwd = (await agent.filesDir()).path;
      }
      final exe = Platform.isWindows ? 'powershell.exe' : 'bash';
      final argv = Platform.isWindows
          ? ['-NoProfile', '-NonInteractive', '-Command', cmd]
          : ['-lc', cmd];
      Process p;
      try {
        p = await Process.start(exe, argv, workingDirectory: cwd, runInShell: false);
      } catch (e) {
        return 'Error: could not start $shellName: $e';
      }
      final out = StringBuffer();
      void add(List<int> b) {
        if (out.length < 16000) out.write(utf8.decode(b, allowMalformed: true));
      }

      final subs = [p.stdout.listen(add), p.stderr.listen(add)];
      var timedOut = false;
      final code = await p.exitCode.timeout(const Duration(seconds: 120), onTimeout: () {
        timedOut = true;
        p.kill();
        return -1;
      });
      for (final s in subs) {
        await s.cancel();
      }
      var text = out.toString().trim();
      if (text.length > 6000) text = '${text.substring(0, 6000)}\n… (output cut)';
      return '${timedOut ? '[timed out after 120 s]\n' : ''}'
          '${text.isEmpty ? '(no output)' : text}\n[exit code $code]';
    },
    needsConfirm: true,
  ));
}
