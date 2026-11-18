import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/cluster_backup.dart';
import 'package:neuromesh_ai/services/model_transfer_service.dart';

void main() {
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
