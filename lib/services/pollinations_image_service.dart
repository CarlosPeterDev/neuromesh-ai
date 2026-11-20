import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Sana is available anonymously through Pollinations' public image endpoint.
class PollinationsImageService {
  static const attribution = 'Generated online with Pollinations (Sana).';
  static const _maxBytes = 12 * 1024 * 1024;
  static const _timeout = Duration(seconds: 75);

  static String? explicitPrompt(String text) {
    final request = RegExp(
      r'^\s*(?:please\s+)?(?:(?:can|could|would) you\s+)?(?:please\s+)?(?:generate|create|make|draw|render|paint)\s+(?:(?:an?|the|me an?)\s+)?(?:(?:ai[- ]generated|realistic|photorealistic)\s+)?(?:image|picture|photo|illustration|portrait)(?:\s+(?:of|showing|depicting|with)\b|\s*:\s*|\s+)(.+)$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(text);
    final subject = request?.group(1)?.trim();
    if (subject == null ||
        subject.isEmpty ||
        RegExp(r'^(?:from|based on|using)\s+(?:this|the|my|our)\b|@(?:file|skill):',
                caseSensitive: false)
            .hasMatch(subject)) return null;
    return text.trim();
  }

  Future<Uint8List> generate(String prompt, {http.Client? client}) async {
    final text = prompt.trim();
    if (text.isEmpty || text.length > 1000) {
      throw const FormatException(
          'Use an image description of 1 to 1,000 characters.');
    }
    final shape = text.toLowerCase();
    final wide = RegExp(r'\b(widescreen|landscape orientation|wide banner)\b')
        .hasMatch(shape);
    final tall =
        RegExp(r'\b(portrait orientation|vertical poster|phone wallpaper)\b')
            .hasMatch(shape);
    final uri = Uri(
      scheme: 'https',
      host: 'image.pollinations.ai',
      pathSegments: ['prompt', text],
      queryParameters: {
        'model': 'sana',
        'width': wide
            ? '1024'
            : tall
                ? '576'
                : '768',
        'height': wide
            ? '576'
            : tall
                ? '1024'
                : '768',
        'nologo': 'true',
      },
    );
    final transport = client ?? http.Client();
    try {
      return await _request(transport, uri).timeout(_timeout);
    } on TimeoutException {
      throw const FormatException(
          'Pollinations took too long to generate the image.');
    } on http.ClientException {
      throw const FormatException('Couldn’t connect to Pollinations.');
    } finally {
      if (client == null) transport.close();
    }
  }

  Future<Uint8List> _request(http.Client client, Uri uri) async {
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await client.send(request);
    if (response.statusCode == 401 ||
        response.statusCode == 402 ||
        response.statusCode == 403) {
      throw const FormatException(
          'Pollinations declined anonymous image generation for this request.');
    }
    if (response.statusCode == 429) {
      throw const FormatException(
          'Pollinations is rate-limiting anonymous requests. Try again later.');
    }
    if (response.statusCode != 200) {
      throw FormatException(
          'Pollinations is unavailable (HTTP ${response.statusCode}).');
    }
    if ((response.contentLength ?? 0) > _maxBytes) {
      throw const FormatException(
          'Pollinations returned an image that is too large.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > _maxBytes) {
        throw const FormatException(
            'Pollinations returned an image that is too large.');
      }
      bytes.add(chunk);
    }
    final image = bytes.takeBytes();
    if (image.length < 5 ||
        image[0] != 0xff ||
        image[1] != 0xd8 ||
        image[2] != 0xff ||
        image[image.length - 2] != 0xff ||
        image.last != 0xd9) {
      throw const FormatException(
          'Pollinations returned an invalid JPEG image.');
    }
    return image;
  }
}
