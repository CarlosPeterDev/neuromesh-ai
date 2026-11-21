import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/widgets/model_access_notice.dart';

void main() {
  testWidgets('setup explains access and opens explicit permissions review',
      (tester) async {
    var reviewed = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelAccessNotice(onReview: () => reviewed = true))));
    expect(find.textContaining('grants no microphone'), findsOneWidget);
    expect(reviewed, false);
    await tester.tap(find.text('Review tools & permissions'));
    expect(reviewed, true);
  });
}
