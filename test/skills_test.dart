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
    expect(first.search('UNIQUE_ERROR_PATH'), contains('UNIQUE_ERROR_PATH'));
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
      await store.toggle('code-review', false);
      await expectLater(store.prepare('@skill:code-review', workspace),
          throwsFormatException);
      await expectLater(
          store.prepare('@file:missing.md', workspace), throwsFormatException);
      await expectLater(
          store.prepare('@file:../secret', workspace), throwsFormatException);
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
