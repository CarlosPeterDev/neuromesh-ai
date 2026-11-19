import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// Platform mock for the app's path_provider dependency.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:neuromesh_ai/services/cluster_backup.dart';
import 'package:neuromesh_ai/services/model_transfer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'streams large workspace files and rejects a truncated archive before restoring',
      () async {
    final temp = await Directory.systemTemp.createTemp('nm-transfer-test');
    addTearDown(() => temp.delete(recursive: true));
    final originalPaths = PathProviderPlatform.instance;
    addTearDown(() => PathProviderPlatform.instance = originalPaths);
    final sender = await Directory('${temp.path}/sender').create();
    final receiver = await Directory('${temp.path}/receiver').create();
    PathProviderPlatform.instance = _TransferPaths(sender.path);
    final original = File('${sender.path}/agent_files/output.bin');
    await original.parent.create();
    final bytes = Uint8List(2 * 1024 * 1024 + 19)
      ..[0] = 18
      ..[2 * 1024 * 1024 + 18] = 39;
    await original.writeAsBytes(bytes);
    final packet = File('${temp.path}/backup.bin');
    final key = ClusterBackup.randomBytes(32);
    await ClusterBackup.writeWorkspace(packet, key);

    PathProviderPlatform.instance = _TransferPaths(receiver.path);
    final shortened = File('${temp.path}/short.bin');
    final encrypted = await packet.readAsBytes();
    await shortened.writeAsBytes(encrypted.sublist(0, encrypted.length - 5));
    await expectLater(
        ClusterBackup.restoreWorkspace(shortened, key), throwsFormatException);
    final restored = File('${receiver.path}/agent_files/output.bin');
    expect(await restored.exists(), isFalse);

    await ClusterBackup.restoreWorkspace(packet, key);
    expect(await restored.readAsBytes(), bytes);
    await restored.writeAsString('existing file');
    await ClusterBackup.restoreWorkspace(packet, key);
    expect(await restored.readAsString(), 'existing file');
  });

  test('backup payload verifies the key and authentication tag', () {
    final key = ClusterBackup.randomBytes(32);
    final input = Uint8List.fromList(utf8.encode('Chat – تجربة'));
    final packet = ClusterBackup.seal(key, input);
    expect(ClusterBackup.open(key, packet), input);
    final wrongKey = Uint8List.fromList(key)..[0] ^= 1;
    expect(() => ClusterBackup.open(wrongKey, packet), throwsA(anything));
    packet[12] ^= 1;
    expect(() => ClusterBackup.open(key, packet), throwsA(anything));
  });

  test('a valid packet cannot restore a different backup category', () async {
    final key = ClusterBackup.randomBytes(32);
    final packet = ClusterBackup.seal(
        key, Uint8List.fromList(utf8.encode('{"kind":"memory"}')));
    await expectLater(
        ClusterBackup.restore(ClusterBackupPart.chats, key, packet),
        throwsFormatException);
  });

  test('backup codes are scoped to private LAN addresses', () {
    final key =
        base64Url.encode(ClusterBackup.randomBytes(32)).split('=').first;
    const suffix = ':8080/?token=abcdefghijkm';
    expect(ModelTransferClient.parse('http://192.168.1.2$suffix#backup=$key'),
        isNotNull);
    expect(ModelTransferClient.parse('http://192.168.1.2$suffix#backup=wrong'),
        isNull);
    expect(
        ModelTransferClient.parse('http://8.8.8.8$suffix#backup=$key'), isNull);
  });

  test('workspace backup paths reject escapes and unsafe file names', () {
    expect(ClusterBackup.isSafePath('agent_projects/abc/file.txt'), isTrue);
    expect(ClusterBackup.isSafePath('agent_projects/../file.txt'), isFalse);
    expect(ClusterBackup.isSafePath('agent_projects/.. /file.txt'), isFalse);
    expect(ClusterBackup.isSafePath('agent_files/CON.txt'), isFalse);
    expect(ClusterBackup.isSafePath('other/file.txt'), isFalse);
  });
}

class _TransferPaths extends PathProviderPlatform {
  _TransferPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
