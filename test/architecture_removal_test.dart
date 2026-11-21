import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/controllers/home_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('removed integrations cannot be opened through root navigation', () {
    final home = HomeController();
    addTearDown(home.onClose);
    home.changeTab(3);
    expect(home.currentTab.value, 3);
    home.changeTab(4);
    expect(home.currentTab.value, 3);
    home.changeTab(-1);
    expect(home.currentTab.value, 3);
    for (final path in [
      'lib/views/agent_hub_view.dart',
      'lib/services/opencode_adapter.dart',
      'lib/services/local_image_service.dart',
      'lib/views/web_image_gen_test_view.dart'
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
    final settings = File('lib/views/settings_view.dart').readAsStringSync();
    expect(settings, isNot(contains("title: 'Image generation'")));
    final dependencies = File('pubspec.yaml').readAsStringSync();
    expect(dependencies, isNot(contains('sd_flutter_android')));
    expect(File('lib/services/pollinations_image_service.dart').existsSync(),
        isTrue);
  });
}
