import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/bm25.dart';
import '../utils/skill_context.dart';
import '../utils/memory_text.dart';
import 'chat_calculator.dart';
import 'voice_service.dart';
import 'hive_service.dart';
import 'pollinations_image_service.dart';
import 'pollinations_credentials.dart';
import 'background_work_notifications.dart';

/// Asks the user whether a tool may run. Returns true to allow.
typedef ToolConfirm = Future<bool> Function(
    String toolName, String serverName, Map<String, dynamic> args);

/// Implementation of a tool registered for Chat.
class ChatTool {
  final String name;
  final String description;
  final String params;
  final FutureOr<String> Function(Map<String, dynamic> args) run;

  /// Reaches outside the app's own data (network, the user's files, a shell),
  /// so the user is asked first.
  final bool needsConfirm;

  /// Whether the tool should be offered to the model right now.
  final bool Function()? available;

  const ChatTool(this.name, this.description, this.params, this.run,
      {this.needsConfirm = false, this.available});
}

/// Result of one chat turn that may have used tools.
class ToolLoopResult {
  /// The model's final answer.
  final String answer;

  /// One short markdown line per tool the model used.
  final List<String> trace;
  final bool hitLimit;
  const ToolLoopResult(this.answer, this.trace, this.hitLimit,
      {this.searches = const []});

  final List<Map<String, dynamic>> searches;

  /// Marker so trace lines can be stripped out of the history sent back to
  /// the model on later turns.
  static const traceMark = '> 🔧 ';

  String get markdown =>
      trace.isEmpty ? answer : '${trace.join('\n')}\n\n$answer';
}

/// Removes tool-trace lines from a saved assistant message.
String stripToolTrace(String content) => content
    .split('\n')
    .where((l) => !l.startsWith(ToolLoopResult.traceMark))
    .join('\n')
    .trimLeft();

String markToolTraceCancelled(String content) =>
    content.split('\n').map((line) {
      if (!line.startsWith(ToolLoopResult.traceMark)) return line;
      try {
        final data =
            jsonDecode(line.substring(ToolLoopResult.traceMark.length));
        if (data is Map && data['run'] == true) {
          data['run'] = false;
          data['failed'] = true;
          data['r'] = 'Cancelled.';
          return '${ToolLoopResult.traceMark}${jsonEncode(data)}';
        }
      } on FormatException {
        return line;
      }
      return line;
    }).join('\n');

enum ChatToolMode { auto, off }

/// Stores Chat attachments and output files and dispatches bounded tools.
class ChatToolService extends GetxService {
  static const _memoryKey = 'agent_memory';
  static const _allowKey = 'agent_always_allow'; // legacy, migrated
  static const _policyKey = 'agent_tool_policy';
  static const _modeKey = 'agent_chat_mode';
  static final _chatToolAbort = Object();
  static final _chatToolCancelled = Object();
  static final _chatToolStop = Object();

  static bool get chatToolCancelled =>
      (Zone.current[_chatToolCancelled] as bool Function()?)?.call() ?? false;

  Future<String> executeChatTool(ParsedToolCall call, ToolConfirm confirm,
          {required Future<void> abort,
          required bool Function() cancelled,
          void Function()? onStop}) =>
      runZoned(
        () => executeTool(call, confirm),
        zoneValues: {
          _chatToolAbort: abort,
          _chatToolCancelled: cancelled,
          _chatToolStop: onStop,
        },
      );

  static const maxMemory = 60;

  final HiveService _hive = Get.find<HiveService>();

  final memory = <String>[].obs;

  /// Per-tool choice: 'allow' (never ask), 'ask' (always ask) or 'block'.
  /// Key is "server::tool". Tools with no entry use their default.
  final policy = <String, String>{}.obs;
  final mode = ChatToolMode.auto.obs;
  final _extra = <ChatTool>[];

  // ── workspace (private folder; attachments are copied here) ──────────

  static final _workspaceKey = Object();

  String projectForChat(String chatId) => chatId.isEmpty
      ? ''
      : _hive.getSetting<String>('workspace_project_$chatId') ?? '';

