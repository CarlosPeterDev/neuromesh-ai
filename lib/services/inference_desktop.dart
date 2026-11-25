import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'inference_android.dart' show LoadResult;

bool get isDesktopPlatform => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Windows / Linux / macOS engine: runs the bundled `llama-server` (llama.cpp)
/// next to the app and talks to it over a private loopback connection.
class DesktopEngine {
  Process? _proc;
  int _port = 0;
  HttpClient? _http;
  bool visionLoaded = false;
  int contextSize = 0;
  final _log = <String>[];

  static String? findServer() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? 'llama-server.exe' : 'llama-server';
    final sep = Platform.pathSeparator;
    for (final d in [
      '$exeDir${sep}llama',
      exeDir,
      '$exeDir${sep}data${sep}llama',
      '$exeDir${sep}lib${sep}llama',
      if (!Platform.isWindows) '/usr/local/bin',
      if (!Platform.isWindows) '/usr/bin',
    ]) {
      final f = File('$d$sep$name');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  Future<LoadResult> loadModel({
    required String modelPath,
    required int contextSize,
    String? mmprojPath,
    void Function(double)? onProgress,
  }) async {
    await dispose();
    final bin = findServer();
    if (bin == null) {
      return LoadResult(
          success: false,
          message: 'ERROR: llama-server was not found next to the app. '
              'Reinstall the desktop build, or put llama-server in the "llama" folder beside the app.');
    }
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = probe.port;
    await probe.close();
    this.contextSize = contextSize;
    final threads = Platform.numberOfProcessors > 2 ? Platform.numberOfProcessors - 1 : 2;
    final args = [
      '-m', modelPath,
      '-c', '$contextSize',
      '--host', '127.0.0.1',
      '--port', '$_port',
      '-t', '$threads',
      '--no-webui',
      if (mmprojPath != null && mmprojPath.isNotEmpty) ...['--mmproj', mmprojPath],
    ];
    try {
      _log.clear();
      _proc = await Process.start(bin, args, workingDirectory: File(bin).parent.path);
    } catch (e) {
      return LoadResult(success: false, message: 'ERROR: could not start llama-server: $e');
    }
    void keep(List<int> b) {
      for (final l in utf8.decode(b, allowMalformed: true).split('\n')) {
        if (l.trim().isEmpty) continue;
        _log.add(l);
        if (_log.length > 40) _log.removeAt(0);
      }
    }

    _proc!.stdout.listen(keep);
    _proc!.stderr.listen(keep);
    var exited = false;
    unawaited(_proc!.exitCode.then((_) => exited = true));

    final started = DateTime.now();
    final probeClient = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      while (DateTime.now().difference(started).inMinutes < 15) {
        if (exited) {
          return LoadResult(
              success: false,
              message: 'ERROR: llama-server stopped while loading the model.\n${_log.reversed.take(6).toList().reversed.join('\n')}');
        }
        try {
          final req = await probeClient.getUrl(Uri.parse('http://127.0.0.1:$_port/health'));
          final res = await req.close();
          await res.drain<void>();
          if (res.statusCode == 200) {
            onProgress?.call(1.0);
            visionLoaded = mmprojPath != null && mmprojPath.isNotEmpty;
            return LoadResult(success: true, message: 'Loaded', runtime: 'llama-server', backend: 'cpu');
          }
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 700));
      }
    } finally {
      probeClient.close(force: true);
    }
    await dispose();
    return LoadResult(success: false, message: 'ERROR: the model took too long to load.');
  }

  Future<String> generate({
    required String prompt,
    List<Map<String, String>>? conversationHistory,
    required String systemPrompt,
    required int maxTokens,
    required double temperature,
    String? imagePath,
    bool normalThinking = false,
    bool rawCompletion = false,
    void Function(String token)? onToken,
  }) async {
    if (_proc == null) return 'ERROR: no model is loaded.';
    if (imagePath != null && imagePath.isNotEmpty && !visionLoaded) {
      return 'ERROR: Load this model with its vision helper to read images.';
    }
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      for (final m in conversationHistory ?? const <Map<String, String>>[])
        {'role': m['role'], 'content': m['content']},
    ];
    dynamic userContent = prompt;
    if (imagePath != null && imagePath.isNotEmpty && visionLoaded) {
      final bytes = await File(imagePath).readAsBytes();
      final ext = imagePath.split('.').last.toLowerCase();
      final mime = ext == 'png' ? 'image/png' : 'image/jpeg';
      userContent = [
        {'type': 'text', 'text': prompt},
        {'type': 'image_url', 'image_url': {'url': 'data:$mime;base64,${base64Encode(bytes)}'}},
      ];
    }
    // The caller already put the new message last in the history when it
    // matches the prompt; avoid sending it twice.
    if (messages.length > 1 && messages.last['role'] == 'user' && messages.last['content'] == prompt) {
      messages.removeLast();
    }
    messages.add({'role': 'user', 'content': userContent});

    final client = HttpClient();
    _http = client;
    final out = StringBuffer();
    try {
      final endpoint = rawCompletion ? '/completion' : '/v1/chat/completions';
      final req =
          await client.postUrl(Uri.parse('http://127.0.0.1:$_port$endpoint'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(rawCompletion
          ? {
              'prompt': prompt,
              'stream': true,
              'n_predict': maxTokens,
              'temperature': 0.0,
              'repeat_penalty': 1.0
            }
          : {
              'messages': messages,
              'stream': true,
              'chat_template_kwargs': {'enable_thinking': normalThinking},
              'max_tokens': maxTokens,
              'temperature': temperature,
            })));
      final res = await req.close();
      if (res.statusCode != 200) {
        final body = await utf8.decodeStream(res);
        return 'ERROR: llama-server replied ${res.statusCode}: $body';
      }
      var buf = '';
      await for (final chunk in res.transform(utf8.decoder)) {
        buf += chunk;
        final lines = buf.split('\n');
        buf = lines.removeLast();
        for (final l in lines) {
          if (!l.startsWith('data:')) continue;
          final d = l.substring(5).trim();
          if (d == '[DONE]') continue;
          try {
            final j = jsonDecode(d) as Map<String, dynamic>;
            final delta = rawCompletion
                ? j['content']
                : (((j['choices'] as List?)?.first as Map?)?['delta']
                    as Map?)?['content'];
            if (delta is String && delta.isNotEmpty) {
              out.write(delta);
              onToken?.call(delta);
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      if (out.isEmpty) return 'ERROR: $e';
    } finally {
      client.close(force: true);
      if (identical(_http, client)) _http = null;
    }
    return out.toString();
  }

  Future<void> stop() async {
    _http?.close(force: true); // llama-server stops when the connection drops
    _http = null;
  }

  Future<void> dispose() async {
    await stop();
    final p = _proc;
    _proc = null;
    visionLoaded = false;
    if (p != null) {
      p.kill();
      try {
        await p.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        p.kill(ProcessSignal.sigkill);
      }
    }
  }
}
