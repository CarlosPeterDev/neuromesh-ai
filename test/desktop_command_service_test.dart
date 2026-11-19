import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/services/desktop_command_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';

void main() {
  test('type approvals exclude compound expressions and shell expansions', () {
    expect(desktopCommandType(r'ls -la'), 'ls');
    expect(desktopCommandType('Get-ChildItem'), 'get-childitem');
    expect(desktopCommandType('ls; echo another command'), isNull);
    expect(desktopCommandType(r'ls $(pwd)'), isNull);
    expect(desktopCommandType('Get-ChildItem | Write-Output'), isNull);
    expect(validDesktopVmHost('user@my-vm'), isTrue);
    expect(validDesktopVmHost('-oProxyCommand=example'), isFalse);
  });

  test('denial shows the exact target and command and leaves it unexecuted',
      () async {
    final dir = await Directory.systemTemp.createTemp('nm-command-approval');
    Hive.init(dir.path);
    addTearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });
    final service = DesktopCommandService(await HiveService().init());
    service.onInit();

    final result = await service.execute(
      {'command': 'echo example > marker.txt'},
      () async => dir,
      (tool, server, args) async {
        expect(server, 'desktop');
        expect(args['target'], 'This computer');
        expect(args['cwd'], dir.path);
        expect(args['command'], 'echo example > marker.txt');
        expect(args.containsKey('type'), isFalse);
        return false;
      },
    );
    expect(result, 'The user denied this command.');
    expect(await File('${dir.path}/marker.txt').exists(), isFalse);

    await service.allowType('pwd');
    expect(service.approval, DesktopApproval.approvedTypes);
    expect(service.types, ['pwd']);
    if (Platform.isLinux) {
      final output = await service.execute(
        {'command': 'pwd'},
        () async => dir,
        (_, __, ___) async =>
            fail('The approved type should run without a prompt.'),
      );
      expect(output, contains(dir.path));
      expect(output, endsWith('[exit code 0]'));
    }
    await service.useTarget(vm: true, host: 'private-vm');
    expect(service.approval, DesktopApproval.eachCommand);
    expect(service.types, isEmpty);
    await service.useTarget(vm: false);
    await service.revokeType('pwd');
    expect(service.types, isEmpty);
  });
}