  Future<void> setChatProject(String chatId, String name) async {
    if (chatId.isEmpty) throw ArgumentError('Open a chat first.');
    final project = name.trim();
    if (project.length > 60 || project.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError('Enter a project name up to 60 characters.');
    }
    await _hive.setSetting('workspace_project_$chatId', project);
  }

  Future<T> inProject<T>(String project, Future<T> Function() action) =>
      runZoned(action, zoneValues: {_workspaceKey: project});

  String get _project => Zone.current[_workspaceKey] as String? ?? '';
  String get _projectId =>
      base64Url.encode(utf8.encode(_project)).replaceAll('=', '');

  Future<Directory> filesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(_project.isEmpty
        ? '${base.path}/agent_files'
        : '${base.path}/agent_projects/$_projectId');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> _versionDir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final key = base64Url.encode(utf8.encode(name)).replaceAll('=', '');
    return Directory(
        '${base.path}/agent_revisions/${_project.isEmpty ? "_" : _projectId}/$key');
  }

  Future<void> _keepFileVersion(File file) async {
    if (!await file.exists()) return;
    final dir = await _versionDir(file.uri.pathSegments.last);
    await dir.create(recursive: true);
    final now = DateTime.now().microsecondsSinceEpoch;
    await file.copy('${dir.path}/$now');
    final revisions = await _versions(dir);
    for (final old in revisions.skip(10)) {
      await old.delete();
    }
  }

  Future<List<File>> _versions(Directory dir) async {
    if (!await dir.exists()) return [];
    return (await dir
        .list(followLinks: false)
        .where((entry) => entry is File)
        .cast<File>()
        .toList())
      ..sort((a, b) => b.path.compareTo(a.path));
  }

  Future<List<String>> archivedWorkspaceFiles() async {
    final root = (await _versionDir('file')).parent;
    if (!await root.exists()) return [];
    final names = <String>[];
    await for (final dir in root.list(followLinks: false)) {
      if (dir is! Directory) continue;
      try {
        names.add(utf8.decode(base64Url.decode(base64Url.normalize(
            dir.uri.pathSegments.where((part) => part.isNotEmpty).last))));
      } on FormatException {
        continue;
      }
    }
    return names..sort();
  }

  Future<List<int>> workspaceVersions(String name) async {
    final dir = await _versionDir(name);
    return (await _versions(dir))
        .map((file) => int.tryParse(file.uri.pathSegments.last))
        .whereType<int>()
        .toList();
  }

  Future<bool> restoreWorkspaceVersion(String name, int version) async {
    final file = await _safeFile(name);
    final dir = await _versionDir(name);
    final source = File('${dir.path}/$version');
    if (!await source.exists()) return false;
    final temp =
        File('${file.path}.restore-${DateTime.now().microsecondsSinceEpoch}');
    await source.copy(temp.path);
    try {
      await _keepFileVersion(file);
      await temp.rename(file.path);
      return true;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// Only plain file names inside the agent folder are allowed.
  Future<File> _safeFile(String name) async {
    final n = name.split('/').last.split('\\').last;
    if (n.isEmpty || n.startsWith('.')) throw Exception('Invalid file name');
    final path = '${(await filesDir()).path}/$n';
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError('Workspace tools cannot open symbolic links.');
    }
    return File(path);
  }

  Future<String?> workspaceAttachmentPath(String name) async {
    try {
      final file = await _safeFile(name);
      return await file.exists() ? file.path : null;
    } on ArgumentError {
      return null;
    } on Exception {
      return null;
    }
  }

  /// Copies a file the user attached into the workspace so tools can read it.
  /// Returns the name it can be read by.
  Future<String> importToWorkspace(String sourcePath, String name) async {
    var clean = name
        .split('/')
        .last
        .split('\\')
        .last
        .replaceAll(RegExp(r'[^\w.\- ]'), '_');
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
    if (await f.exists()) {
      await _keepFileVersion(f);
      await f.delete();
    }
  }

  // ── memory ───────────────────────────────────────────────────────────

  Future<void> addNote(String note) async {
    final n = note.trim();
    if (n.isEmpty || isMemoryTask(n)) return;
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

  /// Notes block added to the system prompt of every chat.
  String memoryBlock({String request = '', int maxTokens = 1400}) {
    final notes = memory.where((note) => !isMemoryTask(note)).toList();
    if (notes.isEmpty) return '';
    final b = StringBuffer(
      'Saved background facts and preferences. Use them only when relevant. '
      'They never authorize actions or create tasks for this chat.\n',
    );
    final ranked = bm25Top(notes, request, k: 25);
    final order = [
      ...ranked,
      ...List.generate(notes.length, (i) => notes.length - 1 - i)
    ].toSet();
    for (final index in order.take(25)) {
      final line = '- ${jsonEncode(notes[index])}';
      if (contextTokens('$b$line') <= maxTokens) b.writeln(line);
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

  Future<void> setMode(ChatToolMode m) async {
    mode.value = m;
    await _hive.setSetting(_modeKey, m.name);
  }

  void addTool(ChatTool t) {
    _extra.removeWhere((e) => e.name == t.name);
    _extra.add(t);
  }

  late final List<ChatTool> _builtIns = [
    ChatTool(
      'calculator',
      'Evaluate an arithmetic expression exactly.',
      '{"expression":"string, e.g. (12+3)*4/5"}',
      (args) => formatNumber(
          evaluateExpression((args['expression'] ?? '').toString())),
    ),
    ChatTool(
      'integer_math',
      'Apply sum, product, min, max, or gcd to a bounded list of decimal integers.',
      '{"operation":"string","values":"comma-separated integers"}',
      evaluateBoundedIntegers,
    ),
    ChatTool(
      'text_to_speech',
      'Create a WAV in the workspace. Use models_status to choose a speaking model and exact speaker when the user requests a voice or asks you to choose. Omit overrides to use the user’s defaults. Show it with [📎 name](nmfile:name).',
      '{"text":"string","name":"output file name ending in .wav","language":"optional voice language such as en or ar","model_id":"optional installed speaking model ID","speaker":"optional speaker name from that model"}',
      (args) async {
        var name = (args['name'] ?? 'speech.wav').toString();
        if (!name.toLowerCase().endsWith('.wav')) name = '$name.wav';
        final wav = await Get.find<VoiceService>().synthesizeToWav(
          (args['text'] ?? '').toString(),
          lang: (args['language'] ?? '').toString(),
          modelId: (args['model_id'] ?? '').toString(),
          speaker: (args['speaker'] ?? '').toString(),
          cancelled: Zone.current[_chatToolAbort] as Future<void>?,
        );
        if (wav.length <= 44)
          return 'Error: the voice produced no playable audio.';
        if (chatToolCancelled) return 'Error: audio generation cancelled.';
        final f = await _safeFile(name);
        await f.writeAsBytes(wav, flush: true);
        return 'Saved ${f.path.split('/').last} (${wav.length ~/ 1024} KB). Show it with [📎 ${f.path.split('/').last}](nmfile:${f.path.split('/').last}).';
      },
    ),
    ChatTool(
      'generate_image',
      'Create an image online with Pollinations. Internet is required. Use the user’s description, ask if the subject is missing, and show the returned image.',
      '{"prompt":"image description","style":"illustration|photo|design","name":"optional output file name"}',
      (args) async {
        final transport = http.Client();
        final abort = Zone.current[_chatToolAbort] as Future<void>?;
        if (abort != null) unawaited(abort.then((_) => transport.close()));
        try {
          final image = await PollinationsImageService().create(
            (args['prompt'] ?? '').toString(),
            style: (args['style'] ?? '').toString(),
            key: await PollinationsCredentials.read()
                .onError<Exception>((_, __) => null),
            client: transport,
          );
          if (chatToolCancelled) return 'Error: image generation cancelled.';
          return _savePollinationsImage(image, args['name'], edited: false);
        } finally {
          transport.close();
        }
      },
      needsConfirm: true,
    ),
    ChatTool(
      'edit_image',
      'Edit an existing image online using a free Pollinations image editor. Requires the user’s Pollinations key and an existing workspace image.',
      '{"prompt":"requested edit","source":"existing workspace image filename","name":"optional output file name"}',
      (args) async {
        final key = await PollinationsCredentials.read();
        if (key == null || key.isEmpty)
          return PollinationsImageService.editKeyNotice;
        final encoded = args['attachedImage'];
        final Uint8List bytes;
        if (encoded is String) {
          if (encoded.length > (8 * 1024 * 1024 * 4 ~/ 3) + 4) {
            return 'Choose an image smaller than 8 MB to edit.';
          }
          bytes = base64Decode(encoded);
        } else {
          final source = await _safeFile((args['source'] ?? '').toString());
          if (await source.length() > 8 * 1024 * 1024) {
            return 'Choose an image smaller than 8 MB to edit.';
          }
          bytes = await source.readAsBytes();
        }
        final transport = http.Client();
        final abort = Zone.current[_chatToolAbort] as Future<void>?;
        if (abort != null) unawaited(abort.then((_) => transport.close()));
        try {
          final image = await PollinationsImageService().edit(
            (args['prompt'] ?? '').toString(),
            bytes,
            key: key,
            style: (args['style'] ?? '').toString(),
            client: transport,
          );
          if (chatToolCancelled) return 'Error: image editing cancelled.';
          return _savePollinationsImage(image, args['name'], edited: true);
        } finally {
          transport.close();
        }
      },
      needsConfirm: true,
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

  List<ChatTool> get catalog => [..._builtIns, ..._extra];

  @override
  void onInit() {
    super.onInit();
    memory.value = (_hive.getSetting<List>(_memoryKey) ?? const [])
        .map((e) => e.toString())
        .toList();
    final saved = _hive.getSetting<Map>(_policyKey);
    if (saved != null) {
      policy.addAll({
        for (final e in saved.entries) e.key.toString(): e.value.toString()
      });
    }
    for (final e in (_hive.getSetting<List>(_allowKey) ?? const [])) {
      policy.putIfAbsent(e.toString(), () => 'allow');
    }
    final m = _hive.getSetting<String>(_modeKey) ?? 'auto';
    mode.value = ChatToolMode.values
        .firstWhere((x) => x.name == m, orElse: () => ChatToolMode.auto);
  }

  static int contextBudget(int contextSize) =>
      (contextSize * 0.72).floor() - 64;

  /// Keeps the current user request intact while fitting generated context.
  static ({
    String system,
    String prompt,
    List<Map<String, String>> history,
  }) fitTurn({
    required String baseSystem,
    required String system,
    required String prompt,
    required List<Map<String, String>> history,
    required int contextSize,
    required String request,
    bool needsEvidence = false,
    bool nativeBudget = false,
  }) {
    final budget = contextBudget(contextSize);
    final originalPrompt = prompt;
    if (contextSize > 0 &&
        contextTokens(system) + contextTokens(prompt) > budget) {
      system = baseSystem;
      final remaining =
          budget - contextTokens(system) - contextTokens(request) - 12;
      final optional = prompt.startsWith(request)
          ? prompt.substring(request.length).trimLeft()
          : prompt;
      final supportingText = fitContextText(optional, remaining);
      if (needsEvidence &&
          !nativeBudget &&
          supportingText.length < 80 &&
          optional.length >= 80) {
        throw StateError(
            'This model has too little room for the source text. Shorten the chat instructions or increase the context size.');
      }
      if (!nativeBudget || !needsEvidence || supportingText.length >= 80) {
        prompt =
            supportingText.isEmpty ? request : '$request\n\n$supportingText';
      }
    }
    final fittedHistory = List<Map<String, String>>.of(history);
    if (fittedHistory.lastOrNull?['role'] == 'user' &&
        fittedHistory.last['content'] == originalPrompt) {
      fittedHistory[fittedHistory.length - 1] = {
        'role': 'user',
        'content': prompt
      };
    } else {
      fittedHistory.add({'role': 'user', 'content': prompt});
    }
    fitToContext(system, fittedHistory, prompt, contextSize,
        nativeBudget: nativeBudget);
    return (system: system, prompt: prompt, history: fittedHistory);
  }

  /// Trims [hist] and [prompt] so the whole request fits the model's context
  /// with room left to answer; an overflow makes small models fail or go silent.
  /// Keeps the latest request intact; reports an oversized mandatory context.
  static String fitToContext(String system, List<Map<String, String>> hist,
      String prompt, int ctxTokens,
      {bool nativeBudget = false}) {
    if (ctxTokens <= 0) return prompt;
    final budget = contextBudget(ctxTokens);
    int total() =>
        contextTokens(system) +
        hist.fold<int>(0, (a, m) => a + contextTokens(m['content'] ?? ''));
    // Strict chat templates require history to start with a user turn.
    while (hist.length > 1 && hist.first['role'] != 'user') {
      hist.removeAt(0);
    }
    while (total() > budget && hist.length > 1) {
      hist.removeAt(0);
      while (hist.length > 1 && hist.first['role'] != 'user') {
        hist.removeAt(0);
      }
    }
    // User instructions are mandatory: never silently crop the current request.
    if (!nativeBudget &&
        (total() > budget ||
            contextTokens(system) + contextTokens(prompt) > budget)) {
      throw StateError(
          'The current instructions and message exceed this model’s context. Use @file: references for large documents, shorten the pinned rules, or increase context size.');
    }
    return prompt;
  }

  String composeSystem(String base,
      {String request = '', int contextSize = 8192}) {
    final memory = memoryBlock(request: request, maxTokens: contextSize ~/ 10);
    return [base, if (memory.isNotEmpty) memory].join('\n\n');
  }

  /// One saved trace line: the marker followed by a JSON step.
  static String stepLine(
      String name, Map<String, dynamic> args, String label, String? result,
      {bool running = false, bool failed = false, int ms = 0}) {
    var r = result ?? '';
    if (r.length > 3000)
      r = '${r.substring(0, 3000)}\n… (${result!.length - 3000} more characters)';
    return '${ToolLoopResult.traceMark}${jsonEncode({
          'n': name,
          'l': label,
          'a': args,
          'r': r,
          'run': running,
          if (failed) 'failed': true,
          'ms': ms,
        })}';
  }

  Future<String> _savePollinationsImage(PollinationsImage image, Object? name,
      {required bool edited}) async {
    var stem = name?.toString().trim() ?? '';
    stem = stem.replaceFirst(
        RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false), '');
    if (stem.isEmpty) stem = 'image_${DateTime.now().microsecondsSinceEpoch}';
    final file = await _safeFile('$stem.${image.extension}');
    await file.writeAsBytes(image.bytes, flush: true);
    final filename = file.uri.pathSegments.last;
    return '${edited ? 'Edited' : 'Generated'} online with Pollinations (${image.model}).'
        '\n\n![${edited ? 'Edited' : 'Generated'} image](nmfile:$filename)';
  }

  /// Runs one validated Chat tool with its configured approval.
  Future<String> executeTool(ParsedToolCall call, ToolConfirm confirm) async {
    final tool = catalog.firstWhereOrNull((tool) => tool.name == call.name);
    if (tool == null || tool.available?.call() == false) {
      return 'Error: this tool is unavailable in the current turn.';
    }
    final policy =
        policyFor('built-in', tool.name, needsConfirm: tool.needsConfirm);
    if (policy == 'block') return 'The user has blocked this tool.';
    final args = {...call.arguments}..remove('attachedImage');
    if (policy == 'ask' && !await confirm(tool.name, 'built-in', args)) {
      return 'The user denied this tool call.';
    }
    if (chatToolCancelled) return 'Error: tool cancelled.';
    final stop = Zone.current[_chatToolStop] as void Function()?;
    final notifications = stop != null &&
            (call.name == 'generate_image' || call.name == 'edit_image') &&
            Get.isRegistered<BackgroundWorkNotifications>()
        ? Get.find<BackgroundWorkNotifications>()
        : null;
    final notification = notifications?.begin(BackgroundWork.image, stop!);
    try {
      final output = await tool.run(call.arguments);
      return output.length > 6000
          ? '${output.substring(0, 6000)}\n…(truncated)'
          : output;
    } on FormatException catch (error) {
      return 'Error: ${error.message}';
    } on ArgumentError {
      return 'Error: the tool rejected an argument. Check its settings and try again.';
    } on Exception {
      return 'Error: the tool failed. Check its configuration and try again.';
    } finally {
      notifications?.finish(notification);
    }
  }
}
