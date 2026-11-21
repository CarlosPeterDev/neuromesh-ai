import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/update_service.dart';

void main() {
  test('prefers the release GitHub marked Latest', () async {
    final client = MockClient((request) async {
      expect(request.url.path, endsWith('/releases/latest'));
      return http.Response('{"tag_name":"v1.0.151"}', 200);
    });
    addTearDown(client.close);
    final release =
        await UpdateService.fetchLatestRelease(client, abi: 'arm64');
    expect(release.version, '1.0.151');
  });

  test('checks the legacy tag when no Latest release exists', () async {
    final routes = <String>[];
    final client = MockClient((request) async {
      routes.add(request.url.path.split('/releases/').last);
      return routes.length == 1
          ? http.Response('', 404)
          : http.Response(
              '{"tag_name":"latest","name":"NeuroMesh v1.0.139"}', 200);
    });
    addTearDown(client.close);
    final release =
        await UpdateService.fetchLatestRelease(client, abi: 'arm64');
    expect(release.version, '1.0.139');
    expect(routes, ['latest', 'tags/latest']);
  });

  test(
      'moving GitHub channel selects ARM64 and reads its real version and signer',
      () {
    final signer = 'ab' * 32;
    final release = UpdateService.parseRelease({
      'tag_name': 'latest',
      'name': 'NeuroMesh AI latest (v1.0.136)',
      'body': 'Release notes\n- Android APK signer SHA-256: $signer\n',
      'assets': [
        {'name': 'NeuroMesh-AI-v1.0.136-universal-dev.apk', 'size': 9},
        {'name': 'NeuroMesh-AI-v1.0.136-arm64-dev.apk', 'size': 5},
      ],
    }, abi: 'arm64');
    expect(release.version, '1.0.136');
    expect(release.apkName, endsWith('-arm64-dev.apk'));
    expect(release.signerSha256, signer);
    expect(UpdateService.compareVersions(release.version, '1.0.133'), 1);
  });
}
