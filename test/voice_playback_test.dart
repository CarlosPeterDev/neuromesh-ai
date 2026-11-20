import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/voice_service.dart';

class _Player implements AudioPlayer {
  final completed = StreamController<void>.broadcast(sync: true);
  final started = Completer<void>();
  Completer<void>? prepare;
  bool autoComplete = true;
  Object? error;
  bool playing = false;
  int plays = 0;
  final paths = <String>[];

  @override
  Stream<void> get onPlayerComplete => completed.stream;

  @override
  Future<void> play(Source source,
      {double? volume,
      double? balance,
      AudioContext? ctx,
      Duration? position,
      PlayerMode? mode}) async {
    plays++;
    paths.add((source as DeviceFileSource).path);
    if (!started.isCompleted) started.complete();
    await prepare?.future;
    playing = true;
    if (error != null) completed.addError(error!, StackTrace.current);
    if (autoComplete) {
      playing = false;
      completed.add(null);
    }
  }

  @override
  Future<void> stop() async => playing = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Player player;
  late MockClient client;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('voice-playback-');
    player = _Player();
    client = MockClient((request) async => http.Response.bytes(
        encodeWav(Float32List.fromList([0, .1, 0]), 16000), 200));
  });

  tearDown(() async {
    client.close();
    await player.completed.close();
    await directory.delete(recursive: true);
  });

  VoiceService service({
    Future<Directory> Function()? temporaryDirectory,
    Duration playbackGrace = const Duration(seconds: 5),
  }) =>
      VoiceService(
          player: player,
          workerClient: client,
          playbackGrace: playbackGrace,
          temporaryDirectory: temporaryDirectory ?? () async => directory)
        ..workerUrl = 'http://worker.invalid:8765';

  test('an interruption during WAV preparation never starts playback',
      () async {
    final entered = Completer<void>();
    final ready = Completer<Directory>();
    final voice = service(temporaryDirectory: () {
      entered.complete();
      return ready.future;
    });
    final speaking = voice.speak('Hello there.');
    await entered.future;
    await voice.stopSpeaking();
    ready.complete(directory);
    await speaking;
    expect(player.plays, 0);
    expect(player.completed.hasListener, isFalse);
  });

  test('a late native play completion cannot undo an interruption', () async {
    player.prepare = Completer<void>();
    player.autoComplete = false;
    final voice = service();
    final speaking = voice.speak('Hello there.');
    await player.started.future;
    await voice.stopSpeaking();
    player.prepare!.complete();
    await speaking;
    expect(player.playing, isFalse);
    expect(player.completed.hasListener, isFalse);
  });

  test('stopping active audio releases its completion listener', () async {
    player.autoComplete = false;
    final voice = service();
    final speaking = voice.speak('Hello there.');
    await player.started.future;
    await Future<void>.delayed(Duration.zero);
    expect(player.completed.hasListener, isTrue);
    await voice.stopSpeaking();
    await speaking;
    expect(player.completed.hasListener, isFalse);
  });

  test('normal completion releases its listener for the next sentence',
      () async {
    final voice = service();
    await voice.speak('Hello there.');
    await voice.speak('A second sentence.');
    expect(player.plays, 2);
    expect(player.paths.toSet(), hasLength(2));
    expect(directory.listSync(), isEmpty);
    expect(player.completed.hasListener, isFalse);
  });

  test('missing completion clears playback and lets the next sentence play',
      () async {
    player.autoComplete = false;
    final voice = service(playbackGrace: const Duration(milliseconds: 20));
    final playback = <bool>[];
    await expectLater(voice.speak('First sentence.', onPlayback: playback.add),
        throwsA(isA<TimeoutException>()));
    expect(playback, [true, false]);
    expect(player.playing, isFalse);
    expect(player.completed.hasListener, isFalse);

    player.autoComplete = true;
    await voice.speak('Second sentence.');
    expect(player.plays, 2);
  });

  test('silent WAV output fails without entering playback', () async {
    client.close();
    client = MockClient((_) async =>
        http.Response.bytes(encodeWav(Float32List(20), 16000), 200));
    final playback = <bool>[];
    await expectLater(service().speak('Hello there.', onPlayback: playback.add),
        throwsFormatException);
    expect(playback, isEmpty);
    expect(player.plays, 0);
  });

  test('native playback errors reach the caller and release the listener',
      () async {
    player.error = StateError('Audio output disconnected');
    player.autoComplete = false;
    await expectLater(service().speak('Hello there.'), throwsStateError);
    expect(player.playing, isFalse);
    expect(player.completed.hasListener, isFalse);
  });

  test('a stopped worker failure never falls back to system speech', () async {
    client.close();
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    client = MockClient((_) {
      requested.complete();
      return response.future;
    });
    final voice = service();
    final speaking = voice.speak('Hello there.');
    await requested.future;
    await voice.stopSpeaking();
    response.complete(http.Response('Worker unavailable', 503));
    await speaking;
    expect(player.plays, 0);
    expect(player.completed.hasListener, isFalse);
  });

  test('stopping a pending worker does not wait for its response', () async {
    client.close();
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    client = MockClient((request) {
      expect(request.followRedirects, isFalse);
      requested.complete();
      return response.future;
    });
    final voice = service();
    final speaking = voice.speak('Hello there.');
    await requested.future;
    await voice.stopSpeaking();
    await speaking.timeout(const Duration(seconds: 1));
    expect(response.isCompleted, isFalse);
    response.completeError(http.ClientException('Worker disconnected'));
    await Future<void>.delayed(Duration.zero);
    expect(player.plays, 0);
  });
}
