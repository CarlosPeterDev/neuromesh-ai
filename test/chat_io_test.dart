import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/chat_io.dart';

void main() {
  final session = {'id': 's1', 'title': 'Hello'};
  final msgs = [
    {'role': 'user', 'content': 'Hi', 'imageBase64': 'AAAA'},
    {'role': 'assistant', 'content': 'Hey there'},
  ];

  test('markdown has titles and roles', () {
    final md = chatToMarkdown(session, msgs);
    expect(md, contains('# Hello'));
    expect(md, contains('### You'));
    expect(md, contains('Hey there'));
  });

  test('json round trip drops images', () {
    final parsed = parseChatJson(chatToJson(session, msgs));
    expect(parsed.session['id'], 's1');
    expect(parsed.messages.length, 2);
    expect(parsed.messages.first.containsKey('imageBase64'), false);
  });

  test('rejects foreign json', () {
    expect(() => parseChatJson('{"a":1}'), throwsFormatException);
    expect(() => parseChatJson('nope'), throwsFormatException);
    expect(() => parseBackup('{"format":"x"}'), throwsFormatException);
  });

  test('backup round trip', () {
    final b = parseBackup(buildBackup(
        sessions: [session], messages: msgs, settings: {'temperature': 0.5}));
    expect(b.sessions.length, 1);
    expect(b.messages.length, 2);
    expect(b.settings['temperature'], 0.5);
  });

  test('secrets are stripped and logs sanitized', () {
    final s = stripSecrets({'openai_key': 'x', 'server_api_key': 'y', 'temperature': 1});
    expect(s.keys, ['temperature']);
    expect(sanitizeLog('Authorization: Bearer abcdefgh12345'), isNot(contains('abcdefgh12345')));
    expect(sanitizeLog('token=hf_abcdefghijklmnop'), isNot(contains('abcdefghijklmnop')));
  });
}
