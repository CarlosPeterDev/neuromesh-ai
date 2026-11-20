import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/pollinations_image_service.dart';

void main() {
  test('only explicit standalone image requests dispatch automatically', () {
    for (final request in [
      'Create an image of a fox',
      'Could you generate a photo of an orange?',
      'Draw me a picture of a cat',
    ]) {
      expect(PollinationsImageService.explicitPrompt(request), request);
    }
    for (final question in [
      'Explain how to make an image of a fox',
      'Describe this image',
      'Create an image based on my file',
      'Create an image using @file:private.txt',
    ]) {
      expect(PollinationsImageService.explicitPrompt(question), isNull);
    }
  });

  test('uses the anonymous URL without redirects, and returns JPEG bytes',
      () async {
    final data = [0xff, 0xd8, 0xff, 0xff, 0xd9];
    final client = MockClient((request) async {
      expect(request.url.host, 'image.pollinations.ai');
      expect(request.url.scheme, 'https');
      expect(request.url.pathSegments, ['prompt', 'A cat? #1 phone wallpaper']);
      expect(request.url.queryParameters, {
        'model': 'sana',
        'width': '576',
        'height': '1024',
        'nologo': 'true'
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
