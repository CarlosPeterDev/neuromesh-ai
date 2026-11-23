import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/widgets/startup_gate.dart';

void main() {
  testWidgets('delay, storage failure and retry gate dependent app startup',
      (tester) async {
    final storage = Completer<void>();
    var opens = 0;
    var starts = 0;
    var errors = 0;
    await tester.pumpWidget(StartupGate(
      openStorage: () {
        opens++;
        return opens == 1 ? storage.future : Future<void>.value();
      },
      startApp: () async {
        starts++;
        return const MaterialApp(home: Text('Ready'));
      },
      onError: (_, __) => errors++,
    ));
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('Starting NeuroMesh…'), findsOneWidget);
    expect(starts, 0);
    storage.completeError(StateError('Corrupt or inaccessible storage'));
    await tester.pumpAndSettle();
    expect(errors, 1);
    expect(starts, 0);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(opens, 2);
    expect(starts, 1);
    expect(find.text('Ready'), findsOneWidget);
  });
}
