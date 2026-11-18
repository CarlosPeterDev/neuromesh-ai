import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/skill_context.dart';
import '../utils/bm25.dart';
import 'agent_service.dart';
import 'document_extractor_service.dart';

class SkillsService extends GetxService {
  final skills = <SkillDefinition>[].obs;
  final disabled = <String>{}.obs;
  late Directory root;
  static final _turnKey = Object();
  static SkillTurnContext? get current =>
      Zone.current[_turnKey] as SkillTurnContext?;
  static Future<T> inTurn<T>(
          SkillTurnContext turn, Future<T> Function() action) =>
      runZoned(action, zoneValues: {_turnKey: turn});

  Future<SkillsService> init() async {
    root = Directory('${(await getApplicationSupportDirectory()).path}/skills');
    await root.create(recursive: true);
    final prefs = File('${root.path}/disabled.json');
    if (await prefs.exists()) {
      try {
        disabled.addAll(
            (jsonDecode(await prefs.readAsString()) as List).cast<String>());
      } catch (_) {/* A malformed preference must not prevent startup. */}
    }
    await reload();
    return this;
  }

  Future<void> reload() async {
    final found = <SkillDefinition>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          entity.path.split(Platform.pathSeparator).last.startsWith('.'))
        continue;
      final file = File('${entity.path}/SKILL.md');
      if (!await file.exists() || await file.length() > 2 * 1024 * 1024)
        continue;
      try {
        found.add(SkillDefinition.parse(await file.readAsString()));
      } catch (_) {/* Invalid imports are rejected before saving. */}
    }
    found.sort((a, b) => a.name.compareTo(b.name));
    skills.assignAll(found);
  }

  Future<void> toggle(String name, bool enabled) async {
    final next = disabled.toSet();
    if (enabled) {
      next.remove(name);
    } else {
      next.add(name);
    }
    final temp = File('${root.path}/disabled.json.tmp');
    await temp.writeAsString(jsonEncode(next.toList()), flush: true);
    await temp.rename('${root.path}/disabled.json');
    disabled.assignAll(next);
  }

  Future<void> save(String text, {String? editing}) async {
    if (utf8.encode(text).length > 2 * 1024 * 1024)
      throw const FormatException(
          'SKILL.md is limited to 2 MB. Move large documents into references.');
    final def = SkillDefinition.parse(text);
    if (editing != null && editing != def.name)
      throw const FormatException('Keep the skill name when editing.');
    final dir = Directory('${root.path}/${def.name}');
    if (editing == null && await dir.exists())
      throw const FormatException(
          'This skill already exists. Edit it instead.');
    await dir.create(recursive: true);
    final temp = File('${dir.path}/SKILL.md.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename('${dir.path}/SKILL.md');
    await reload();
  }

  Future<void> importFile(String path) async {
    final file = File(path);
    if (await file.length() > 16 * 1024 * 1024)
      throw const FormatException('Skill imports are limited to 16 MB.');
    if (!path.toLowerCase().endsWith('.zip')) {
      await save(await file.readAsString());
      return;
    }
    // Decode and validate before writing anything. No links or executable hooks.
    final archive = await decodeSkillArchive(await file.readAsBytes());
    if (archive.length > 300)
      throw const FormatException('A skill can contain at most 300 files.');
    var total = 0;
    for (final entry in archive) {
      safeSkillPath(entry.name);
      total += entry.size;
      if (entry.isSymbolicLink || total > 32 * 1024 * 1024)
        throw const FormatException(
            'Skill contains a link or exceeds the 32 MB expanded limit.');
    }
    final manifests = archive
        .where((e) =>
            e.isFile && (e.name == 'SKILL.md' || e.name.endsWith('/SKILL.md')))
        .toList();
    if (manifests.length != 1)
      throw const FormatException(
          'Import one skill folder containing one SKILL.md.');
    final manifest = manifests.single;
    if (manifest.size > 2 * 1024 * 1024)
      throw const FormatException('SKILL.md is limited to 2 MB.');
    final def = SkillDefinition.parse(utf8.decode(manifest.content));
    final prefix = manifest.name.substring(0, manifest.name.length - 8);
    final dest = Directory('${root.path}/${def.name}');
    if (await dest.exists())
      throw const FormatException('This skill already exists.');
    final stage = await root.createTemp('.import-');
    try {
      for (final entry in archive) {
        if (!entry.isFile) continue;
        if (!entry.name.startsWith(prefix))
          throw const FormatException(
              'All files must be inside the skill folder.');
        final name = entry.name.substring(prefix.length);
        safeSkillPath(name);
        final target = File('${stage.path}/$name');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.content, flush: true);
      }
      await stage.rename(dest.path);
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
    await reload();
  }

  Future<SkillTurnContext> prepare(String request, Directory workspace,
      {String? attachment}) async {
    final docs = <String, ContextDocument>{};
    final enabled = skills.where((s) => !disabled.contains(s.name)).toList();
    final selected = <String>{};
    for (final (kind, name) in contextMentions(request)) {
      if (kind == 'skill') {
        if (!enabled.any((s) => s.name == name))
          throw FormatException(
              'Skill "$name" is missing or disabled. Open Skills to enable or import it.');
        selected.add(name);
      } else {
        docs['file:$name'] = await _readWorkspaceDocument(workspace, name);
      }
    }
    if (attachment != null && !docs.containsKey('file:$attachment')) {
      try {
        docs['file:$attachment'] =
            await _readWorkspaceDocument(workspace, attachment);
      } catch (_) {
        // Optional attachments retain the existing file tools (including binary
        // summaries and larger files). Explicit @file references still report errors.
      }
    }
    // Rank only descriptions, avoiding full instruction loading for unrelated skills.
    final ranked = bm25Top(
        enabled.map((s) => '${s.name} ${s.description}').toList(), request,
        k: 3);
    for (final i in ranked) {
      selected.add(enabled[i].name);
    }
    for (final skill in enabled.where((s) => selected.contains(s.name))) {
      docs['skill:${skill.name}'] =
          ContextDocument('skill:${skill.name}', skill.body);
    }
    final turn = SkillTurnContext(docs, '');
    // Explicit context first. Full contents remain accessible page by page.
    for (final doc in docs.values) {
      if (doc.pages.isNotEmpty) turn.read(doc.id, 1);
    }
    return turn;
  }

  Future<ContextDocument> _readWorkspaceDocument(
      Directory workspace, String name) async {
    safeSkillPath(name);
    final file = File('${workspace.path}/$name');
    if (!await file.exists())
      throw FormatException('Workspace file "$name" was not found.');
    final resolved = await file.resolveSymbolicLinks();
    final base = await workspace.resolveSymbolicLinks();
    if (!resolved.startsWith('$base${Platform.pathSeparator}'))
      throw const FormatException('File must be inside the current workspace.');
    if (await file.length() > 2 * 1024 * 1024)
      throw const FormatException('Referenced text files are limited to 2 MB.');
    final extension = name.split('.').last.toLowerCase();
    final text = extension == 'pdf' || extension == 'docx'
        ? await DocumentExtractorService.extractText(file.path, extension)
        : utf8.decode(await file.readAsBytes());
    return ContextDocument('file:$name', text);
  }

  void registerTools(AgentService agent) {
    agent.addTool(AgentTool(
        'list_skill_files',
        'List resources bundled with an active skill.',
        '{"name":"skill-name"}', (args) async {
      final name = '${args['name'] ?? ''}';
      if (!(current?.documents.containsKey('skill:$name') ?? false))
        return 'Select an enabled skill with @skill:$name first.';
      final dir = Directory('${root.path}/$name');
      final files = <String>[];
      await for (final file in dir.list(recursive: true, followLinks: false)) {
        if (file is File)
          files.add(
              'skill:$name/${file.path.substring(dir.path.length + 1).replaceAll(Platform.pathSeparator, '/')}');
        if (files.length >= 100) break;
      }
      return 'Read with read_context(source,page):\n${files.join('\n')}';
    }));
    agent.addTool(AgentTool(
        'read_context',
        'Read a selected skill, its bundled resource, or a mentioned workspace file by page (starting at 1).',
        '{"source":"skill:name","page":1}', (args) async {
      final turn = current;
      if (turn == null) return 'No selected context in this turn.';
      var id = '${args['source'] ?? ''}';
      if (!turn.documents.containsKey(id) &&
          id.startsWith('skill:') &&
          id.contains('/')) {
        final slash = id.indexOf('/');
        final name = id.substring(6, slash);
        if (!turn.documents.containsKey('skill:$name'))
          return 'Select this skill first with @skill:$name.';
        final relative = id.substring(slash + 1);
        safeSkillPath(relative);
        final file = File('${root.path}/$name/$relative');
        if (!await file.exists() || await file.length() > 2 * 1024 * 1024)
          return 'Resource missing or larger than 2 MB.';
        turn.documents[id] = ContextDocument(id, await file.readAsString());
      }
      return turn.read(id, (args['page'] as num?)?.toInt() ?? 1);
    }));
    agent.addTool(AgentTool(
        'search_context',
        'Find relevant excerpts in selected skills and mentioned files.',
        '{"query":"keywords"}',
        (args) =>
            current?.search('${args['query'] ?? ''}') ??
            'No selected context.'));
  }
}

void safeSkillPath(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('\\') ||
      name.contains(':') ||
      name.contains('\u0000') ||
      name.split('/').any((s) => s == '..' || s == '.')) {
    throw const FormatException(
        'Unsafe relative path in skill or file reference.');
  }
}

Future<Archive> decodeSkillArchive(List<int> bytes) => Isolate.run(() {
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      var total = 0;
      final names = <String>{};
      if (archive.length > 300)
        throw const FormatException('Too many skill files.');
      for (final entry in archive) {
        safeSkillPath(entry.name);
        if (!names.add(entry.name) || entry.isSymbolicLink)
          throw const FormatException('Duplicate paths or links in skill.');
        total += entry.size;
        if (total > 32 * 1024 * 1024)
          throw const FormatException('Skill exceeds expanded size limit.');
        if (entry.isFile && entry.content.length != entry.size)
          throw const FormatException('Invalid skill file length.');
      }
      return archive;
    });
