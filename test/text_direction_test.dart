import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/text_direction.dart';

void main() {
  test('detects direction from first letter', () {
    expect(detectDirection('مرحبا بك'), TextDirection.rtl);
    expect(detectDirection('Hello مرحبا'), TextDirection.ltr);
    expect(detectDirection('123 مرحبا'), TextDirection.rtl);
    expect(detectDirection(''), TextDirection.ltr);
  });
}
