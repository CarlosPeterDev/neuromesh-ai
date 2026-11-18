import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/tunnel_service.dart';

void main() {
  test('finds the public link split across SSH output chunks', () {
    final address = TunnelAddress();
    expect(address.add('Welcome to localhost.run\nhttps://my-'), isNull);
    expect(address.add('phone.lhr.life\n'), 'https://my-phone.lhr.life');
  });

  test('ignores help URLs and lookalike domains', () {
    final address = TunnelAddress();
    expect(address.add('See https://localhost.run/docs'), isNull);
    expect(address.add(' https://a.lhr.life.example.com'), isNull);
    expect(address.add(' https://phone.localhost.run '),
        'https://phone.localhost.run');
  });

  test('only verifies the published keys and algorithms', () {
    final fingerprint = Uint8List.fromList(
      ascii.encode('SHA256:pG6qrBxubYfWa1Zadu/V0NUgjEDiBds/7e2xzte/QNM'),
    );
    expect(TunnelService.verifyHostKey('ssh-ed25519', fingerprint), isTrue);
    expect(TunnelService.verifyHostKey('ssh-rsa', fingerprint), isFalse);
    expect(TunnelService.verifyHostKey('ssh-ed25519', Uint8List(0)), isFalse);
  });
}
