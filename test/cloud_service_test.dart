import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/cloud_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';

String _chunk(String token, {String? finish}) => 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': token},
              'finish_reason': finish,
            }
          ]
        })}\n\n';

void main() {
  late Directory dir;
  late HttpServer server;
  late CloudService cloud;
  // What the fake provider streams back for the next request.
  late Future<void> Function(HttpResponse res) respond;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cloud_test');
    Hive.init(dir.path);
    final hive = await HiveService().init();
    Get.put(hive);
    Get.put(AppLogService());

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await req.drain<void>();
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      await respond(req.response);
    });

    await hive.setSetting(AppConstants.keyCloudProvider, 'custom');
    await hive.setSetting(
        AppConstants.keyCustomCloudBaseUrl, 'http://127.0.0.1:${server.port}');
    await hive.setSetting(AppConstants.keyCustomCloudKey, 'test-key');
    await hive.setSetting(AppConstants.keyCustomCloudModel, 'test-model');
    cloud = CloudService();
  });

  tearDown(() async {
    CloudService.streamIdleTimeout = const Duration(seconds: 60);
    await server.close(force: true);
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  Future<String> send(List<String> tokens) => cloud.sendMessage(
        messages: [
          {'role': 'user', 'content': 'hi'}
        ],
        onToken: tokens.add,
      );

  Future<String?> nativeTools() => cloud.tryNativeTools(
        messages: const [
          {'role': 'user', 'content': 'Use a calculator.'}
        ],
        allowed: {'calculator'},
        onToken: (_) {},
      );

  test('joins a native function call split across stream events', () async {
    respond = (res) async {
      for (final (name, arguments, finish) in [
        ('calculator', '{"expression":', null),
        (null, '"2+2"}', 'tool_calls'),
      ]) {
        res.write('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'function': {
                          'name': name,
                          'arguments': arguments,
                        }
                      }
                    ]
                  },
                  'finish_reason': finish,
                }
              ]
            })}\n\n');
      }
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    expect(await nativeTools(),
        '<tool_call>{"name":"calculator","arguments":{"expression":"2+2"}}</tool_call>');
  });

  test('a provider protocol rejection is cached for that endpoint and model',
      () async {
    var requests = 0;
    respond = (res) async {
      requests++;
      res.statusCode = 400;
      await res.close();
    };
    expect(await nativeTools(), isNull);
    expect(await nativeTools(), isNull);
    expect(requests, 1);
  });

  test('a complete stream returns the text', () async {
    respond = (res) async {
      res.write(_chunk('Hello '));
      res.write(_chunk('world', finish: 'stop'));
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    final tokens = <String>[];
    expect(await send(tokens), 'Hello world');
    expect(tokens.join(), 'Hello world');
  });

  test('an error event mid-stream is reported, not shown as a reply', () async {
    respond = (res) async {
      res.write(_chunk('Partial '));
      res.write('data: ${jsonEncode({
            'error': {'message': 'Rate limit exceeded'}
          })}\n\n');
      await res.close();
    };
    final result = await send([]);
    expect(result, startsWith('Partial'));
    expect(result, contains('Rate limit exceeded'));
  });

  test('an error event before any text is an ERROR', () async {
    respond = (res) async {
      res.write('data: ${jsonEncode({'error': 'upstream failed'})}\n\n');
      await res.close();
    };
    expect(await send([]), startsWith('ERROR:'));
  });

  test('a stream that ends without [DONE] is marked as cut off', () async {
    respond = (res) async {
      res.write(_chunk('Half an answer'));
      await res.close();
    };
    final result = await send([]);
    expect(result, startsWith('Half an answer'));
    expect(result, contains('cut off'));
  });

  test('an empty stream is an ERROR, not a blank reply', () async {
    respond = (res) async {
      res.write('data: [DONE]\n\n');
      await res.close();
    };
    expect(await send([]), startsWith('ERROR:'));
  });

  test('a stalled stream times out instead of hanging', () async {
    CloudService.streamIdleTimeout = const Duration(milliseconds: 300);
    respond = (res) async {
      res.write(_chunk('Start'));
      await res.flush(); // ...then nothing more
      await Future.delayed(const Duration(seconds: 5));
    };
    final result = await send([]).timeout(const Duration(seconds: 3));
    expect(result, startsWith('ERROR:'));
    expect(result, contains("didn't respond in time"));
  });

  test('cancel() aborts the stream in progress', () async {
    respond = (res) async {
      res.write(_chunk('Start'));
      await res.flush();
      await Future.delayed(const Duration(seconds: 5));
    };
    final pending = send([]);
    await Future.delayed(const Duration(milliseconds: 200));
    cloud.cancel();
    expect(await pending.timeout(const Duration(seconds: 2)),
        startsWith('ERROR:'));
  });
}
