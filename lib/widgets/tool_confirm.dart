import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/agent_service.dart';
import '../services/desktop_command_service.dart';

/// Asks the user whether the AI may run a tool. Used by chat.
Future<bool> confirmToolCall(
    String tool, String server, Map<String, dynamic> args) async {
  if (server == 'desktop' && tool == 'run_shell') {
    final service = Get.find<DesktopCommandService>();
    final type = args['type'] as String?;
    final scope = args['scope'];
    final choice = await Get.dialog<String>(
      AlertDialog(
        title: const Text('Review terminal command'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Target: ${args['target']}\nFolder: ${args['cwd']}'),
              const SizedBox(height: 12),
              SelectableText('${args['command']}',
                  style: const TextStyle(fontFamily: 'monospace')),
              const SizedBox(height: 12),
              const Text('This command runs with the account’s permissions.'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: 'deny'),
              child: const Text('Deny')),
          if (type != null)
            TextButton(
              onPressed: () => Get.back(result: 'type'),
              child: Text('Allow $type type'),
            ),
          FilledButton(
              onPressed: () => Get.back(result: 'once'),
              child: const Text('Allow once')),
        ],
      ),
      barrierDismissible: false,
    );
    if (choice == 'type' &&
        type != null &&
        service.scope == scope &&
        service.approval != DesktopApproval.blocked) {
      await service.allowType(type);
      return true;
    }
    return choice == 'once';
  }
  final pretty = args.isEmpty
      ? '(no arguments)'
      : const JsonEncoder.withIndent('  ').convert(args);
  final shown = pretty.length > 900 ? '${pretty.substring(0, 900)}…' : pretty;
  final where = server == 'built-in' ? '' : ' on "$server"';
  final risky = tool == 'run_shell' || tool == 'write_user_file';
  final choice = await Get.dialog<String>(
    PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Allow this action?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('The AI wants to run "$tool"$where.'
                  '${server == 'built-in' ? '' : ' The data below is sent to that server.'}'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(Get.context!)
                      .colorScheme
                      .surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(shown,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
              if (risky) ...[
                const SizedBox(height: 10),
                const Text(
                    'This can change files or run commands. Check it before allowing.',
                    style: TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: 'deny'),
              child: const Text('Deny')),
          if (!risky)
            TextButton(
                onPressed: () => Get.back(result: 'always'),
                child: const Text('Always allow')),
          TextButton(
              onPressed: () => Get.back(result: 'once'),
              child: const Text('Allow once')),
        ],
      ),
    ),
    barrierDismissible: false,
  );
  if (choice == 'always') {
    await Get.find<AgentService>().allowAlwaysFor(server, tool);
  }
  return choice == 'once' || choice == 'always';
}
