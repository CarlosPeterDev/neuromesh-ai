import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/bm25.dart';
import '../utils/page_text.dart';
import '../utils/web_search_parse.dart';
import '../widgets/ask_user.dart';
import 'agent_tools.dart';
import 'device_bridge.dart';
import '../controllers/model_controller.dart';
import 'local_image_service.dart';
import 'scheduler_service.dart';
import 'voice_service.dart';
import 'document_extractor_service.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'mcp_client.dart';
import 'user_files.dart';
import 'web_search_service.dart';

/// Asks the user whether a tool may run. Returns true to allow.
typedef ToolConfirm = Future<bool> Function(
    String toolName, String serverName, Map<String, dynamic> args);

/// A tool the model can call. Built-in tools live in this file; other
/// services (like the Linux sandbox) register theirs with [AgentService.addTool].
class AgentTool {
  final String name;
  final String description;
  final String params;
  final FutureOr<String> Function(Map<String, dynamic> args) run;

  /// Reaches outside the app's own data (network, the user's files, a shell),
  /// so the user is asked first.
  final bool needsConfirm;

  /// Whether the tool should be offered to the model right now.
  final bool Function()? available;

  const AgentTool(this.name, this.description, this.params, this.run,
      {this.needsConfirm = false, this.available});
}

/// Result of one chat turn that may have used tools.
class ToolLoopResult {
  /// The model's final answer.
  final String answer;

  /// One short markdown line per tool the model used.
  final List<String> trace;
  final bool hitLimit;
  const ToolLoopResult(this.answer, this.trace, this.hitLimit);

  /// Marker so trace lines can be stripped out of the history sent back to
  /// the model on later turns.
  static const traceMark = '> 🔧 ';

  String get markdown => trace.isEmpty ? answer : '${trace.join('\n')}\n\n$answer';
}

/// Removes tool-trace lines from a saved assistant message.
String stripToolTrace(String content) => content
    .split('\n')
    .where((l) => !l.startsWith(ToolLoopResult.traceMark))
    .join('\n')
    .trimLeft();

enum AgentChatMode { auto, always, off }

/// Lets the chat model use tools: files, memory, the web, MCP servers and
/// (in the Pro build) a Linux sandbox. It is part of normal chat: when the
/// model needs a tool it calls it, then keeps answering.
class AgentService extends GetxService {
  static const _serversKey = 'mcp_servers';
  static const _memoryKey = 'agent_memory';
  static const _allowKey = 'agent_always_allow'; // legacy, migrated
  static const _policyKey = 'agent_tool_policy';
  static const _modeKey = 'agent_chat_mode';
  static const _autoMemKey = 'agent_auto_memory';
  static const maxSteps = 20;
  static const maxMemory = 60;

  final HiveService _hive = Get.find<HiveService>();

  final servers = <McpServerConfig>[].obs;
  final serverStatus = <String, String>{}.obs;
  final _tools = <String, List<McpTool>>{};
  final toolsVersion = 0.obs; // bumps when a server's tool list changes
  final memory = <String>[].obs;
  /// Per-tool choice: 'allow' (never ask), 'ask' (always ask) or 'block'.
  /// Key is "server::tool". Tools with no entry use their default.
  final policy = <String, String>{}.obs;
  final mode = AgentChatMode.auto.obs;
  final autoMemory = true.obs;
  final _extra = <AgentTool>[];
  bool _cancel = false;

  // ── workspace (private folder; attachments are copied here) ──────────

  Future<Directory> filesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/agent_files');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Only plain file names inside the agent folder are allowed.
  Future<File> _safeFile(String name) async {
    final n = name.split('/').last.split('\\').last;
    if (n.isEmpty || n.startsWith('.')) throw Exception('Invalid file name');
    return File('${(await filesDir()).path}/$n');
  }

  /// Copies a file the user attached into the workspace so tools can read it.
  /// Returns the name it can be read by.
  Future<String> importToWorkspace(String sourcePath, String name) async {
    var clean = name.split('/').last.split('\\').last.replaceAll(RegExp(r'[^\w.\- ]'), '_');
    if (clean.isEmpty || clean.startsWith('.')) clean = 'file_$clean';
    final dir = await filesDir();
    var dest = File('${dir.path}/$clean');
    var i = 1;
    while (await dest.exists()) {
      final dot = clean.lastIndexOf('.');
      final base = dot > 0 ? clean.substring(0, dot) : clean;
      final ext = dot > 0 ? clean.substring(dot) : '';
      dest = File('${dir.path}/${base}_$i$ext');
      i++;
    }
    await File(sourcePath).copy(dest.path);
    return dest.path.split('/').last;
  }

  Future<void> deleteWorkspaceFile(String name) async {
    final f = await _safeFile(name);
    if (await f.exists()) await f.delete();
  }

  // ── memory ───────────────────────────────────────────────────────────

  Future<void> addNote(String note) async {
    final n = note.trim();
    if (n.isEmpty) return;
    if (memory.contains(n)) return;
    memory.add(n.length > 300 ? n.substring(0, 300) : n);
    while (memory.length > maxMemory) {
      memory.removeAt(0);
    }
    await _saveMemory();
  }

  Future<void> removeNote(String note) async {
    memory.remove(note);
    await _saveMemory();
  }

  Future<void> editNote(String old, String updated) async {
    final i = memory.indexOf(old);
    if (i < 0 || updated.trim().isEmpty) return;
    memory[i] = updated.trim();
    await _saveMemory();
  }

  Future<void> clearMemory() async {
    memory.clear();
    await _saveMemory();
  }

  Future<void> _saveMemory() => _hive.setSetting(_memoryKey, memory.toList());

  /// Handles "remember that …" without involving the model. Returns the saved
  /// note, or null when the message isn't an explicit memory request.
  Future<String?> rememberDirect(String text) async {
    if (!autoMemory.value) return null;
    final m = RegExp(
            r'^\s*(?:please\s+)?(?:remember|note|save|keep in mind)(?:\s+that)?[\s:,-]+(.{3,300})$',
            caseSensitive: false,
            dotAll: true)
        .firstMatch(text);
    final ar = RegExp(r'^\s*(?:تذكر|افتكر|احفظ)(?:\s+إن|\s+ان|\s+أن)?[\s:،-]+(.{3,300})$',
            dotAll: true)
        .firstMatch(text);
    final note = (m ?? ar)?.group(1)?.trim();
    if (note == null || note.endsWith('?') || note.endsWith('؟')) return null;
    await addNote(note);
    return note;
  }

  Future<void> setAutoMemory(bool v) async {
    autoMemory.value = v;
    await _hive.setSetting(_autoMemKey, v);
  }

