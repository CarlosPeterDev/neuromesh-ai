import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:neuromesh_ai/services/pollinations_image_service.dart';

void main() {
  test('decode an explicitly supplied live-provider response artifact', () async {
    final bytes = await File(Platform.environment['POLLINATIONS_LIVE_ARTIFACT']!).readAsBytes();
    final image = img.decodeImage(bytes);
    expect(image, isNotNull);
    expect(image!.width, 768); expect(image.height, 768);
  }, skip: !Platform.environment.containsKey('POLLINATIONS_LIVE_ARTIFACT'));

  const freeEditor = 'community/test/flux-edit-free';
  const freePortrait = 'community/test/lucid-origin:free';
  final catalog = [
    {
      'name': 'community/test/paid-editor-free',
      'input_modalities': ['text', 'image'],
      'output_modalities': ['image'],
      'pricing': {'currency': 'pollen', 'completionImageTokens': '1'}
    },
    {
      'name': freePortrait,
      'input_modalities': ['text'],
      'output_modalities': ['image'],
      'pricing': {'currency': 'pollen'}
    },
    {
      'name': freeEditor,
      'input_modalities': ['text', 'image'],
      'output_modalities': ['image'],
      'pricing': {'currency': 'pollen'}
    },
  ];

  test('model routing skips paid and text-only models for edits', () {
    expect(
        PollinationsImageService.chooseFreeModel(catalog,
            edit: false, style: 'illustration'),
        freePortrait);
    expect(
        PollinationsImageService.chooseFreeModel(catalog,
            edit: false, style: 'photo'),
        freeEditor);
    expect(PollinationsImageService.chooseFreeModel(catalog, edit: true),
        freeEditor);
    expect(
        PollinationsImageService.chooseFreeModel(catalog.take(2).toList(),
            edit: true),
        isNull);
  });

  test('uploads the actual image only to the free editing endpoint', () async {
    final png =
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.url.host, 'gen.pollinations.ai');
      expect(request.followRedirects, isFalse);
      if (request.url.path == '/image/models') {
        expect(request.method, 'GET');
        expect(request.headers['authorization'], isNull);
        return http.Response(jsonEncode(catalog), 200);
      }
      expect(request.url.path, '/v1/images/edits');
      expect(request.method, 'POST');
      expect(request.headers['authorization'], 'Bearer sample-key');
      final body = jsonDecode(request.body) as Map;
      expect(body['model'], freeEditor);
      expect(body['image'], [
        {'image_url': 'data:image/png;base64,${base64Encode(png)}'}
      ]);
      expect(body['prompt'], 'Turn the sky purple');
      return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': base64Encode(png)}
            ]
          }),
          200);
    });
    final result = await PollinationsImageService()
        .edit('Turn the sky purple', png, key: 'sample-key', client: client);
    expect(result.model, freeEditor);
    expect(result.extension, 'png');
    expect(requests, 2);
  });

  test('uses the anonymous URL without redirects, and returns JPEG bytes',
      () async {
    final data = img.encodeJpg(img.Image(width: 2, height: 2));
    final client = MockClient((request) async {
      expect(request.url.host, 'image.pollinations.ai');
      expect(request.url.scheme, 'https');
      expect(request.url.pathSegments, ['prompt', 'A cat? #1 phone wallpaper']);
      expect(request.url.queryParameters, {
        'model': 'sana',
        'width': '768',
        'height': '768',
        'nologo': 'true',
        'nofeed': 'true',
      });
      expect(request.headers, isNot(contains('authorization')));
      expect(request.followRedirects, isFalse);
      return http.Response.bytes(data, 200);
    });
    expect(
        await PollinationsImageService()
            .generate('A cat? #1 phone wallpaper', client: client),
        data);
  });

  test('the anonymous free limit displays the provider retry time', () async {
    final client = MockClient((_) async =>
        http.Response('Free limit', 402, headers: {'retry-after': '45'}));
    await expectLater(
        PollinationsImageService().generate('Cat', client: client),
        throwsA(isA<FormatException>().having(
            (error) => error.message, 'message', contains('in 45 seconds'))));
  });

  test('surfaces access and format errors', () async {
    for (final (status, message) in [
      (402, 'declined anonymous'),
      (429, 'rate-limiting'),
      (302, 'HTTP 302'),
      (200, 'invalid JPEG'),
    ]) {
      final client = MockClient((_) async => http.Response('error', status));
      await expectLater(
          PollinationsImageService().generate('Cat', client: client),
          throwsA(isA<FormatException>()
              .having((error) => error.message, 'message', contains(message))));
    }
  });
}
