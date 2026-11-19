import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/skills_service.dart';
import 'package:neuromesh_ai/utils/skill_context.dart';

const sample =
    '---\nname: code-review\ndescription: Review code and find bugs.\n---\nCheck error paths.\n';
void main() {
  test('standard metadata parses and invalid names are rejected', () {
    expect(SkillDefinition.parse(sample).name, 'code-review');
    expect(
        () => SkillDefinition.parse(
            sample.replaceFirst('code-review', '../escape')),
        throwsFormatException);
    expect(() => SkillDefinition.parse('# No metadata'), throwsFormatException);
  });
  test('context pages preserve source code indentation and trailing whitespace',
      () {
    const source = 'def greet():\n    print("hello")\n\treturn 0\n';
    final doc = ContextDocument('file:main.py', source);
    expect(doc.page(0), endsWith(source));
  });

  test('mentions preserve quoted paths and skills', () {
    expect(
        contextMentions('Use @skill:code-review with @file:"docs/my notes.md"'),
        [('skill', 'code-review'), ('file', 'docs/my notes.md')]);
  });
  test(
      'paged retrieval retains context through history compaction and isolates turns',
      () async {
    final first = SkillTurnContext({
      'skill:test': ContextDocument('skill:test',
          '${'normal words ' * 150} UNIQUE_ERROR_PATH ${'tail ' * 500}')
    }, '');
    final second = SkillTurnContext({}, '');
    expect(
        await first.search('UNIQUE_ERROR_PATH'), contains('UNIQUE_ERROR_PATH'));
    final page = first.read('skill:test', 2);
    expect(first.prompt(2048), contains(page));
    expect(contextTokens(first.prompt(2048)), lessThanOrEqualTo(2048));
    expect(() => first.read('skill:test', 0), throwsRangeError);
    await SkillsService.inTurn(first, () async {
      expect(SkillsService.current, same(first));
      await SkillsService.inTurn(second, () async {
        expect(SkillsService.current, same(second));
      });
      expect(SkillsService.current, same(first));
    });
    expect(SkillsService.current, isNull);
  });
  test('search ranks across files and retains the best returned excerpt',
      () async {
    final context = SkillTurnContext({
      'file:generic':
          ContextDocument('file:generic', 'repair ${'unrelated words ' * 10}'),
      'file:specific': ContextDocument(
          'file:specific', 'repair tokenizer segmentation fault'),
    }, '');
    context.prompt(256);
    final result = await context.search('repair tokenizer segmentation fault');
    expect(result, startsWith('[file:specific'));
    expect(contextTokens(result), lessThanOrEqualTo(256));
    expect(
        context.prompt(1024), contains('repair tokenizer segmentation fault'));
  });

  test('current tool excerpts do not consume the context budget twice', () {
    final context = SkillTurnContext({
      'skill:test':
          ContextDocument('skill:test', 'Keep this unique rule intact.')
    }, '');
    final page = context.read('skill:test', 1);
    expect(context.prompt(512), contains('Keep this unique rule intact.'));
    expect(context.prompt(512, alreadyIncluded: 'Tool result: $page'),
        isNot(contains('Keep this unique rule intact.')));
    expect(context.prompt(512), contains('Keep this unique rule intact.'));
  });

  test('only explicit skill mentions activate conversation skills', () {
    expect(
        previouslyMentionedSkills([
          'Use @skill:code-review',
          'Attached\n\nAttached file: notes.md\n@skill:other'
        ]),
        {'code-review'});
  });

  group('skill storage and imports', () {
    late Directory temp;
    late SkillsService store;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('skills-test-');
      store = SkillsService()..root = Directory('${temp.path}/skills');
      await store.root.create();
    });
    tearDown(() async {
      await temp.delete(recursive: true);
    });
    test('create, edit, disable, exact mentions and missing files', () async {
      await store.save(sample);
      expect(store.skills.single.name, 'code-review');
      await expectLater(store.save(sample), throwsFormatException);
      await store.save('$sample\nMore instructions.', editing: 'code-review');
      final workspace = await Directory('${temp.path}/workspace').create();
      await File('${workspace.path}/notes.md').writeAsString('important notes');
      final context =
          await store.prepare('@skill:code-review @file:notes.md', workspace);
      expect(context.documents.keys,
          containsAll(['skill:code-review', 'file:notes.md']));
      final continued = await store
          .prepare('Continue', workspace, activeSkills: ['code-review']);
      expect(continued.documents.keys, contains('skill:code-review'));
      final fresh = await store.prepare('Hello', workspace);
      expect(fresh.documents, isEmpty);
      await store.toggle('code-review', false);
      final disabled = await store
          .prepare('Continue', workspace, activeSkills: ['code-review']);
      expect(disabled.documents, isEmpty);
      await expectLater(store.prepare('@skill:code-review', workspace),
          throwsFormatException);
      await expectLater(
          store.prepare('@file:missing.md', workspace), throwsFormatException);
      await expectLater(
          store.prepare('@file:../secret', workspace), throwsFormatException);
    });
    test('optional binary attachments preserve the normal file-tool fallback',
        () async {
      final workspace = await Directory('${temp.path}/workspace').create();
      await File('${workspace.path}/binary.zip')
          .writeAsBytes([0xff, 0xfe, 0xfd]);
      final context = await store.prepare('Inspect this archive', workspace,
          attachment: 'binary.zip');
      expect(context.documents, isEmpty);
      await expectLater(
          store.prepare('@file:binary.zip', workspace), throwsFormatException);
    });

    test('mentioned DOCX uses extracted text instead of decoding ZIP bytes',
        () async {
      final workspace = await Directory('${temp.path}/workspace').create();
      const xml =
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Document context</w:t></w:r></w:p></w:body></w:document>';
      final bytes = utf8.encode(xml);
      final doc = Archive()
        ..addFile(ArchiveFile('word/document.xml', bytes.length, bytes));
      await File('${workspace.path}/notes.docx')
          .writeAsBytes(ZipEncoder().encode(doc));
      final context = await store.prepare('@file:notes.docx', workspace);
      expect(context.read('file:notes.docx', 1), contains('Document context'));
    });

    test('zip preserves resources and rejects traversal without overwriting',
        () async {
      final zip = File('${temp.path}/skill.zip');
      final good = Archive()
        ..addFile(ArchiveFile('code-review/SKILL.md',
            utf8.encode(sample).length, utf8.encode(sample)))
        ..addFile(ArchiveFile(
            'code-review/references/errors.md', 5, utf8.encode('rules')));
      await zip.writeAsBytes(ZipEncoder().encode(good));
      await store.importFile(zip.path);
      expect(
          await File('${store.root.path}/code-review/references/errors.md')
              .readAsString(),
          'rules');
      final bad = Archive()
        ..addFile(ArchiveFile('../outside', 3, utf8.encode('bad')));
      await zip.writeAsBytes(ZipEncoder().encode(bad));
      await expectLater(store.importFile(zip.path), throwsFormatException);
      expect(await File('${temp.path}/outside').exists(), isFalse);
      expect(
          await File('${store.root.path}/code-review/SKILL.md').readAsString(),
          sample);
    });
  });
}
