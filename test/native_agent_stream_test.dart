// Deterministic provider-stream tests; no live cloud credentials are used.
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:neuromesh_ai/services/native_agent_stream.dart';

void main() {
  Future<({Map<String, dynamic> data, bool streamed})> read(
          Stream<List<int>> source, String provider, List<String> visible) =>
      readNativeAgentResponse(
          http.StreamedResponse(source, 200,
              headers: {'content-type': 'text/event-stream'}),
          provider: provider,
          idleTimeout: const Duration(seconds: 1),
          onText: visible.add);
  List<int> event(Object data) => utf8.encode('data: ${jsonEncode(data)}\n\n');
  Map<String, dynamic> openai(Map<String, dynamic> delta, [String? finish]) => {
        'choices': [
          {'delta': delta, 'finish_reason': finish}
        ]
      };

  test('OpenAI text is visible before the response completes', () async {
    final source = StreamController<List<int>>();
    final seen = <String>[];
    var completed = false;
    final result = read(source.stream, 'openai', seen)
      ..then((_) => completed = true);
    final first = event(openai({'content': 'Hello 🌌'}));
    source.add(first.sublist(0, first.length - 4));
    source.add(first.sublist(first.length - 4));
    await Future<void>.delayed(Duration.zero);
    expect(seen.join(), 'Hello 🌌');
    expect(completed, isFalse);
    source.add(event(openai({'content': ' there'}, 'stop')));
    source.add(utf8.encode('data: [DONE]\n\n'));
    await source.close();
    expect((await result).data['choices'][0]['message']['content'],
        'Hello 🌌 there');
  });

  test('fragmented tool arguments remain hidden until complete', () async {
    final seen = <String>[];
    final events = [
      openai({
        'tool_calls': [
          {
            'index': 0,
            'id': 'call_1',
            'function': {'name': 'calculator', 'arguments': '{"expression":'}
          }
        ]
      }),
      openai({
        'tool_calls': [
          {
            'index': 0,
            'function': {'arguments': '"17*19"}'}
          }
        ]
      }, 'tool_calls'),
    ];
    final result =
        await read(Stream.fromIterable(events.map(event)), 'openai', seen);
    final call = result.data['choices'][0]['message']['tool_calls'][0];
    expect(jsonDecode(call['function']['arguments']), {'expression': '17*19'});
    expect(seen, isEmpty);
  });

  test('truncated calls never become executable results', () async {
    await expectLater(
        read(
            Stream.value(event(openai({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'partial',
                  'function': {
                    'name': 'calculator',
                    'arguments': '{"expression":"1+1"}'
                  }
                }
              ]
            }))),
            'openai',
            []),
        throwsA(isA<NativeAgentStreamError>()));
  });

  test('a stream error preserves the text already received', () async {
    final seen = <String>[];
    await expectLater(
        read(
            Stream.fromIterable([
              event(openai({'content': 'Partial answer'})),
              event({
                'error': {'message': 'upstream failed'}
              })
            ]),
            'openai',
            seen),
        throwsA(isA<NativeAgentStreamError>()
            .having((e) => e.partialText, 'partialText', 'Partial answer')));
    expect(seen.join(), 'Partial answer');
  });

  test('Google streams text and retains opaque tool signatures', () async {
    final source = StreamController<List<int>>();
    final seen = <String>[];
    final result = read(source.stream, 'google', seen);
    source.add(event({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'Here is '}
            ]
          }
        }
      ]
    }));
    await Future<void>.delayed(Duration.zero);
    expect(seen.join(), 'Here is ');
    source.add(event({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'functionCall': {
                  'name': 'calculator',
                  'args': {'expression': '2+2'}
                },
                'thoughtSignature': 'opaque'
              }
            ]
          },
          'finishReason': 'STOP'
        }
      ]
    }));
    await source.close();
    final parts =
        (await result).data['candidates'][0]['content']['parts'] as List;
    expect(parts.last['thoughtSignature'], 'opaque');
    expect(seen.join(), 'Here is ');
  });

  test('Anthropic streams text and assembles tool JSON without exposing it',
      () async {
    final seen = <String>[];
    final result = await read(
        Stream.fromIterable([
          event({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''}
          }),
          event({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': 'Calculating'}
          }),
          event({
            'type': 'content_block_start',
            'index': 1,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'calculator',
              'input': {}
            }
          }),
          event({
            'type': 'content_block_delta',
            'index': 1,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"expression":'
            }
          }),
          event({
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'input_json_delta', 'partial_json': '"2+2"}'}
          }),
          event({
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'}
          }),
          event({'type': 'message_stop'})
        ]),
        'anthropic',
        seen);
    expect(seen.join(), 'Calculating');
    expect(result.data['content'][1]['input'], {'expression': '2+2'});
  });

  test('max-token termination rejects pending actions', () async {
    await expectLater(
        read(Stream.value(event(openai({'content': 'Incomplete'}, 'length'))),
            'openai', []),
        throwsA(isA<NativeAgentStreamError>()));
  });
}
