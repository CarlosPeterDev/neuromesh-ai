import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/memory_service.dart';

void main() {
  test('automatic memory saves context and preferences instead of tasks', () {
    final notes = MemoryService.parseFacts('''
- Create hello.txt in the workspace.
- The user asked for a report to be sent.
- User wants the assistant to publish the build.
- المستخدم طلب تعديل التطبيق.
- User builds cross-platform Flutter apps.
- User prefers Egyptian Arabic replies.
- The user's project uses local models by default.
''');
    expect(notes, [
      'User builds cross-platform Flutter apps.',
      'User prefers Egyptian Arabic replies.',
      "The user's project uses local models by default.",
    ]);
  });

  test(
      'old tasks stay out of the model context and file saves are not memory requests',
      () async {
    Get.put(HiveService());
    addTearDown(Get.reset);
    final agent = AgentService();
    agent.memory.addAll([
      'Create hello.txt in the workspace.',
      'User prefers Egyptian Arabic replies.',
    ]);

    expect(
        agent.memoryBlock(), contains('User prefers Egyptian Arabic replies.'));
    expect(agent.memoryBlock(), isNot(contains('hello.txt')));
    expect(
        await agent.rememberDirect('save hello.txt in the workspace'), isNull);
    expect(await agent.rememberDirect('remember to send the report'), isNull);
    expect(await agent.rememberDirect('remember that send the report'), isNull);
  });
}
