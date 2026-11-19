import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/ui.dart';
import '../services/desktop_command_service.dart';

class DesktopAccessView extends StatelessWidget {
  const DesktopAccessView({super.key});

  Future<void> _configureVm(
      BuildContext context, DesktopCommandService service) async {
    final input = TextEditingController(text: service.vmHost.value);
    final host = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Connect to a VM'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'Configure OpenSSH on your computer and verify the VM’s host key first. NeuroMesh uses that SSH configuration and key.'),
          const SizedBox(height: 12),
          TextField(
            controller: input,
            decoration:
                const InputDecoration(labelText: 'SSH alias or user@host'),
            autocorrect: false,
            textCapitalization: TextCapitalization.none,
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, input.text),
              child: const Text('Save VM')),
        ],
      ),
    );
    input.dispose();
    if (host == null) return;
    try {
      await service.useTarget(vm: true, host: host);
    } on FormatException catch (error) {
      if (context.mounted) showToast('Invalid SSH host', error.message);
    }
  }

  Future<void> _setMode(BuildContext context, DesktopCommandService service,
      DesktopApproval mode) async {
    final scope = service.scope;
    if (mode == DesktopApproval.allowAll) {
      final allowed = await confirmSheet(
        context,
        title: 'Allow all terminal commands?',
        confirmLabel: 'Allow all commands',
        message: service.target.value == 'vm'
            ? 'The agent can use your SSH account to run any command in this VM. It can change or delete files and access networks without asking again.'
            : 'The agent can run any command your account can run. This can expose private files, change your system, delete data, or send information over the network without asking again.',
      );
      if (allowed != true || service.scope != scope) return;
    }
    await service.setApproval(mode);
  }

  @override
  Widget build(BuildContext context) {
    final service = Get.find<DesktopCommandService>();
    return Scaffold(
      appBar: appScreenBar(context,
          title: 'Desktop command access', showBack: true),
      body: Obx(() => ListView(padding: kPagePadding, children: [
            const AppNotice(
                'Local commands run in your computer’s shell with your account permissions. You can also use a VM you manage over SSH. Approvals are saved for each target.'),
            const SectionHeader('Command target'),
            AppGroup(children: [
              AppRow(
                icon: Icons.computer_rounded,
                title: 'This computer',
                subtitle: service.target.value == 'local' ? 'Selected' : null,
                onTap: () => service.useTarget(vm: false),
              ),
              AppRow(
                icon: Icons.dns_outlined,
                title: 'Virtual machine via SSH',
                subtitle: service.target.value == 'vm'
                    ? 'Selected · ${service.vmHost.value}'
                    : 'Optional · configure a Linux VM',
                onTap: () => _configureVm(context, service),
              ),
            ]),
            const SectionHeader('Approval'),
            AppGroup(children: [
              for (final (mode, label, description) in const [
                (
                  DesktopApproval.eachCommand,
                  'Ask every time',
                  'Review the full command and working folder.'
                ),
                (
                  DesktopApproval.approvedTypes,
                  'Remember approved types',
                  'Unapproved commands still ask. Approve an eligible command type in its review dialog.'
                ),
                (
                  DesktopApproval.allowAll,
                  'Allow all commands',
                  'Run without approval prompts.'
                ),
                (
                  DesktopApproval.blocked,
                  'Block commands',
                  'The agent cannot run desktop commands.'
                ),
              ])
                AppRow(
                  title: label,
                  subtitle: description,
                  trailing: service.approval == mode
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => _setMode(context, service, mode),
                ),
            ]),
            if (service.types.isNotEmpty) ...[
              const SectionHeader('Approved command types'),
              AppGroup(children: [
                for (final type in service.types)
                  AppRow(
                    title: type,
                    trailing: IconButton(
                      tooltip: 'Revoke $type approval',
                      onPressed: () => service.revokeType(type),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
              ]),
            ],
          ])),
    );
  }
}
