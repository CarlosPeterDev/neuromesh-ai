// Native/gallery/share calls are mocked; files, checksums and widget routes are real.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
// Platform mocks for existing plugins.
// ignore: implementation_imports
import 'package:gal/src/gal_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/output_file_service.dart';
import 'package:neuromesh_ai/services/voice_service.dart';
import 'package:neuromesh_ai/widgets/agent_steps.dart';
import 'package:neuromesh_ai/widgets/image_viewer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  late Directory dir;
  late Uint8List jpeg;
  late GalPlatform gallery;
  late SharePlatform share;
  late PathProviderPlatform paths;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('generated-output-');
    jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 3, height: 3)));
    Hive.init('${dir.path}/db');
    Get.put(await HiveService().init());
    Get.put<AgentService>(_Files(dir));
    gallery = GalPlatform.instance;
    share = SharePlatform.instance;
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
  });
  tearDown(() async {
    GalPlatform.instance = gallery;
    SharePlatform.instance = share;
    PathProviderPlatform.instance = paths;
    debugDefaultTargetPlatformOverride = null;
    Get.reset();
    await Hive.close();
    await dir.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.neuromesh.ai/device'), null);
  });

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var attempt = 0; attempt < 200 && !ready(); attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(ready(), isTrue,
        reason:
            'The expected output did not become available: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()}');
  }

  testWidgets(
      'opened generated image has Save and Share; shared JPEG keeps its type',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final sharing = _Share();
    SharePlatform.instance = sharing;
    final file = File('${dir.path}/moon.jpg');
    file.writeAsBytesSync(jpeg);
    await tester.pumpWidget(GetMaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => ImageViewer.showFile(context, file),
                    child: const Text('Open image'))))));
    await tester.tap(find.text('Open image'));
    await until(tester, () => find.byType(ImageViewer).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    await tester.tap(find.text('Share'));
    await until(tester, () => sharing.called.isCompleted);
    expect(sharing.called.isCompleted, isTrue,
        reason: find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .toList()
            .toString());
    expect(sharing.mime, 'image/jpeg');
    expect(sharing.path, endsWith('.jpg'));
    expect(sharing.bytes, jpeg);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'Save sends actual bytes to the gallery and denial performs no write',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final saving = _Gallery();
    GalPlatform.instance = saving;
    await tester.pumpWidget(
        GetMaterialApp(home: ImageViewer(base64Image: base64Encode(jpeg))));
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(saving.saved, jpeg);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    saving.allowed = false;
    saving.saved = null;
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(saving.saved, isNull);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('invalid image disables Save and Share instead of crashing',
      (tester) async {
    await tester.pumpWidget(
        GetMaterialApp(home: const ImageViewer(base64Image: 'invalid!')));
    expect(find.text('This image could not be opened.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find
                .ancestor(
                    of: find.text('Save'),
                    matching: find.byWidgetPredicate((w) => w is FilledButton))
                .first)
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
  });

  test(
      'audio Save uses one-document native consent and requires verified bytes',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final file = File('${dir.path}/speech.wav');
    await file.writeAsBytes([82, 73, 70, 70, 1, 2, 3, 4]);
    final digest = sha256.convert(await file.readAsBytes()).toString();
    var requests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.neuromesh.ai/device'), (call) async {
      expect(call.method, 'saveOutputFile');
      expect(call.arguments['path'], file.path);
      expect(call.arguments['sha256'], digest);
      requests++;
      return {
        'uri': 'content://test/speech.wav',
        'bytes': 8,
        'sha256': digest,
        'verified': requests == 1
      };
    });
    expect(await OutputFileService.save(file), 'content://test/speech.wav');
    await expectLater(OutputFileService.save(file), throwsStateError);
    expect(requests, 2);
  });

  test('cancelling Save produces no success reference', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final file = File('${dir.path}/speech.wav');
    await file.writeAsBytes([1]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.neuromesh.ai/device'), (_) async => null);
    expect(await OutputFileService.save(file), isNull);
  });

  testWidgets('audio has a real Save action, not a share-sheet shortcut',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channels = <String>[
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events'
    ];
    for (final name in channels) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        final name =
            'xyz.luan/audioplayers/events/${call.arguments['playerId']}';
        channels.add(name);
        messenger.setMockMethodCallHandler(
            MethodChannel(name), (_) async => null);
      }
      return null;
    });
    final file = File('${dir.path}/speech.wav');
    file.writeAsBytesSync(encodeWav(Float32List(160), 16000));
    var saved = false;
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.neuromesh.ai/device'), (call) async {
      saved = call.method == 'saveOutputFile';
      return {
        'uri': 'content://test/speech.wav',
        'bytes': file.lengthSync(),
        'sha256': sha256.convert(file.readAsBytesSync()).toString(),
        'verified': true
      };
    });
    try {
      await tester.pumpWidget(GetMaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => openAgentFile(context, 'speech.wav'),
                      child: const Text('Open audio'))))));
      await tester.tap(find.text('Open audio'));
      await until(tester, () => find.text('Save').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Share / save'), findsNothing);
      final button = tester.widget<OutlinedButton>(find
          .ancestor(
              of: find.text('Save'),
              matching: find.byWidgetPredicate((w) => w is OutlinedButton))
          .first);
      button.onPressed!();
      await until(tester, () => saved);
      await tester.pump();
      expect(saved, isTrue);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('speech.wav'))).pop();
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    }
  });

  testWidgets(
      'chat image taps open the shared viewer rather than sharing immediately',
      (tester) async {
    final file = File('${dir.path}/moon.jpg');
    file.writeAsBytesSync(jpeg);
    await tester.pumpWidget(GetMaterialApp(
        home:
            Scaffold(body: agentImage(Uri.parse('nmfile:moon.jpg'), 'Moon'))));
    await until(tester, () => find.byType(Image).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byType(Image));
    await until(tester, () => find.byType(ImageViewer).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}

final class _Gallery extends GalPlatform {
  bool allowed = true;
  Uint8List? saved;
  @override
  Future<bool> hasAccess({bool toAlbum = false}) async => allowed;
  @override
  Future<bool> requestAccess({bool toAlbum = false}) async => allowed;
  @override
  Future<void> putImageBytes(Uint8List bytes,
      {String? album, required String name}) async {
    saved = bytes;
  }
}

class _Share extends SharePlatform {
  final called = Completer<void>();
  Uint8List? bytes;
  String? path, mime;
  @override
  Future<ShareResult> shareXFiles(List<XFile> files,
      {String? subject,
      String? text,
      Rect? sharePositionOrigin,
      List<String>? fileNameOverrides}) async {
    final file = files.single;
    bytes = await file.readAsBytes();
    path = file.path;
    mime = file.mimeType;
    called.complete();
    return const ShareResult('test', ShareResultStatus.success);
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Files extends AgentService {
  _Files(this.dir);
  final Directory dir;
  @override
  Future<Directory> filesDir() async => dir;
}