  /// Notes block added to the system prompt of every chat.
  String memoryBlock() {
    if (memory.isEmpty) return '';
    final b = StringBuffer('Things to remember about the user (saved by them or by you earlier):\n');
    for (final n in memory.reversed.take(25).toList().reversed) {
      b.writeln('- $n');
    }
    return b.toString().trimRight();
  }

  // ── permissions ──────────────────────────────────────────────────────

  static String keyOf(String server, String tool) => '$server::$tool';

  Future<void> setPolicy(String server, String tool, String value) async {
    final k = keyOf(server, tool);
    if (value == 'default') {
      policy.remove(k);
    } else {
      policy[k] = value;
    }
    await _hive.setSetting(_policyKey, Map<String, String>.from(policy));
  }

  Future<void> allowAlwaysFor(String server, String tool) =>
      setPolicy(server, tool, 'allow');

  Future<void> resetPolicies() async {
    policy.clear();
    await _hive.setSetting(_policyKey, <String, String>{});
  }

  /// What happens when the model calls this tool.
  String policyFor(String server, String tool, {required bool needsConfirm}) {
    final p = policy[keyOf(server, tool)];
    if (p == 'allow' || p == 'ask' || p == 'block') return p!;
    return needsConfirm ? 'ask' : 'allow';
  }

  Future<void> setMode(AgentChatMode m) async {
    mode.value = m;
    await _hive.setSetting(_modeKey, m.name);
  }

  void addTool(AgentTool t) {
    _extra.removeWhere((e) => e.name == t.name);
    _extra.add(t);
  }

  // ── built-in tools ───────────────────────────────────────────────────

  UserFilesService? get _user =>
      Get.isRegistered<UserFilesService>() ? Get.find<UserFilesService>() : null;

  bool get _hasFolders => _user != null && _user!.folders.isNotEmpty;

  String _page(String text, int start, {int size = 4000}) {
    if (start < 0) start = 0;
    if (start >= text.length) return '(end of file)';
    final end = (start + size).clamp(0, text.length);
    final part = text.substring(start, end);
    return end < text.length
        ? '$part\n…(characters $start-$end of ${text.length}; call again with "start": $end for more)'
        : part;
  }

  static String _magic(List<int> b) {
    bool starts(List<int> m) =>
        b.length >= m.length && List.generate(m.length, (i) => b[i] == m[i]).every((x) => x);
    if (starts([0x25, 0x50, 0x44, 0x46])) return 'PDF document';
    if (starts([0x50, 0x4B, 3, 4])) return 'ZIP archive (or docx/xlsx/apk/jar)';
    if (starts([0x89, 0x50, 0x4E, 0x47])) return 'PNG image';
    if (starts([0xFF, 0xD8, 0xFF])) return 'JPEG image';
    if (starts([0x47, 0x49, 0x46])) return 'GIF image';
    if (starts([0x7F, 0x45, 0x4C, 0x46])) return 'ELF executable';
    if (starts([0x1F, 0x8B])) return 'gzip data';
    if (starts([0x47, 0x47, 0x55, 0x46])) return 'GGUF model file';
    if (starts([0x53, 0x51, 0x4C, 0x69])) return 'SQLite database';
    return looksBinary(b) ? 'binary data' : 'text';
  }

