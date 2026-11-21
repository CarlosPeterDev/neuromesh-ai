import '../utils/output_links.dart';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../controllers/model_controller.dart';
import '../utils/page_text.dart';
import '../utils/model_file_role.dart';
import 'agent_service.dart';
import 'voice_models.dart';
import 'voice_service.dart';

/// Extra tools that work in every build (no Linux needed): fetching files,
/// HTTP requests, archives, searching the workspace and a model overview.
void registerExtraTools(AgentService agent) {
  String nameOf(File f) => f.path.split('/').last;

  Future<File> newFile(String name) async {
    final file = await agent.newWorkspaceFile(name);
    if (await file.exists()) {
      throw StateError('The destination already exists. Choose a new name.');
    }
    return file;
  }

  String size(int b) => b > 1048576
      ? '${(b / 1048576).toStringAsFixed(1)} MB'
      : '${(b / 1024).ceil()} KB';

  agent.addTool(AgentTool(
    'models_status',
    'Show which AI models are installed and ready: chat models, listening (speech to text) and speaking (text to speech). Use this to check voice choices for text_to_speech and transcribe_audio.',
    '{}',
    (args) async {
      final mc = Get.find<ModelController>();
      final vs = Get.find<VoiceModelStore>();
      final v = Get.find<VoiceService>();
      final b = StringBuffer();
      b.writeln(
          'Chat model loaded now: ${mc.lastLoadedModelName.isEmpty ? '(none)' : mc.lastLoadedModelName}');
      final files = mc.downloadedFiles.toList();
      for (final file in files.take(30)) {
        b.writeln('$file — ${modelFileRole(file).label}');
      }
      b.writeln(
          'Downloaded models (${files.length}): ${files.isEmpty ? 'none' : files.take(30).join(', ')}');
      final voiceModels = kVoiceModels
          .where((m) => !m.clone && vs.installed.contains(m.id))
          .toList();
      for (final (kind, heading, loaded) in [
        (VoiceKind.stt, 'Listening models', v.sttReady),
        (VoiceKind.tts, 'Speaking models', v.ttsReady),
      ]) {
        final entries = voiceModels.where((m) => m.kind == kind).map((m) =>
            '${m.id} — ${m.title} [${m.lang}]${m.speakers.isEmpty ? '' : '; speakers: ${m.speakers.join(', ')}'}');
        b.writeln(
            '$heading: ${entries.isEmpty ? 'NONE (download in Models → Voice)' : entries.join('\n')}${loaded ? '\nRuntime loaded' : ''}');
      }
      b.writeln(
          'System TTS file synthesis available: ${v.systemFileTtsAvailable.value}. Use model_id omitted for the default local/system voice.');
      b.writeln('Image generation: Pollinations online (internet required).');
      return b.toString().trim();
    },
  ));

  agent.addTool(AgentTool(
    'download_file',
    'Download a file from a web address (image, PDF, audio, zip, data…) into your workspace. Up to 200 MB.',
    '{"url":"https://...","name":"optional file name to save as"}',
    (args) async {
      final uri = Uri.tryParse((args['url'] ?? '').toString());
      if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http'))
        return 'Error: give a full http(s) URL.';
      var name = (args['name'] ?? '').toString().trim();
      if (name.isEmpty) {
        name = uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty
            ? uri.pathSegments.last
            : 'download.bin';
      }
      final client = http.Client();
      try {
        final res = await client.send(http.Request('GET', uri)
          ..headers['User-Agent'] =
              'Mozilla/5.0 (Linux; Android 14) NeuroMeshAI');
        if (res.statusCode != 200)
          return 'Error: server answered ${res.statusCode}.';
        final f = await newFile(name);
        final sink = f.openWrite();
        var n = 0;
        try {
          await for (final chunk
              in res.stream.timeout(const Duration(seconds: 60))) {
            n += chunk.length;
            if (n > 200 * 1048576) {
              await sink.close();
              await f.delete();
              return 'Error: the file is larger than 200 MB.';
            }
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        return 'Saved ${nameOf(f)} (${size(n)}). Show it with [📎 ${nameOf(f)}](${outputFileUri(nameOf(f))}).';
      } catch (e) {
        return 'Error: download failed: $e';
      } finally {
        client.close();
      }
    },
    needsConfirm: true,
  ));

  agent.addTool(AgentTool(
    'http_request',
    'Call a web API: any method, headers and body. Returns the status and the response text. Use it for REST APIs and webhooks.',
    '{"method":"GET|POST|PUT|PATCH|DELETE","url":"https://...","headers":"optional JSON object","body":"optional text or JSON string"}',
    (args) async {
      final uri = Uri.tryParse((args['url'] ?? '').toString());
      if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http'))
        return 'Error: give a full http(s) URL.';
      final method = (args['method'] ?? 'GET').toString().toUpperCase();
      final headers = <String, String>{'User-Agent': 'NeuroMeshAI'};
      final h = args['headers'];
      try {
        final m = h is Map
            ? h
            : (h is String && h.trim().isNotEmpty ? jsonDecode(h) : null);
        if (m is Map) {
          for (final e in m.entries) {
            headers['${e.key}'] = '${e.value}';
          }
        }
      } catch (_) {
        return 'Error: "headers" must be a JSON object.';
      }
      final bodyArg = args['body'];
      final body = bodyArg == null
          ? null
          : (bodyArg is String ? bodyArg : jsonEncode(bodyArg));
      if (body != null &&
          !headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
        headers['Content-Type'] = 'application/json';
      }
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = body;
      try {
        final streamed =
            await http.Client().send(req).timeout(const Duration(seconds: 30));
        final res = await http.Response.fromStream(streamed);
        var text = utf8.decode(res.bodyBytes, allowMalformed: true);
        if ((res.headers['content-type'] ?? '').contains('html'))
          text = readableText(text);
        if (text.length > 6000)
          text =
              '${text.substring(0, 6000)}\n… (${text.length} characters; cut)';
        return 'HTTP ${res.statusCode}\n$text';
      } catch (e) {
        return 'Error: request failed: $e';
      }
    },
    needsConfirm: true,
  ));

  agent.addTool(AgentTool(
    'copy_file',
    'Copy a workspace file to a new name.',
    '{"name":"existing file","to":"new file name"}',
    (args) async {
      final src = await agent.workspaceFile((args['name'] ?? '').toString());
      if (src == null) return 'Error: no such file. Use list_files.';
      final dst = await newFile((args['to'] ?? '').toString());
      await src.copy(dst.path);
      return 'Copied to ${nameOf(dst)}.';
    },
  ));

  agent.addTool(AgentTool(
    'rename_file',
    'Rename a workspace file.',
    '{"name":"existing file","to":"new file name"}',
    (args) async {
      final src = await agent.workspaceFile((args['name'] ?? '').toString());
      if (src == null) return 'Error: no such file. Use list_files.';
      final dst = await newFile((args['to'] ?? '').toString());
      await src.rename(dst.path);
      return 'Renamed to ${nameOf(dst)}.';
    },
  ));

  agent.addTool(AgentTool(
    'search_workspace',
    'Search every workspace file by name and by text inside it. Returns matching file names with the matching lines.',
    '{"query":"text to find"}',
    (args) async {
      final q = (args['query'] ?? '').toString().toLowerCase().trim();
      if (q.isEmpty) return 'Error: empty query.';
      final out = <String>[];
      for (final e in (await agent.filesDir())
          .listSync(followLinks: false)
          .whereType<File>()) {
        final n = nameOf(e);
        if (n.toLowerCase().contains(q)) out.add('$n  (name matches)');
        if (e.lengthSync() > 2 * 1048576) continue;
        try {
          final lines = const LineSplitter().convert(await e.readAsString());
          var hits = 0;
          for (var i = 0; i < lines.length && hits < 3; i++) {
            if (lines[i].toLowerCase().contains(q)) {
              final l = lines[i].trim();
              out.add(
                  '$n:${i + 1}: ${l.length > 160 ? '${l.substring(0, 160)}…' : l}');
              hits++;
            }
          }
        } catch (_) {}
        if (out.length > 40) break;
      }
      return out.isEmpty ? 'No matches.' : out.join('\n');
    },
  ));

  agent.addTool(AgentTool(
    'zip_files',
    'Put several workspace files into one .zip file.',
    '{"names":"comma-separated file names","output":"archive name ending in .zip"}',
    (args) async {
      final names = (args['names'] ?? '')
          .toString()
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
      var out = (args['output'] ?? 'archive.zip').toString();
      if (!out.toLowerCase().endsWith('.zip')) out = '$out.zip';
      final enc = ZipFileEncoder();
      final dst = await newFile(out);
      enc.create(dst.path);
      var n = 0;
      for (final name in names) {
        final f = await agent.workspaceFile(name);
        if (f == null) continue;
        await enc.addFile(f);
        n++;
      }
      await enc.close();
      if (n == 0) {
        await dst.delete();
        return 'Error: none of those files exist. Use list_files.';
      }
      return 'Created ${nameOf(dst)} with $n file(s) (${size(dst.lengthSync())}). Show it with [📎 ${nameOf(dst)}](${outputFileUri(nameOf(dst))}).';
    },
  ));

  agent.addTool(AgentTool(
    'unzip_file',
    'Extract a .zip or .tar.gz from the workspace. Files are saved in the workspace with their folder path joined by "_".',
    '{"name":"archive file name"}',
    (args) async {
      final f = await agent.workspaceFile((args['name'] ?? '').toString());
      if (f == null) return 'Error: no such file. Use list_files.';
      final bytes = await f.readAsBytes();
      final lower = f.path.toLowerCase();
      Archive a;
      try {
        a = lower.endsWith('.tar.gz') || lower.endsWith('.tgz')
            ? TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes))
            : ZipDecoder().decodeBytes(bytes);
      } catch (e) {
        return 'Error: could not open the archive: $e';
      }
      final saved = <String>[];
      for (final e in a) {
        if (!e.isFile || saved.length >= 300) continue;
        final flat = e.name
            .replaceAll(RegExp(r'[\\/]+'), '_')
            .replaceAll(RegExp(r'[^\w.\- ]'), '_');
        if (flat.isEmpty || flat.startsWith('.')) continue;
        final out = await newFile(flat);
        await out.writeAsBytes(e.content as List<int>);
        saved.add(nameOf(out));
      }
      return saved.isEmpty
          ? '(the archive is empty)'
          : 'Extracted ${saved.length} file(s): ${saved.take(40).join(', ')}';
    },
  ));
}
