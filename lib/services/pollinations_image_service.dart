import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

typedef PollinationsImage = ({Uint8List bytes, String model, String extension});

enum ImageAction { create, edit }

class ImageRequest {
  const ImageRequest(this.action, this.description);
  final ImageAction action;
  final String description;

  static ImageRequest? parse(String value, {bool hasImage = false}) {
    final text = value.trim();
    final instruction = text.replaceFirst(
        RegExp(r'^\s*(?:(?:ok|please|can you|could you|would you)\b[ ,.!]+)+',
            caseSensitive: false),
        '');
    final edit = RegExp(
            r'^(?:retouch|restyle)\b|^(?:edit|remove|replace|change|add|crop|brighten|fix|turn)\b.*\b(?:image|picture|photo|background)\b',
            caseSensitive: false,
            dotAll: true)
        .hasMatch(instruction);
    final explicitCreation =
        PollinationsImageService.explicitPrompt(text) != null;
    final editExisting = RegExp(r'^(?:make|turn)\s+(?:this|the|my|attached)\b',
            caseSensitive: false)
        .hasMatch(instruction);
    if (explicitCreation && !edit && !editExisting) {
      return ImageRequest(ImageAction.create, text);
    }
    if (edit ||
        (hasImage &&
            RegExp(r'^(?:edit|remove|replace|change|add|make|crop|brighten|fix|turn)\b',
                    caseSensitive: false)
                .hasMatch(instruction))) {
      final bare = RegExp(
              r'^(?:edit|retouch|restyle)(?:\s+(?:this|the|my|an?)\s+(?:image|photo|picture))?[.!?]*$',
              caseSensitive: false)
          .hasMatch(instruction);
      return ImageRequest(ImageAction.edit, bare ? '' : text);
    }
    if (RegExp(
            r'^(?:draw|paint)\s+(?!(?:me\s+)?(?:an?\s+)?(?:image|picture|photo|illustration|portrait)\b)\S',
            caseSensitive: false)
        .hasMatch(instruction)) {
      return ImageRequest(ImageAction.create, text);
    }
    final match = RegExp(
      r'^(?:generate|create|make|render|design)\s+(?:me\s+)?(?:an?\s+)?(?:image|picture|photo|illustration|portrait|logo|poster|icon|banner|wallpaper)(?:\s+(.+))?[.!?]*$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(instruction);
    if (match == null) return null;
    final subject = match.group(1)?.trim() ?? '';
    return ImageRequest(
        ImageAction.create,
        RegExp(r'^(?:please|for me|something|anything|nice)?[.!?]*$',
                    caseSensitive: false)
                .hasMatch(subject)
            ? ''
            : text);
  }
}

/// Sana is available anonymously through Pollinations' public image endpoint.
class PollinationsImageService {
  static const attribution = 'Generated online with Pollinations (Sana).';
  static const _maxBytes = 12 * 1024 * 1024;
  static const _timeout = Duration(seconds: 75);
  static const internetNotice =
      'Create images online with Pollinations. Internet required.';
  static const editKeyNotice =
      'Pollinations requires a key for image editing. Add one under Models → Images. The app selects models listed as free.';
  static const _modernHost = 'gen.pollinations.ai';

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
        'nofeed': 'true',
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

  /// Uses the anonymous service if no key is configured. With a key, only
  /// explicitly free catalog models can be selected.
  Future<PollinationsImage> create(String prompt,
      {String? key, String style = '', http.Client? client}) async {
    if (key == null || key.isEmpty) {
      return (
        bytes: await generate(prompt, client: client),
        model: 'Sana',
        extension: 'jpg'
      );
    }
    return _modern(prompt, key: key, style: style, client: client);
  }

  Future<PollinationsImage> edit(String prompt, Uint8List source,
      {required String key, String style = '', http.Client? client}) async {
    if (key.trim().isEmpty) throw const FormatException(editKeyNotice);
    if (source.isEmpty || source.length > 8 * 1024 * 1024) {
      throw const FormatException('Choose an image smaller than 8 MB to edit.');
    }
    final extension = _imageExtension(source);
    if (!const {'jpg', 'png', 'webp'}.contains(extension)) {
      throw const FormatException('Choose a JPEG, PNG or WebP image to edit.');
    }
    final mime = extension == 'jpg' ? 'image/jpeg' : 'image/$extension';
    return _modern(prompt,
        key: key,
        style: style,
        client: client,
        source: 'data:$mime;base64,${base64Encode(source)}');
  }