  /// Text of a workspace file, whatever its type.
  Future<String> _textOfWorkspaceFile(File f) async {
    final name = f.path.split('/').last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (ext == 'pdf' || ext == 'docx') {
      return DocumentExtractorService.extractText(f.path, ext);
    }
    final bytes = await f.readAsBytes();
    if (ext == 'zip' || ext == 'jar' || ext == 'apk' || ext == 'xlsx' || ext == 'pptx') {
      final arch = ZipDecoder().decodeBytes(bytes);
      final b = StringBuffer('Archive with ${arch.files.length} entries:\n');
      for (final e in arch.files.take(200)) {
        b.writeln('${e.isFile ? '' : '[dir] '}${e.name}${e.isFile ? ' (${e.size} bytes)' : ''}');
      }
      return b.toString();
    }
    if (looksBinary(bytes)) {
      final head = bytes.take(48).map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
      return '(${_magic(bytes)}, ${bytes.length} bytes; not readable as text)\nFirst bytes: $head';
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  late final List<AgentTool> _builtIns = [
    AgentTool(
      'calculator',
      'Evaluate an arithmetic expression exactly.',
      '{"expression":"string, e.g. (12+3)*4/5"}',
      (args) => formatNumber(evaluateExpression((args['expression'] ?? '').toString())),
    ),
    AgentTool(
      'current_time',
      'Get the phone\'s current local date and time.',
      '{}',
      (args) => DateTime.now().toString(),
    ),
    AgentTool(
      'remember',
      'Save a short fact about the user or their preferences so you remember it in future chats.',
      '{"note":"string"}',
      (args) async {
        await addNote((args['note'] ?? '').toString());
        return 'Saved.';
      },
    ),
    AgentTool(
      'forget',
      'Delete saved notes that contain the given text.',
      '{"contains":"string"}',
      (args) async {
        final q = (args['contains'] ?? '').toString().toLowerCase().trim();
        if (q.isEmpty) return 'Error: say what to forget.';
        final hits = memory.where((n) => n.toLowerCase().contains(q)).toList();
        for (final n in hits) {
          await removeNote(n);
        }
        return hits.isEmpty ? 'Nothing matched.' : 'Forgot ${hits.length} note(s).';
      },
    ),
    AgentTool(
      'ask_user',
      'Ask the user a question when you need a decision or missing detail before continuing. Prefer this over guessing.',
      '{"question":"string","options":"optional list of short choices"}',
      (args) async {
        final o = args['options'];
        final opts = o is List
            ? o.map((e) => e.toString()).toList()
            : (o is String && o.trim().isNotEmpty
                ? o.split(RegExp(r'\s*[,|/]\s*'))
                : <String>[]);
        return askUserDialog((args['question'] ?? '').toString(), opts);
      },
    ),
    AgentTool(
      'device_status',
      'Read the phone\'s battery, charging state, temperature, free storage, memory and network type. Read-only.',
      '{}',
      (args) async {
        final m = await Get.find<DeviceBridge>().status();
        if (m.isEmpty) return 'Phone status is not available.';
        String gb(num? b) => b == null ? '?' : '${(b / 1073741824).toStringAsFixed(1)} GB';
        return [
          'Device: ${m['model']} (Android ${m['android']}, ${m['cores']} cores)',
          'Battery: ${m['level']}%${m['charging'] == true ? ' (charging)' : ''}${m['saver'] == true ? ', battery saver on' : ''}',
          'Thermal status: ${m['thermal']} (0 normal, 3+ hot)',
          'Storage free: ${gb(m['storageFree'] as num?)} of ${gb(m['storageTotal'] as num?)}',
          'Memory free: ${gb(m['ramFree'] as num?)} of ${gb(m['ramTotal'] as num?)}',
          'Network: ${m['network']}${m['metered'] == true ? ' (metered)' : ''}',
          'Local time: ${DateTime.now()}',
        ].join('\n');
      },
    ),
    AgentTool(
      'transcribe_audio',
      'Turn a workspace audio file (mp3, m4a, ogg, wav, video) into text with the on-device speech model.',
      '{"name":"audio file name","language":"optional code such as en or ar"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final t = await Get.find<VoiceService>()
            .transcribeFile(f.path, language: (args['language'] ?? '').toString());
        return t.isEmpty ? '(no speech found)' : _page(t, 0);
      },
    ),
    AgentTool(
      'text_to_speech',
      'Speak text with the on-device voice model and save it as a WAV file in the workspace. Show it to the user with [📎 name](nmfile:name).',
      '{"text":"string","name":"output file name ending in .wav"}',
      (args) async {
        var name = (args['name'] ?? 'speech.wav').toString();
        if (!name.toLowerCase().endsWith('.wav')) name = '$name.wav';
        final wav = await Get.find<VoiceService>().synthesizeToWav((args['text'] ?? '').toString());
        final f = await _safeFile(name);
        await f.writeAsBytes(wav);
        return 'Saved ${f.path.split('/').last} (${wav.length ~/ 1024} KB). Show it with [📎 ${f.path.split('/').last}](nmfile:${f.path.split('/').last}).';
      },
    ),
    AgentTool(
      'schedule_task',
      'Schedule a prompt to run automatically later or repeatedly. when examples: "in 30 minutes", "daily 08:00", "every 2 hours", "weekly mon,thu 09:00", "once 2026-12-01 18:30".',
      '{"title":"string","prompt":"what to do when it runs","when":"string"}',
      (args) async {
        final s = Get.find<SchedulerService>();
        final t = parseWhen((args['when'] ?? '').toString(),
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            title: (args['title'] ?? 'Task').toString(),
            prompt: (args['prompt'] ?? '').toString());
        if (t == null || t.prompt.trim().isEmpty) {
          return 'Error: could not understand "when". Use forms like "daily 08:00" or "in 30 minutes".';
        }
        s.upsert(t);
        return 'Scheduled "${t.title}": ${t.whenText}.';
      },
      needsConfirm: true,
    ),
    AgentTool(
      'list_schedules',
      'List the scheduled tasks.',
      '{}',
      (args) async {
        final s = Get.find<SchedulerService>();
        if (s.tasks.isEmpty) return '(no scheduled tasks)';
        return s.tasks
            .map((t) => '${t.id}: ${t.title} — ${t.whenText}${t.enabled ? '' : ' (off)'}')
            .join('\n');
      },
    ),
    AgentTool(
      'cancel_schedule',
      'Delete a scheduled task by id (from list_schedules).',
      '{"id":"string"}',
      (args) async {
        final s = Get.find<SchedulerService>();
        final id = (args['id'] ?? '').toString();
        if (!s.tasks.any((t) => t.id == id)) return 'Error: unknown id.';
        s.remove(id);
        return 'Deleted.';
      },
      needsConfirm: true,
    ),
    AgentTool(
      'generate_image',
      'Create an image from a text description with the on-device image model. Takes a while on a phone. Write the prompt in English, describing subject, style and lighting. Show the result with ![short description](nmfile:name).',
      '{"prompt":"detailed English description","name":"output file name ending in .png"}',
      (args) async {
        final prompt = (args['prompt'] ?? '').toString().trim();
        if (prompt.isEmpty) return 'Error: empty prompt.';
        final mc = Get.find<ModelController>();
        final img = Get.find<LocalImageService>();
        final inf = Get.find<InferenceService>();
        final imgName = img.lastModelName ?? '';
        if (imgName.isEmpty || !mc.isDownloaded(imgName)) {
          return 'Error: no image model is installed. Ask the user to download one in Models → Image models.';
        }
        final textName = mc.lastLoadedModelName;
        var name = (args['name'] ?? 'image_${DateTime.now().millisecondsSinceEpoch}.png').toString();
        if (!name.toLowerCase().endsWith('.png')) name = '$name.png';
        try {
          // Phone memory holds one model at a time: swap the chat model out,
          // draw, then bring it back.
          await inf.unloadModel();
          if (!img.isModelLoaded.value) {
            await mc.loadModel(imgName);
            for (var i = 0; i < 600 && img.isLoadingModel.value; i++) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          }
          if (!img.isModelLoaded.value) {
            return 'Error: the image model could not be loaded (not enough memory?).';
          }
          final bytes = await img.generateImage(prompt: prompt);
          if (bytes == null || bytes.isEmpty) return 'Error: the image model produced nothing.';
          final f = await _safeFile(name);
          await f.writeAsBytes(bytes);
          final n = f.path.split('/').last;
          return 'Saved $n. Show it to the user with ![${prompt.length > 40 ? prompt.substring(0, 40) : prompt}](nmfile:$n)';
        } finally {
          await img.unloadModel();
          if (textName.isNotEmpty && !inf.isModelLoaded.value) {
            await mc.loadModel(textName);
            for (var i = 0; i < 600 && inf.isLoadingModel.value; i++) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          }
        }
      },
    ),
    AgentTool(
      'list_files',
      'List the files in your workspace (files the user attached are here).',
      '{}',
      (args) async {
        final out = <String>[];
        for (final f in (await filesDir()).listSync().whereType<File>()) {
          out.add('${f.path.split('/').last} (${f.lengthSync()} bytes)');
        }
        return out.isEmpty ? '(no files)' : out.join('\n');
      },
    ),
    AgentTool(
      'file_info',
      'Show the size and detected type of a workspace file.',
      '{"name":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final bytes = await f.openRead(0, 64).expand((x) => x).toList();
        return '${f.path.split('/').last}: ${await f.length()} bytes, ${_magic(bytes)}';
      },
    ),
    AgentTool(
      'read_file',
      'Read a workspace file. Works for text, code, PDF, DOCX and zip listings; binary files return a summary.',
      '{"name":"string","start":"optional character offset"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final text = await _textOfWorkspaceFile(f);
        return _page(text, int.tryParse('${args['start'] ?? 0}') ?? 0);
      },
    ),
    AgentTool(
      'search_in_file',
      'Find the passages of a workspace file that best match a query. Use this for big files.',
      '{"name":"string","query":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final text = await _textOfWorkspaceFile(f);
        final chunks = chunkText(text, size: 700, overlap: 80);
        final top = bm25Top(chunks, (args['query'] ?? '').toString(), k: 4);
        if (top.isEmpty) return 'No matching passages.';
        return top.map((i) => '[passage ${i + 1}/${chunks.length}]\n${chunks[i]}').join('\n\n');
      },
    ),
    AgentTool(
      'write_file',
      'Create or overwrite a text file in your workspace.',
      '{"name":"string","content":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        await f.writeAsString((args['content'] ?? '').toString());
        return 'Wrote ${f.path.split('/').last}.';
      },
    ),
    AgentTool(
      'append_file',
      'Add text to the end of a workspace file (creates it if missing).',
      '{"name":"string","content":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        await f.writeAsString((args['content'] ?? '').toString(), mode: FileMode.append);
        return 'Appended to ${f.path.split('/').last}.';
      },
    ),
    AgentTool(
      'edit_file',
      'Change an existing workspace file by replacing exact text. Read the file first and copy the text exactly. Set "all":"true" to replace every match.',
      '{"name":"string","old":"exact text to find","new":"replacement text","all":"optional true"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: no such file. Use list_files to see the names.';
        final old = (args['old'] ?? '').toString();
        final nw = (args['new'] ?? '').toString();
        if (old.isEmpty) return 'Error: "old" must be the exact text to replace.';
        final text = await f.readAsString();
        final n = text.split(old).length - 1;
        if (n == 0) return 'Error: that text was not found. Use read_file and copy the exact text.';
        final all = '${args['all'] ?? ''}' == 'true';
        if (n > 1 && !all) return 'Error: the text appears $n times. Add more surrounding text, or set "all":"true".';
        await f.writeAsString(all ? text.replaceAll(old, nw) : text.replaceFirst(old, nw));
        return 'Edited ${f.path.split('/').last} ($n replacement${n == 1 ? '' : 's'}).';
      },
    ),
    AgentTool(
      'delete_file',
      'Delete a file from your workspace.',
      '{"name":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: no such file.';
        await f.delete();
        return 'Deleted ${f.path.split('/').last}.';
      },
      needsConfirm: true,
    ),
    AgentTool(
      'edit_user_file',
      'Change a text file inside a shared folder by replacing exact text (read it first with read_user_file). Set "all":"true" to replace every match.',
      '{"folder":"shared folder name","path":"file path","old":"exact text","new":"replacement","all":"optional true"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null) return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        final path = (args['path'] ?? '').toString();
        final old = (args['old'] ?? '').toString();
        final nw = (args['new'] ?? '').toString();
        if (old.isEmpty) return 'Error: "old" must be the exact text to replace.';
        final text = await u.readText(f, path, maxChars: 2000000);
        final n = text.split(old).length - 1;
        if (n == 0) return 'Error: that text was not found. Use read_user_file and copy the exact text.';
        final all = '${args['all'] ?? ''}' == 'true';
        if (n > 1 && !all) return 'Error: the text appears $n times. Add more surrounding text, or set "all":"true".';
        await u.writeText(f, path, all ? text.replaceAll(old, nw) : text.replaceFirst(old, nw));
        return 'Edited $path ($n replacement${n == 1 ? '' : 's'}).';
      },
      needsConfirm: true,
      available: () => _hasFolders,
    ),
    AgentTool(
      'tool_help',
      'Show the full description and arguments of one tool, or of every tool when "name" is empty.',
      '{"name":"optional tool name"}',
      (args) async {
        final q = (args['name'] ?? '').toString().trim();
        final all = [..._allBuiltIns, ..._enabledMcpTools.map((t) => AgentTool(t.qualifiedName, t.description, t.signature, (_) => ''))];
        final hit = q.isEmpty ? all : all.where((t) => t.name.contains(q)).toList();
        if (hit.isEmpty) return 'No tool matches "$q".';
        return hit.map((t) => '${t.name}: ${t.description}\narguments: ${t.params}').join('\n\n');
      },
    ),
    AgentTool(
      'list_folder',
      'List files and folders inside a folder the user shared with you.',
      '{"folder":"shared folder name","path":"optional sub-path"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null) return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        final items = await u.list(f, (args['path'] ?? '').toString());
        if (items.isEmpty) return '(empty)';
        return items.map((e) => '${e.isDir ? '[dir] ' : ''}${e.name}${e.isDir ? '' : ' (${e.size} bytes)'}').join('\n');
      },
      available: () => _hasFolders,
    ),
    AgentTool(
      'read_user_file',
      'Read a file from a folder the user shared with you (text, code, PDF, DOCX).',
      '{"folder":"shared folder name","path":"file path inside it","start":"optional character offset"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null) return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        final start = int.tryParse('${args['start'] ?? 0}') ?? 0;
        final text = await u.readText(f, (args['path'] ?? '').toString(), maxChars: start + 4000);
        return _page(text, start);
      },
      available: () => _hasFolders,
    ),
    AgentTool(
      'write_user_file',
      'Create or overwrite a text file inside a folder the user shared with you.',
      '{"folder":"shared folder name","path":"file path","content":"string"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null) return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        await u.writeText(f, (args['path'] ?? '').toString(), (args['content'] ?? '').toString());
        return 'Wrote ${args['path']}.';
      },
      needsConfirm: true,
      available: () => _hasFolders,
    ),
    AgentTool(
      'web_search',
      'Search the web and return the top results (title, url, snippet).',
      '{"query":"string"}',
      (args) async {
        final r = await Get.find<WebSearchService>().search((args['query'] ?? '').toString());
        if (r.isEmpty) return 'No results.';
        return r.map((e) => '${e.title}\n${e.url}\n${e.snippet}').join('\n\n');
      },
    ),
    AgentTool(
      'fetch_url',
      'Download a web page and return its readable text.',
      '{"url":"https://...","start":"optional character offset"}',
      (args) async {
        final uri = Uri.tryParse((args['url'] ?? '').toString());
        if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
          return 'Error: give a full http(s) URL.';
        }
        final res = await http.get(uri, headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 14) NeuroMeshAI'
        }).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) return 'Error: server answered ${res.statusCode}.';
        final ct = res.headers['content-type'] ?? '';
        final body = utf8.decode(res.bodyBytes, allowMalformed: true);
        final text = ct.contains('html') ? readableText(body) : body;
        return _page(text, int.tryParse('${args['start'] ?? 0}') ?? 0);
      },
    ),
  ];

  /// Every built-in tool, including blocked or currently unavailable ones
  /// (for the permissions screen).
  /// Runs a tool by name without the model (used by the HTTP API).
  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final t = catalog.firstWhere((t) => t.name == name,
        orElse: () => throw Exception('Unknown tool $name'));
    return await t.run(args);
  }

  Future<List<Map<String, dynamic>>> listWorkspace() async {
    final dir = await filesDir();
    return [
      for (final e in dir.listSync().whereType<File>())
        {
          'name': e.path.split('/').last,
          'bytes': e.lengthSync(),
          'modified': e.lastModifiedSync().toIso8601String(),
        }
    ];
  }

  Future<File?> workspaceFile(String name) async {
    final f = await _safeFile(name);
    return await f.exists() ? f : null;
  }

  Future<File> newWorkspaceFile(String name) => _safeFile(name);

  List<AgentTool> get catalog => [..._builtIns, ..._extra];

  Iterable<AgentTool> get _allBuiltIns sync* {
    for (final t in [..._builtIns, ..._extra]) {
      if (policyFor('built-in', t.name, needsConfirm: t.needsConfirm) == 'block') continue;
      if (t.available == null || t.available!()) yield t;
    }
  }

  @override
  void onInit() {
    super.onInit();
    final raw = _hive.getSetting<List>(_serversKey) ?? const [];
    servers.value = raw
        .whereType<Map>()
        .map((m) => McpServerConfig.fromMap(Map<String, dynamic>.from(m)))
        .toList();
    memory.value = (_hive.getSetting<List>(_memoryKey) ?? const [])
        .map((e) => e.toString())
        .toList();
    final saved = _hive.getSetting<Map>(_policyKey);
    if (saved != null) {
      policy.addAll({for (final e in saved.entries) e.key.toString(): e.value.toString()});
    }
    for (final e in (_hive.getSetting<List>(_allowKey) ?? const [])) {
      policy.putIfAbsent(e.toString(), () => 'allow');
    }
    final m = _hive.getSetting<String>(_modeKey) ?? 'auto';
    mode.value = AgentChatMode.values
        .firstWhere((x) => x.name == m, orElse: () => AgentChatMode.auto);
    autoMemory.value = _hive.getSetting<bool>(_autoMemKey) ?? true;
    // Reconnect to enabled servers in the background so their tools are ready.
    for (final s in servers.where((s) => s.enabled)) {
      unawaited(refreshServer(s));
    }
  }

  // ── MCP servers ──────────────────────────────────────────────────────

  Future<void> _saveServers() =>
      _hive.setSetting(_serversKey, servers.map((s) => s.toMap()).toList());

  Future<McpServerConfig> addServer(String name, String url, String token,
      {Map<String, String> headers = const {}}) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final cfg = McpServerConfig(
        id: id,
        name: name.trim(),
        url: url.trim(),
        token: token.trim(),
        headers: headers);
    servers.add(cfg);
    await _saveServers();
    unawaited(refreshServer(cfg));
    return cfg;
  }

  Future<void> updateServer(McpServerConfig cfg) async {
    final i = servers.indexWhere((s) => s.id == cfg.id);
    if (i < 0) return;
    servers[i] = cfg;
    await _saveServers();
    await refreshServer(cfg);
  }

  Future<void> removeServer(String id) async {
    servers.removeWhere((s) => s.id == id);
    _tools.remove(id);
    serverStatus.remove(id);
    toolsVersion.value++;
    await _saveServers();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = servers.indexWhere((s) => s.id == id);
    if (i < 0) return;
    servers[i] = servers[i].copyWith(enabled: enabled);
    await _saveServers();
    if (enabled && !_tools.containsKey(id)) await refreshServer(servers[i]);
    toolsVersion.value++;
  }

  Future<void> setToolEnabled(String serverId, String tool, bool enabled) async {
    final i = servers.indexWhere((s) => s.id == serverId);
    if (i < 0) return;
    final off = {...servers[i].disabledTools};
    enabled ? off.remove(tool) : off.add(tool);
    servers[i] = servers[i].copyWith(disabledTools: off);
    await _saveServers();
    toolsVersion.value++;
  }

  /// Connects to the server and lists its tools; updates [serverStatus].
  Future<void> refreshServer(McpServerConfig cfg) async {
    serverStatus[cfg.id] = 'Connecting…';
    final client = McpClient(cfg);
    try {
      final tools = await client.listTools();
      _tools[cfg.id] = tools;
      serverStatus[cfg.id] =
          'Connected · ${tools.length} tool${tools.length == 1 ? '' : 's'}';
    } catch (e) {
      _tools.remove(cfg.id);
      serverStatus[cfg.id] = e.toString();
    } finally {
      client.dispose();
      toolsVersion.value++;
    }
  }

  /// Tries a connection without saving anything. Returns tool names or throws.
  Future<List<McpTool>> testServer(McpServerConfig cfg) async {
    final client = McpClient(cfg);
    try {
      return await client.listTools();
    } finally {
      client.dispose();
    }
  }

  List<McpTool> toolsOf(String id) => _tools[id] ?? const [];

  Iterable<McpTool> get _enabledMcpTools sync* {
    for (final s in servers.where((s) => s.enabled)) {
      for (final t in toolsOf(s.id)) {
        if (!s.disabledTools.contains(t.name) &&
            policyFor(s.name, t.name, needsConfirm: true) != 'block') {
          yield t;
        }
      }
    }
  }

  // ── when and how tools are offered ───────────────────────────────────

  static final _intent = RegExp(
      r'\b(file|files|folder|directory|document|attached|attachment|read|open|list|create|write|save|edit|search|look up|find|calculate|compute|remember|forget|note|run|execute|command|shell|script|install|deploy|build|github|repo|supabase|database|vercel|url|http|website|web ?page|download|time is it|date today|zip|pdf|csv|json)\b|مجلد|ملف|اقرا|افتح|احفظ|اكتب|ابحث|احسب|تذكر|انسى|شغل|نفذ|ارفع|حمل|موقع',
      caseSensitive: false);

  static final _actionOnly = RegExp(
      r'\b(create|write|save|edit|delete|remove|run|execute|install|folder|file|zip|convert|draw|schedule|remind)\b|ملف|مجلد|احفظ|اكتب|شغل|نفذ',
      caseSensitive: false);
  static final _askingAboutSelf =
      RegExp(r'\b(you|your|yourself|my|me|i)\b', caseSensitive: false);
  static final _question = RegExp(
      r'^\s*(what|who|whom|whose|when|where|which|why|how|is|are|was|were|does|do|did|can|could|tell me|give me|list|name|explain|compare)\b|[?؟]\s*$|^\s*(ما|ماذا|من|متى|اين|أين|كيف|لماذا|هل|كم|ايه|إيه|مين|فين|امتى)(\s|$)',
      caseSensitive: false);

  /// Questions that ask for information must be answered from the web, not
  /// from the model's (out of date) memory.
  bool needsResearch(String text) {
    final t = text.trim();
    if (t.length < 8) return false;
    final fresh = needsWebSearch(t);
    if (_actionOnly.hasMatch(t) && !fresh) return false;
    if (fresh) return true;
    if (_askingAboutSelf.hasMatch(t)) return false;
    return _question.hasMatch(t);
  }

  /// Whether this chat turn should offer tools to the model.
  bool wantsTools(String text, {bool hasFile = false}) {
    switch (mode.value) {
      case AgentChatMode.off:
        return false;
      case AgentChatMode.always:
        return true;
      case AgentChatMode.auto:
        if (hasFile) return true;
        if (_intent.hasMatch(text)) return true;
        if (needsResearch(text)) return true;
        for (final s in servers.where((s) => s.enabled)) {
          if (text.toLowerCase().contains(s.name.toLowerCase())) return true;
        }
        return false;
    }
  }

  /// Tool instructions appended to the chat's system prompt.
  String toolPrompt() {
    final b = StringBuffer()
      ..writeln('You are an AGENT running inside the NeuroMesh AI app on the user\'s own device. Your tools really run and return real results — you can search the web, read pages, create and edit files, run commands (when a shell tool is listed), speak, transcribe, draw images, schedule tasks and use the user\'s shared folders. Work like a careful engineer: decide what the next step is, call ONE tool, read its result, then continue until the task is truly finished.')
      ..writeln()
      ..writeln('HOW TO CALL A TOOL: reply with ONLY this (no text before or after):')
      ..writeln('<tool_call>{"name":"TOOL_NAME","arguments":{...}}</tool_call>')
      ..writeln('You will receive the tool result, then you decide the next step. WHEN THE TASK IS FINISHED, reply with the final answer in normal text and call NO tool — that is how you end the loop.')
      ..writeln()
      ..writeln('RULES')
      ..writeln('1. Never pretend. Do not say you created, ran, saved or found something unless a tool result confirms it. If asked to create a file, call write_file — never just print the content in the chat.')
      ..writeln('2. If the user asks for information (facts, news, versions, prices, people, how something works today) you MUST search the web first: web_search, then fetch_url on the best results, and search again with different words if the answer is thin. Your own memory of recent events is out of date. Answer only from what you found, give specific names, dates and numbers, prefer the newest source, and cite sources like [1].')
      ..writeln('3. Files: your workspace holds the user\'s attachments and every file you create. To show or hand over a file write [📎 name](nmfile:name); to show an image write ![description](nmfile:name). Shared folders: list_folder, read_user_file, edit_user_file, write_user_file. To change an existing file: read it, then edit_file / edit_user_file, then read it again to verify.')
      ..writeln('4. Other models are your tools: text_to_speech makes an audio file, transcribe_audio turns audio/video into text, generate_image draws a picture (the app swaps the image model in by itself). Use them whenever the user asks for audio, a transcript or an image.')
      ..writeln('5. If a tool returns an error, read it, fix the arguments and try something different. Never repeat an identical call. If you need a detail only the user has, call ask_user.')
      ..writeln('6. Break big requests into steps and do them one after another. Do not stop after the first tool if more is needed; do not keep calling tools once you have what you need.')
      ..writeln('7. Call tool_help if you are unsure what a tool does.')
      ..writeln()
      ..writeln('EXAMPLES')
      ..writeln('User: create notes.txt that says hello  ->  <tool_call>{"name":"write_file","arguments":{"name":"notes.txt","content":"hello"}}</tool_call>  ->  (after the result) Done — I created notes.txt. [📎 notes.txt](nmfile:notes.txt)')
      ..writeln('User: who won the latest world cup?  ->  <tool_call>{"name":"web_search","arguments":{"query":"latest world cup winner"}}</tool_call>  ->  then fetch_url the best result  ->  final answer with the facts and sources.')
      ..writeln()
      ..writeln('Tools:');
    for (final t in _allBuiltIns) {
      b.writeln('- ${t.name}: ${t.description} arguments: ${t.params}');
    }
    for (final t in _enabledMcpTools) {
      final d = t.description.replaceAll('\n', ' ');
      b.writeln('- ${t.qualifiedName}: ${d.length > 220 ? '${d.substring(0, 220)}…' : d} arguments: ${t.signature}');
    }
    if (_hasFolders) {
      b
        ..writeln()
        ..writeln('Shared folders: ${_user!.folders.map((f) => f.name).join(', ')}');
    }
    return b.toString().trimRight();
  }

  /// System prompt for a chat turn: the chat's own prompt, saved memory, and
  /// (when [withTools]) the tool instructions.
  String composeSystem(String base, {required bool withTools}) {
    final b = StringBuffer(base);
    final mem = memoryBlock();
    if (mem.isNotEmpty) b.write('\n\n$mem');
    if (withTools) b.write('\n\n${toolPrompt()}');
    return b.toString();
  }

  void cancel() {
    _cancel = true;
    final inference = Get.find<InferenceService>();
    if (inference.isGenerating.value) inference.stopGeneration();
  }

  /// One chat turn with tools. [generate] runs the model (streaming tokens to
  /// the callback it is given); the loop calls it until the model answers
  /// without a tool call, or [maxSteps] is reached.
  ///
  /// [history] must end with the user's message (as the chat already builds it).
  Future<ToolLoopResult> runToolLoop({
    required Future<String> Function(String prompt,
            List<Map<String, String>> history, void Function(String) onToken)
        generate,
    required String prompt,
    required List<Map<String, String>> history,
    required ToolConfirm confirm,
    required void Function(String visible) onVisible,
    required void Function(String status) onStatus,
    required bool Function() cancelled,
    void Function(List<String> trace)? onTrace,
    String? researchQuestion,
    String? userText,
  }) async {
    _cancel = false;
    final hist = history.map((m) => Map<String, String>.from(m)).toList();
    if (hist.isNotEmpty && hist.last['role'] == 'user') {
      hist.last['content'] = prompt;
    }
    final trace = <String>[];
    final seen = <String>{};
    var current = prompt;
    var last = '';
    final sources = <WebResult>[];
    var ranTool = false;
    var nudges = 0;
    final request = userText ?? prompt;
    if (researchQuestion != null && !cancelled() && !_cancel) {
      final msg = await _autoResearch(
          researchQuestion, trace, onTrace, onStatus, sources, cancelled);
      if (msg != null) {
        ranTool = true;
        hist.add({
          'role': 'assistant',
          'content':
              '<tool_call>${jsonEncode({'name': 'web_search', 'arguments': {'query': searchQuery(researchQuestion)}})}</tool_call>'
        });
        hist.add({'role': 'user', 'content': msg});
        current = msg;
      }
    }
    for (var step = 0; step < maxSteps; step++) {
      if (cancelled() || _cancel) break;
      final buf = StringBuffer();
      var calling = false;
      last = await generate(current, hist, (tok) {
        buf.write(tok);
        final text = buf.toString();
        final i = text.indexOf('<tool_call>');
        if (i >= 0) {
          if (!calling) {
            calling = true;
            onStatus('Using a tool…');
          }
          onVisible(text.substring(0, i).trimRight());
        } else {
          // Hold back a partial opening tag so it never flashes on screen.
          final tail = text.lastIndexOf('<');
          final partial = tail >= 0 && '<tool_call>'.startsWith(text.substring(tail));
          onVisible(partial ? text.substring(0, tail) : text);
        }
      });
      last = last.trim();
      if (cancelled() || _cancel) break;
      if (last.startsWith('ERROR:')) return ToolLoopResult(last, trace, false);
      final call = parseToolCall(last);
      if (call == null) {
        // The model answered without a tool. For action requests (make a file,
        // run a command) that usually means a small model is only describing
        // the work, so push it to actually do it.
        if (!ranTool && nudges < 2) {
          final n = _nudgeFor(request);
          if (n != null) {
            nudges++;
            onVisible('');
            onStatus('Making sure it is really done…');
            hist.add({'role': 'assistant', 'content': last});
            current = n;
            hist.add({'role': 'user', 'content': current});
            continue;
          }
        }
        if (!ranTool) {
          final fb = await _fallbackFile(request, last, confirm, trace, onTrace);
          if (fb != null) return fb;
        }
        return ToolLoopResult(
            _autoLinkFiles(_withSources(last, sources), trace), trace, false);
      }
      ranTool = true;

      final label = stepLabel(call.name, call.arguments);
      onStatus(label);
      final key = '${call.name}${jsonEncode(call.arguments)}';
      final idx = trace.length;
      final sw = Stopwatch()..start();
      trace.add(stepLine(call.name, call.arguments, label, null, running: true));
      onTrace?.call(List.of(trace));
      String result;
      if (!seen.add(key)) {
        result = 'You already ran this exact call. Use a different query or argument, or answer now.';
      } else {
        result = await executeTool(call, confirm);
      }
      trace[idx] = stepLine(call.name, call.arguments, label, result,
          ms: sw.elapsedMilliseconds);
      onTrace?.call(List.of(trace));
      hist.add({'role': 'assistant', 'content': last});
      current = 'Tool result for ${call.name}:\n$result\n\n'
          'Now either call another tool or give the final answer to the user\'s request.';
      hist.add({'role': 'user', 'content': current});
    }
    if (cancelled() || _cancel) {
      return ToolLoopResult(last.isEmpty ? '' : stripCall(last), trace, false);
    }
    return ToolLoopResult(
        'I used $maxSteps tool steps without reaching an answer. A small model may be too weak for this request; try a bigger model or a simpler request.',
        trace,
        true);
  }

  static final _wantsFile = RegExp(
      r'(create|make|write|save|generate|put|store)\b[^\n]{0,80}(\bfile\b|\.[a-z0-9]{1,5}\b)|(اكتب|انشئ|أنشئ|اعمل|احفظ)[^\n]{0,60}(ملف|\.[a-z0-9]{2,5})',
      caseSensitive: false);
  static final _wantsCmd = RegExp(
      r'\b(run|execute)\b[^\n]{0,60}\b(command|shell|terminal|script)\b|\b(ls|pip|npm|git|python|cat|mkdir|curl)\s',
      caseSensitive: false);
  static final _fileName = RegExp(
      r'([\w\-]+\.(?:txt|md|csv|json|html|css|py|js|ts|dart|xml|ya?ml|log|sh|java|kt|c|cpp|sql))\b',
      caseSensitive: false);

  String? _nudgeFor(String request) {
    final names = {for (final t in _allBuiltIns) t.name};
    if (_wantsFile.hasMatch(request) && names.contains('write_file')) {
      final fn = _fileName.firstMatch(request)?.group(1) ?? 'notes.txt';
      return 'You did not call a tool, so NO file was created — printing text in the chat saves nothing. '
          'Create it now by replying with ONLY this tool call (put the real content in "content"):\n'
          '<tool_call>{"name":"write_file","arguments":{"name":"$fn","content":"..."}}</tool_call>';
    }
    if (_wantsCmd.hasMatch(request) && names.contains('run_shell')) {
      return 'You did not call a tool, so nothing was run. Run it now by replying with ONLY: '
          '<tool_call>{"name":"run_shell","arguments":{"command":"..."}}</tool_call>';
    }
    return null;
  }

  /// Last resort for tiny models: they were asked to make a file and only
  /// printed its content, so save that content ourselves.
  Future<ToolLoopResult?> _fallbackFile(String request, String reply,
      ToolConfirm confirm, List<String> trace, void Function(List<String>)? onTrace) async {
    if (!_wantsFile.hasMatch(request)) return null;
    final fn = _fileName.firstMatch(request)?.group(1);
    if (fn == null) return null;
    var content = reply;
    final fence = RegExp(r'```[\w+\-]*\n([\s\S]*?)```').firstMatch(reply);
    if (fence != null) content = fence.group(1)!;
    content = content.trim();
    if (content.isEmpty) return null;
    final args = <String, dynamic>{'name': fn, 'content': content};
    final label = stepLabel('write_file', args);
    final idx = trace.length;
    final sw = Stopwatch()..start();
    trace.add(stepLine('write_file', args, label, null, running: true));
    onTrace?.call(List.of(trace));
    final result = await executeTool(ParsedToolCall('write_file', args, ''), confirm);
    trace[idx] = stepLine('write_file', args, label, result, ms: sw.elapsedMilliseconds);
    onTrace?.call(List.of(trace));
    final ok = result.startsWith('Wrote');
    return ToolLoopResult(
        ok ? 'Done — I created **$fn**.\n\n[📎 $fn](nmfile:$fn)' : result, trace, false);
  }

  String _withSources(String answer, List<WebResult> sources) {
    if (sources.isEmpty || answer.contains('Sources:')) return answer;
    final b = StringBuffer(answer.trimRight())..write('\n\nSources:\n');
    for (var i = 0; i < sources.length; i++) {
      b.writeln('${i + 1}. [${sources[i].title.replaceAll(RegExp(r'[\[\]]'), '')}](${sources[i].url})');
    }
    return b.toString().trimRight();
  }

  /// Files the agent wrote or spoke are linked in the answer even when the
  /// model forgot to mention them.
  String _autoLinkFiles(String answer, List<String> trace) {
    final extra = <String>[];
    for (final line in trace) {
      if (!line.startsWith(ToolLoopResult.traceMark)) continue;
      try {
        final m = jsonDecode(line.substring(ToolLoopResult.traceMark.length)) as Map;
        final n = m['n'];
        final res = '${m['r'] ?? ''}';
        if ((n == 'write_file' || n == 'text_to_speech' || n == 'append_file' || n == 'edit_file') &&
            !res.startsWith('Error')) {
          final a = m['a'];
          final name = a is Map ? '${a['name'] ?? ''}' : '';
          if (name.isNotEmpty && !answer.contains('nmfile:$name') && !extra.contains(name)) {
            extra.add(name);
          }
        }
      } catch (_) {}
    }
    if (extra.isEmpty) return answer;
    return '${answer.trimRight()}\n\n${extra.map((n) => '[📎 $n](nmfile:$n)').join('\n')}';
  }

  /// Searches the web for the question and reads the best pages, showing each
  /// step in the trace. Returns the message handed to the model, or null when
  /// nothing was found.
  Future<String?> _autoResearch(
      String question,
      List<String> trace,
      void Function(List<String>)? onTrace,
      void Function(String) onStatus,
      List<WebResult> sourcesOut,
      bool Function() cancelled) async {
    final web = Get.find<WebSearchService>();
    final fresh = web.freshnessFor(question);
    final all = <WebResult>[];
    for (final q in web.researchQueries(question)) {
      if (cancelled()) return null;
      final args = {'query': q};
      final label = stepLabel('web_search', args);
      onStatus(label);
      final idx = trace.length;
      final sw = Stopwatch()..start();
      trace.add(stepLine('web_search', args, label, null, running: true));
      onTrace?.call(List.of(trace));
      final r = await web.search(q, max: 8, freshness: fresh);
      all.addAll(r);
      trace[idx] = stepLine('web_search', args, label,
          r.isEmpty ? 'No results.' : r.map((e) => '${e.title}\n${e.url}\n${e.snippet}').join('\n\n'),
          ms: sw.elapsedMilliseconds);
      onTrace?.call(List.of(trace));
    }
    final results = dedupeByHost(all, (r) => r.url).take(6).toList();
    if (results.isEmpty) return null;
    final query = searchQuery(question);
    final texts = <String>[];
    for (final r in results.take(3)) {
      if (cancelled()) return null;
      final args = {'url': r.url};
      final label = stepLabel('fetch_url', args);
      onStatus(label);
      final idx = trace.length;
      final sw = Stopwatch()..start();
      trace.add(stepLine('fetch_url', args, label, null, running: true));
      onTrace?.call(List.of(trace));
      final t = await web.pageText(r.url, query, maxChars: 1800);
      texts.add(t);
      trace[idx] = stepLine('fetch_url', args, label, t.isEmpty ? '(could not read this page)' : t,
          ms: sw.elapsedMilliseconds);
      onTrace?.call(List.of(trace));
    }
    sourcesOut.addAll(results);
    final b = StringBuffer(
        'Web research done for the user\'s question. Today is ${DateTime.now().toIso8601String().substring(0, 10)}.\n');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      final body = i < texts.length && texts[i].length > r.snippet.length ? texts[i] : r.snippet;
      b.writeln('\n[${i + 1}] ${r.title} (${r.url})\n$body');
    }
    b.writeln('\nNow answer the user in their language: complete, specific and detailed (names, versions, dates, numbers taken from the sources) — never a one-word answer. '
        'Prefer the NEWEST information by date and say so if sources disagree. Cite sources like [1]. '
        'If these sources do not contain the answer, call web_search again with different wording or fetch_url a better page; do not guess.');
    return b.toString();
  }

  /// Human wording for what a tool call is doing right now.
  static String stepLabel(String name, Map<String, dynamic> a) {
    String q(String k) => (a[k] ?? '').toString();
    switch (name) {
      case 'web_search':
        return 'Searching the web: ${q('query')}';
      case 'fetch_url':
        return 'Reading ${q('url')}';
      case 'run_shell':
        return 'Running command: ${q('command')}';
      case 'read_file':
      case 'read_user_file':
        return 'Reading ${q('name').isNotEmpty ? q('name') : q('path')}';
      case 'write_file':
      case 'write_user_file':
        return 'Writing ${q('name').isNotEmpty ? q('name') : q('path')}';
      case 'search_in_file':
        return 'Searching ${q('name')} for "${q('query')}"';
      case 'list_files':
      case 'list_folder':
        return 'Looking through files';
      case 'transcribe_audio':
        return 'Transcribing ${q('name')}';
      case 'text_to_speech':
        return 'Speaking to ${q('name')}';
      case 'generate_image':
        return 'Creating an image';
      case 'device_status':
        return 'Checking the phone status';
      case 'ask_user':
        return 'Asking you a question';
      case 'remember':
        return 'Saving to memory';
      case 'calculator':
        return 'Calculating ${q('expression')}';
      default:
        return 'Using $name';
    }
  }

  /// One saved trace line: the marker followed by a JSON step.
  static String stepLine(String name, Map<String, dynamic> args, String label, String? result,
      {bool running = false, int ms = 0}) {
    var r = result ?? '';
    if (r.length > 3000) r = '${r.substring(0, 3000)}\n… (${result!.length - 3000} more characters)';
    return '${ToolLoopResult.traceMark}${jsonEncode({
      'n': name,
      'l': label,
      'a': args,
      'r': r,
      'run': running,
      'ms': ms,
    })}';
  }

  static String stripCall(String reply) {
    final i = reply.indexOf('<tool_call>');
    return i < 0 ? reply : reply.substring(0, i).trim();
  }

  /// Runs one tool call (asking the user first when required).
  Future<String> executeTool(ParsedToolCall call, ToolConfirm confirm) async {
    for (final t in _allBuiltIns) {
      if (t.name == call.name) {
        try {
          final pol = policyFor('built-in', t.name, needsConfirm: t.needsConfirm);
          if (pol == 'block') return 'The user has blocked this tool.';
          if (pol == 'ask' && !await confirm(t.name, 'built-in', call.arguments)) {
            return 'The user denied this tool call.';
          }
          final out = await t.run(call.arguments);
          return out.length > 6000 ? '${out.substring(0, 6000)}\n…(truncated)' : out;
        } catch (e) {
          return 'Error: $e';
        }
      }
    }
    McpTool? tool;
    for (final t in _enabledMcpTools) {
      if (t.qualifiedName == call.name) tool = t;
    }
    if (tool == null) {
      return 'Error: unknown tool "${call.name}". Use only the listed tools.';
    }
    final cfg = servers.firstWhere((s) => s.id == tool!.serverId);
    final pol = policyFor(cfg.name, tool.name, needsConfirm: true);
    if (pol == 'block') return 'The user has blocked this tool.';
    if (pol == 'ask' && !await confirm(tool.name, cfg.name, call.arguments)) {
      return 'The user denied this tool call.';
    }
    final client = McpClient(cfg);
    try {
      final out = await client.callTool(tool.name, call.arguments);
      return out.length > 4000 ? '${out.substring(0, 4000)}\n…(truncated)' : out;
    } catch (e) {
      return 'Error: $e';
    } finally {
      client.dispose();
    }
  }
}
