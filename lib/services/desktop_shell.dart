import 'package:get/get.dart';

import 'agent_service.dart';
import 'desktop_command_service.dart';
import 'hive_service.dart';

void registerDesktopShell(AgentService agent) {
  if (!hasDesktopShell) return;
  Get.put(DesktopCommandService(Get.find<HiveService>()), permanent: true);
  agent.addTool(AgentTool(
    'run_shell',
    'Run a command through this computer’s shell or the user’s selected SSH VM. '
        'The default working folder is the workspace on the computer and the home folder in the VM. '
        'The user controls desktop command approvals.',
    '{"command":"string","cwd":"optional folder path"}',
    (_) => 'Error: desktop commands require the chat approval flow.',
    needsConfirm: true,
  ));
}