  static String? chooseFreeModel(Object? catalog,
      {required bool edit, String style = ''}) {
    if (catalog is! List) return null;
    final eligible = <String>[];
    for (final model in catalog.whereType<Map>()) {
      final name = model['name'];
      final modalities = model['input_modalities'];
      final outputs = model['output_modalities'];
      final pricing = model['pricing'];
      if (name is! String ||
          !RegExp(r'^community/[a-z0-9._:/-]+(?:-free|:free)$',
                  caseSensitive: false)
              .hasMatch(name) ||
          pricing is! Map ||
          pricing.entries.any((entry) =>
              entry.key != 'currency' &&
              double.tryParse('${entry.value}') != 0) ||
          modalities is! List ||
          !modalities.contains('text') ||
          (edit && !modalities.contains('image')) ||
          (outputs is List && !outputs.contains('image'))) continue;
      eligible.add(name);
    }
    final keywords = edit
        ? ['flux', 'edit']
        : style == 'design'
            ? ['phoenix', 'flux', 'lucid']
            : style == 'photo'
                ? ['flux', 'phoenix', 'lucid']
                : ['lucid', 'phoenix', 'flux'];
    for (final keyword in keywords) {
      final match =
          eligible.where((model) => model.contains(keyword)).firstOrNull;
      if (match != null) return match;
    }
    return eligible.firstOrNull;
  }

  Future<PollinationsImage> _modern(
    String prompt, {
    required String key,
    required String style,
    String? source,
    http.Client? client,
  }) async {
    final description = prompt.trim();
    if (description.isEmpty || description.length > 1000) {
      throw const FormatException(
          'Use an image description of 1 to 1,000 characters.');
    }
    final transport = client ?? http.Client();
    try {
      final catalog = await transport
          .send(http.Request('GET', Uri.https(_modernHost, '/image/models'))
            ..followRedirects = false)
          .timeout(const Duration(seconds: 15));
      final catalogBytes = await _bounded(catalog, 1024 * 1024)
          .timeout(const Duration(seconds: 15));
      final model = catalog.statusCode == 200
          ? chooseFreeModel(jsonDecode(utf8.decode(catalogBytes)),
              edit: source != null, style: style)
          : null;
      if (model == null) {
        if (source == null) {
          return (
            bytes: await generate(description, client: transport),
            model: 'Sana',
            extension: 'jpg'
          );
        }
        throw const FormatException(
            'Pollinations has no free image editor available right now.');
      }
      final request = http.Request(
          'POST',
          Uri.https(_modernHost,
              source == null ? '/v1/images/generations' : '/v1/images/edits'))
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $key'
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'model': model,
          'prompt': description,
          'n': 1,
          'response_format': 'b64_json',
          if (source != null)
            'image': [
              {'image_url': source}
            ],
        });
      final response = await transport.send(request).timeout(_timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const FormatException(
            'Pollinations rejected the key. Check it under Models → Images.');
      }
      if (response.statusCode == 402) {
        throw const FormatException(
            'Pollinations denied this free request. Check your key’s model access and quota.');
      }
      if (response.statusCode != 200) {
        throw FormatException(
            'Pollinations returned HTTP ${response.statusCode}.');
      }
      final body = await _bounded(response, (_maxBytes * 4 ~/ 3) + 65536)
          .timeout(_timeout);
      final decoded = jsonDecode(utf8.decode(body));
      final data = decoded is Map ? decoded['data'] : null;
      final value = data is List && data.isNotEmpty && data.first is Map
          ? data.first['b64_json']
          : null;
      if (value is! String) {
        throw const FormatException('Pollinations returned no image.');
      }
      final bytes = base64Decode(value);
      final extension = _imageExtension(bytes);
      if (extension == null || bytes.length > _maxBytes) {
        throw const FormatException(
            'Pollinations returned an invalid or oversized image.');
      }
      final actual = response.headers['x-model-used'];
      if (actual != null && actual.isNotEmpty && actual != model) {
        throw const FormatException(
            'Pollinations returned a different model than the free model requested.');
      }
      return (bytes: bytes, model: model, extension: extension);
    } on TimeoutException {
      throw const FormatException('Pollinations took too long to respond.');
    } on http.ClientException {
      throw const FormatException('Couldn’t connect to Pollinations.');
    } finally {
      if (client == null) transport.close();
    }
  }

  static Future<Uint8List> _bounded(
      http.StreamedResponse response, int limit) async {
    if ((response.contentLength ?? 0) > limit) {
      throw const FormatException('Pollinations returned too much data.');
    }
    final output = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (output.length + chunk.length > limit) {
        throw const FormatException('Pollinations returned too much data.');
      }
      output.add(chunk);
    }
    return output.takeBytes();
  }

  static String? _imageExtension(Uint8List bytes) {
    if (bytes.length < 12) return null;
    bool at(int index, List<int> signature) =>
        Iterable<int>.generate(signature.length)
            .every((offset) => bytes[index + offset] == signature[offset]);
    if (at(0, [0xff, 0xd8, 0xff])) return 'jpg';
    if (at(0, [137, 80, 78, 71, 13, 10, 26, 10])) return 'png';
    if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'webp';
    return null;
  }

  Future<Uint8List> _request(http.Client client, Uri uri) async {
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await client.send(request);
    final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
    if (response.statusCode == 429 ||
        (response.statusCode == 402 && retryAfter != null)) {
      final wait = retryAfter == null ? 'later' : 'in $retryAfter seconds';
      throw FormatException(
          'Pollinations is rate-limiting anonymous requests. Try again $wait.');
    }
    if (response.statusCode == 401 ||
        response.statusCode == 402 ||
        response.statusCode == 403) {
      throw const FormatException(
          'Pollinations declined anonymous image generation for this request.');
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
