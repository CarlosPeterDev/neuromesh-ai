import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/workload_placement.dart';

void main() {
  final worker = WorkloadWorker.parse(
      'http://192.168.1.20:8765', List.filled(32, 'a').join())!;

  test('cancelled worker requests return before a late network error',
      () async {
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final cancel = Completer<void>();
    final client = MockClient((request) {
      expect(request.followRedirects, isFalse);
      requested.complete();
      return response.future;
    });
    addTearDown(client.close);
    final result = worker.request('/speech',
        payload: {'text': 'Hello'},
        httpClient: client,
        cancelled: cancel.future);
    final expectation = expectLater(result, throwsA(isA<WorkloadCancelled>()));
    await requested.future;
    cancel.complete();
    await expectation.timeout(const Duration(seconds: 1));
    expect(response.isCompleted, isFalse);
    response.completeError(http.ClientException('Disconnected'));
    await Future<void>.delayed(Duration.zero);
  });

  test('normal workers still return response bytes', () async {
    final client = MockClient((_) async => http.Response('voice bytes', 200));
    addTearDown(client.close);
    expect(utf8.decode(await worker.request('/speech', httpClient: client)),
        'voice bytes');
  });
}
