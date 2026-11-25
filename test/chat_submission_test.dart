import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
// Platform mock for the app's existing path_provider dependency.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:neuromesh_ai/services/chat_calculator.dart';
import 'package:neuromesh_ai/controllers/chat_controller.dart';
import 'package:neuromesh_ai/controllers/settings_controller.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/models/chat_message.dart';
import 'package:neuromesh_ai/models/chat_session.dart';
import 'package:neuromesh_ai/services/chat_tool_service.dart';
import 'package:neuromesh_ai/services/chat_tool_intent.dart';
import 'package:neuromesh_ai/services/chat_tool_loop.dart';
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/cloud_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/services/local_image_service.dart';
import 'package:neuromesh_ai/services/web_search_service.dart';
import 'package:neuromesh_ai/services/voice_service.dart';
import 'package:neuromesh_ai/services/voice_models.dart';
import 'package:neuromesh_ai/utils/web_search_parse.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late HiveService hive;
  late ChatController chat;
  late _WorkspaceAgent agent;
  late _TestCloud cloud;
  late _TestNarrationInference local;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chat_submission');
    Hive.init(dir.path);
    hive = Get.put(await HiveService().init());
    await hive.setSetting(AppConstants.keyInferenceMode, 'cloud');
    Get.put(SettingsController());
    local = _TestNarrationInference();
    Get.put<InferenceService>(local);
    Get.put(AppLogService());
    Get.put(LocalImageService());
    cloud = Get.put<CloudService>(_TestCloud()) as _TestCloud;
    agent = Get.put<ChatToolService>(_WorkspaceAgent()) as _WorkspaceAgent;
    chat = Get.put(ChatController());
  });

  tearDown(() async {
    await Get.delete<ChatController>();
    Get.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  void attachDocument() {
    chat.selectedFileName.value = 'notes.txt';
    chat.selectedFilePath.value = '${dir.path}/notes.txt';
    chat.selectedFileContent.value = 'Document contents';
    chat.selectedFileType.value = 'text';
    chat.textController.text = 'Read this';
  }

  void useTestWorkspace() {
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(dir.path);
    addTearDown(() => PathProviderPlatform.instance = previous);
  }

  Future<String> outputTextFile() async {
    final name = RegExp(r'nmfile:([a-zA-Z0-9_-]+\.txt)\)')
        .firstMatch(chat.messages.last.content)
        ?.group(1);
    expect(name, isNotNull, reason: chat.messages.last.content);
    final file = await agent.workspaceFile(name!);
    return file!.readAsString();
  }

  Future<void> useGguf(String route) async {
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    await hive.setSetting('auto_title', false);
    local.isModelLoaded.value = true;
    local.loadedModelRuntime.value = 'llama';
    local.toolCompletions.add(route);
  }

  test('attachment transcription accepts an audio attachment without a prompt',
      () async {
    useTestWorkspace();
    final voice =
        Get.put<VoiceService>(_TestTranscription()) as _TestTranscription;
    final audio = await File('${dir.path}/note.wav').create();
    chat.selectedFileName.value = 'note.wav';
    chat.selectedFileType.value = 'audio';
    chat.selectedFilePath.value = audio.path;

    await chat.sendMessage();

    expect(voice.path, audio.path);
    expect(chat.messages.last.content, contains('A recorded note.'));
    expect(chat.messages.last.content, contains(ToolLoopResult.traceMark));
    expect(chat.messages.first.visibleUserText, 'Transcribe audio');
    expect(chat.messages.first.attachmentOnly, isTrue);
    final transcript = await outputTextFile();
    expect(transcript, isNotEmpty);
    expect(cloud.calls, 0);
    expect(local.calls, 0);
  });

  final whisperRoot = Platform.environment['NEUROMESH_TEST_WHISPER_TINY'];
  test(
      'attachment transcription recognizes the Whisper fixture without chat inference',
      () async {
    useTestWorkspace();
    Get.put<VoiceModelStore>(_WhisperFixture(whisperRoot!));
    Get.put(VoiceService(player: _UnusedPlayer()));
    chat.selectedFileName.value = '0.wav';
    chat.selectedFileType.value = 'audio';
    chat.selectedFilePath.value = '$whisperRoot/test_wavs/0.wav';

    await chat.sendMessage();

    expect((await outputTextFile()).toLowerCase(),
        contains('the yellow lamps would light up'));
    expect(chat.messages.last.content, contains(ToolLoopResult.traceMark));
    expect(cloud.calls, 0);
    expect(local.calls, 0);
  },
      skip: whisperRoot == null
          ? 'Set NEUROMESH_TEST_WHISPER_TINY to the extracted model directory'
          : false);

  test('a prose decision keeps the full tool catalog out of a 512-token chat',
      () async {
    await useGguf('chat');
    local.contextTokensTotal.value = 512;
    local.answer = 'Hello!';
    chat.textController.text = 'Hi';
    await chat.sendMessage();
    expect(chat.messages.last.content, 'Hello!');
    expect(local.lastSystem, isNot(contains(ChatToolLoop.callPrefix)));
  });

  test('a text-only model transcribes an attached recording with a note',
      () async {
    useTestWorkspace();
    Get.put<VoiceService>(_TestTranscription());
    final audio = await File('${dir.path}/note.wav').create();
    chat.selectedFileName.value = 'note.wav';
    chat.selectedFileType.value = 'audio';
    chat.selectedFilePath.value = audio.path;
    chat.textController.text = 'Put the words in a text file.';
    await chat.sendMessage();
    expect(await outputTextFile(), 'A recorded note.');
    expect(local.calls, 0);
    expect(cloud.calls, 0);
  });

  test('local routing plans search and saves citeable results', () async {
    final web = Get.put<WebSearchService>(_TestWeb()) as _TestWeb;
    await useGguf('search');
    local.answer = 'Here is the benchmark [1].';
    chat.textController.text = 'تاريخ الطباعة';
    await chat.sendMessage();

    expect(web.queries, ['تاريخ الطباعة']);
    expect(local.sources.first, toolCompletionSource);
    expect(cloud.calls, 0);
    expect(chat.messages.last.content, contains(ToolLoopResult.traceMark));
    expect(
        chat.messages.last.content, contains('https://example.com/benchmark'));
    expect(chat.messages.last.toolSearches.single['query'], 'تاريخ الطباعة');
  });

  test('local routing produces verified Calc results and steps', () async {
    await useGguf('math');
    local.toolCompletions.add('8');
    chat.textController.text =
        'Calculate ((84729 × 93617) + sqrt(987654321)) / (137.29^2 + 17.83), rounded to 8 decimal places.';
    await chat.sendMessage();
    expect(chat.messages.last.content, contains('420436.17803423'));
    expect(chat.messages.last.content, contains('7932074793'));
    expect(local.sources, [toolCompletionSource, toolCompletionSource]);
  });

  test('local routing produces an image and extracts spoken words', () async {
    await useGguf('image');
    chat.textController.text = 'A flying car';
    await chat.sendMessage();
    expect(agent.imageCall?.arguments['prompt'], 'A flying car');
    expect(chat.messages.last.content, contains('nmfile:generated.jpg'));

    local.toolCompletions.addAll(['audio', '["Hello, Carlos!", "male"]']);
    chat.textController.text =
        'Make a recording of a male voice saying Hello, Carlos!';
    await chat.sendMessage();
    expect(agent.narration?.arguments['text'], 'Hello, Carlos!');
    expect(chat.messages.last.content, contains('nmfile:research.wav'));
    expect(agent.narration?.arguments['voice'], 'male');
    expect(local.sources, [
      toolCompletionSource,
      InferenceService.toolPlanSource,
      toolCompletionSource,
      toolCompletionSource,
    ]);
  });

  test('local routing saves generated text in a downloadable file', () async {
    useTestWorkspace();
    await useGguf('file');
    local.answer = 'سماء زرقاء';
    chat.textController.text = 'Save this as text: سماء زرقاء';
    await chat.sendMessage();
    expect(await outputTextFile(), 'سماء زرقاء');
    expect(chat.messages.last.content, contains('Text file ready.'));
    expect(local.lastSystem, contains('requested plain-text file contents'));
  });

  test('automatic search respects the block policy', () async {
    final web = Get.put<WebSearchService>(_TestWeb()) as _TestWeb;
    await useGguf('search');
    local.answer = 'Please try again.';
    await agent.setPolicy('built-in', 'web_search', 'block');
    chat.textController.text = 'What is happening in Cairo today?';
    await chat.sendMessage();
    expect(web.queries, isEmpty);
  });

  test('cancelling automatic Search aborts the provider', () async {
    final web = Get.put<WebSearchService>(_PendingSearch()) as _PendingSearch;
    await useGguf('search');
    chat.textController.text = 'What is happening in Cairo today?';
    final sent = chat.sendMessage();
    await web.started.future;
    chat.stopGenerating();
    await sent;
    await web.aborted.future;
    expect(chat.isLoading.value, isFalse);
    expect(chat.messages.last.content, contains('Cancelled.'));
    expect(local.sources, [toolCompletionSource]);
  });

  test('a plain reply is shown without forcing a tool call', () async {
    cloud.answer = 'مرحبًا! كيف يمكنني مساعدتك؟';
    chat.textController.text = 'مرحبًا';
    await chat.sendMessage();
    expect(chat.messages.last.content, cloud.answer);
    expect(cloud.calls, 1);
    expect(agent.imageCall, isNull);
    expect(agent.narration, isNull);
  });

  test('only a model tool call sends an attachment to the image editor',
      () async {
    cloud.replies.addAll([
      '<tool_call>{"name":"edit_image","arguments":{"prompt":"Add a beach"}}</tool_call>',
      'Here is the edited image.',
    ]);
    chat.selectedImageBase64.value = 'cGljdHVyZQ==';
    chat.textController.text = 'Replace the background with a beach';
    await chat.sendMessage();
    expect(agent.imageCall?.name, 'edit_image');
    expect(agent.imageCall?.arguments['attachedImage'], 'cGljdHVyZQ==');
    expect(chat.messages.last.content, contains('nmfile:edited.jpg'));
  });

  test('a model-directed narration returns playable media', () async {
    cloud.replies.addAll([
      '<tool_call>{"name":"text_to_speech","arguments":{"text":"Playing sports builds fitness."}}</tool_call>',
      'I created a recording.',
    ]);
    chat.textController.text = 'Write a paragraph and read it aloud';
    await chat.sendMessage();
    expect(
        agent.narration?.arguments['text'], 'Playing sports builds fitness.');
    expect(chat.messages.last.content, contains('nmfile:research.wav'));
  });

  test('local Chat saves the result of a semantically selected image tool',
      () async {
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    await hive.setSetting('auto_title', false);
    local.isModelLoaded.value = true;
    local.visualDecision = 'artwork';
    const request = 'A vintage spaceport at sunrise on a postcard, please.';

    chat.textController.text = request;
    await chat.sendMessage();

    expect(local.sources, List.filled(2, InferenceService.toolPlanSource));
    expect(agent.imageCall?.name, 'generate_image');
    expect(agent.imageCall?.arguments['prompt'], request);
    expect(chat.messages.last.content, contains('nmfile:generated.jpg'));
  });

  test('a text decision does not send the sample to Pollinations', () async {
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    await hive.setSetting('auto_title', false);
    local.isModelLoaded.value = true;
    local.visualDecision = 'text';
    local.answer = 'A brief explanation.';

    chat.textController.text = 'Explain how a flying car would work.';
    await chat.sendMessage();

    expect(local.sources, [InferenceService.toolPlanSource, 'chat-tools']);
    expect(agent.imageCall, isNull);
    expect(chat.messages.last.content, local.answer);
  });

  test('a blocked image tool is excluded from semantic planning', () async {
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    await hive.setSetting('auto_title', false);
    await agent.setPolicy('built-in', 'generate_image', 'block');
    local.isModelLoaded.value = true;
    local.visualDecision = 'artwork';
    local.answer = 'An ordinary reply.';

    chat.textController.text = 'A vintage spaceport at sunrise on a postcard.';
    await chat.sendMessage();

    expect(local.sources, [InferenceService.toolPlanSource, 'chat-tools']);
    expect(agent.imageCall, isNull);
  });

  test('a model-directed calculation uses the literal formula and tool result',
      () async {
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    await hive.setSetting('auto_title', false);
    local.isModelLoaded.value = true;
    local.visualDecision = 'calc';
    local.calculatorOptions = '8';
    chat.textController.text =
        r'Calculate \frac{(84729\times93617)+\sqrt{987654321}}{137.29^2+17.83} to 8 decimal places.';

    await chat.sendMessage();

    expect(local.sources, List.filled(2, InferenceService.toolPlanSource));
    expect(local.lastPrompt, 'Calculate to 8 decimal places.');
    expect(chat.messages.last.content, contains('420436.17803423'));
    expect(chat.messages.last.content, contains('"n":"calculator"'));
  });

  test('a written prompt request can reject an initial image suggestion',
      () async {
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    await hive.setSetting('auto_title', false);
    local.isModelLoaded.value = true;
    local.visualDecision = 'artwork';
    local.decisions[visualFollowUpInstructions] = 'text';
    local.decisions[visualConfirmationInstructions] = 'text';
    local.answer = 'A written prompt.';
    chat.textController.text = 'Write a prompt I can give a painter.';

    await chat.sendMessage();

    expect(agent.imageCall, isNull);
    expect(chat.messages.last.content, local.answer);
  });

  test('a second send during attachment import cannot duplicate the request',
      () async {
    attachDocument();
    final first = chat.sendMessage();
    await chat.sendMessage();
    expect(agent.imports, 1);
    agent.imported.complete('notes.txt');
    await first;
    expect(cloud.calls, 1);
    expect(chat.messages.map((m) => m.role), ['user', 'assistant']);
    expect(hive.getMessagesForChat(chat.currentSessionId.value), hasLength(2));
  });

  test('a new draft typed during attachment import is preserved', () async {
    attachDocument();
    final first = chat.sendMessage();
    chat.textController.text = 'The next message';
    agent.imported.complete('notes.txt');
    await first;
    expect(chat.messages.first.visibleUserText, 'Read this');
    expect(chat.textController.text, 'The next message');
  });

  test('switching chats during attachment import discards the stale send',
      () async {
    attachDocument();
    final first = chat.sendMessage();
    final original = chat.currentSessionId.value;
    chat.createNewChat();
    agent.imported.complete('notes.txt');
    await first;
    expect(chat.currentSessionId.value, isNot(original));
    expect(chat.messages, isEmpty);
    expect(hive.getMessagesForChat(original), isEmpty);
    expect(cloud.calls, 0);
  });

  test('editing and regenerating preserve the attached document and draft',
      () async {
    final session = ChatSession(id: 'session', title: 'My custom title');
    final original = ChatMessage(
      id: 'message',
      chatId: session.id,
      role: 'user',
      content: 'Read this\n\nAttached file: notes.txt\nDocument contents',
      fileName: 'notes.txt',
      fileContent: 'Document contents',
      fileType: 'text',
    );
    await hive.saveSession(session.id, session.toMap());
    await hive.saveMessage(original.id, original.toMap());
    chat.loadSessions();
    chat.openChat(session.id);
    chat.textController.text = 'Draft I am still writing';
    await chat.resendLast('Summarize this', messageId: original.id);
    await chat.regenerate();

    expect(chat.currentSession?.title, 'My custom title');
    expect(chat.textController.text, 'Draft I am still writing');
    expect(chat.messages.first.id, original.id);
    expect(chat.messages.first.fileName, 'notes.txt');
    expect(chat.messages.first.content,
        startsWith('Summarize this\n\nAttached file'));
    expect(cloud.lastInput, contains('Document contents'));
    expect(cloud.calls, 2);
    expect(hive.getMessagesForChat(session.id), hasLength(2));
  });

  test('an HTML attachment is read without repeating it in the next prompt',
      () async {
    final html = File('${dir.path}/platformer_quest.html');
    await html.writeAsString(
        '<title>Platformer Quest</title><canvas id="game"></canvas>');
    chat.selectedFileName.value = 'platformer_quest.html';
    chat.selectedFilePath.value = html.path;
    chat.selectedFileType.value = 'file'; // Matches older saved attachments.
    chat.textController.text = 'Summarize this file';
    final first = chat.sendMessage();
    agent.imported.complete('platformer_quest.html');
    await first;
    expect(cloud.lastInput, contains('<canvas id="game">'));
    chat.textController.text = 'Please read the file and summarize it';
    await chat.sendMessage();
    expect(cloud.lastInput, isNot(contains('<title>Platformer Quest</title>')));
    expect(cloud.lastInput, contains('Please read the file and summarize it'));
  });

  test('an unreadable text attachment stops before inference', () async {
    chat.selectedFileName.value = 'missing.html';
    chat.selectedFileType.value = 'file';
    chat.textController.text = 'Summarize this file';
    await chat.sendMessage();
    expect(cloud.calls, 0);
    expect(
        chat.messages.last.content, contains('couldn’t read "missing.html"'));
  });

  test('model-directed research refines a query and surfaces both sources',
      () async {
    final web = Get.put<WebSearchService>(_TestWeb()) as _TestWeb;
    cloud.replies.addAll([
      '<tool_call>{"name":"web_search","arguments":{"query":"coding model benchmark"}}</tool_call>',
      '<tool_call>{"name":"web_search","arguments":{"query":"coding model benchmark methodology"},"missing":"benchmark methodology"}</tool_call>',
      'The tests cover different workloads [1] and [2].',
    ]);
    chat.textController.text = 'Which model is strongest at coding today?';
    await chat.sendMessage();

    expect(web.queries,
        ['coding model benchmark', 'coding model benchmark methodology']);
    expect(cloud.lastInput, contains('benchmark methodology'));
    expect(
        chat.messages.last.content, contains('https://example.com/benchmark'));
    expect(chat.messages.last.content,
        contains('https://example.com/methodology'));
    expect(chat.messages.last.content, contains('Sources:'));
    expect(cloud.calls, 3);
    final saved = hive
        .getMessagesForChat(chat.currentSessionId.value)
        .map(ChatMessage.fromMap)
        .firstWhere((message) => message.role == 'assistant');
    expect(saved.toolSearches.map((record) => record['query']), web.queries);
    expect(saved.toolSearches.first['results'].single['snippet'], 'First test');
  });

  test('a send waits for the pending context reset after switching', () async {
    local.isModelLoaded.value = true;
    local.pendingReset = Completer<void>();
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    await hive.setSetting('auto_title', false);
    agent.mode.value = ChatToolMode.off;
    chat.createNewChat();
    chat.textController.text = 'After switching';
    final send = chat.sendMessage();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(local.resets, 1);
    expect(local.calls, 0);
    local.answer = 'Reply from the new chat';
    local.pendingReset!.complete();
    await send;
    expect(local.calls, 1);
    expect(chat.messages.last.content, local.answer);
  });

  test('voice messages and attachments remain in the originating chat',
      () async {
    chat.createNewChat();
    final voiceChat = chat.currentSessionId.value;
    await chat.saveVoiceMessage(
      voiceChat,
      'user',
      'Read this\n\nAttached file: notes.txt',
      fileName: 'notes.txt',
    );
    chat.createNewChat();
    await chat.saveVoiceMessage(voiceChat, 'assistant', 'Summary');
    expect(chat.messages, isEmpty);

    chat.openChat(voiceChat);
    expect(chat.messages.map((m) => m.role), ['user', 'assistant']);
    expect(chat.messages.first.visibleUserText, 'Read this');
    expect(chat.messages.first.fileName, 'notes.txt');
    expect(chat.messages.last.content, 'Summary');
  });

  test('project workspaces isolate files and restore snapshots', () async {
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(dir.path);
    addTearDown(() => PathProviderPlatform.instance = original);

    Future<void> write(String project, String text) => agent.inProject(
          project,
          () async {
            final file = await agent.newWorkspaceFile('notes.txt');
            await file.writeAsString(text);
          },
        );
    await write('Project A', 'first draft');
    await agent.inProject(
        'Project A', () => agent.deleteWorkspaceFile('notes.txt'));
    await write('Project A', 'second draft');
    await write('Project B', 'other project');
    await agent.inProject('Project A', () async {
      final versions = await agent.workspaceVersions('notes.txt');
      expect(versions, hasLength(1));
      expect(await agent.restoreWorkspaceVersion('notes.txt', versions.single),
          isTrue);
      expect(
          await File('${(await agent.filesDir()).path}/notes.txt')
              .readAsString(),
          'first draft');
    });
    await agent.inProject('Project B', () async {
      expect(
          await File('${(await agent.filesDir()).path}/notes.txt')
              .readAsString(),
          'other project');
      expect(await agent.workspaceVersions('notes.txt'), isEmpty);
    });
  });

  test('a damaged saved image leaves the rest of the message readable', () {
    final message = ChatMessage(
      id: 'broken',
      chatId: 'session',
      role: 'assistant',
      content: 'Saved reply',
      imageBase64: 'invalid!',
    );
    expect(message.decodedImageBytes, isNull);
    expect(message.content, 'Saved reply');
  });
}

class _WorkspaceAgent extends ChatToolService {
  final imported = Completer<String>();
  int imports = 0;
  ParsedToolCall? imageCall;
  ParsedToolCall? narration;

  @override
  Future<String> executeTool(ParsedToolCall call, ToolConfirm confirm) async {
    if (call.name == 'generate_image') {
      imageCall = call;
      return 'Generated online with Pollinations.\n\n![Generated](nmfile:generated.jpg)';
    }
    if (call.name == 'edit_image') {
      imageCall = call;
      return 'Edited online with Pollinations. ![Edited](nmfile:edited.jpg)';
    }
    if (call.name == 'text_to_speech') {
      narration = call;
      return 'Saved research.wav. Show it with [Audio](nmfile:research.wav).';
    }
    return super.executeTool(call, confirm);
  }

  @override
  Future<String> importToWorkspace(String sourcePath, String name) {
    imports++;
    return imported.future;
  }
}

class _TestNarrationInference extends InferenceService {
  String answer = '';
  String visualDecision = 'text';
  String calculatorOptions = 'none';
  final decisions = <String, String>{};
  final toolCompletions = <String>[];
  final sources = <String>[];
  Completer<void>? pendingReset;
  int resets = 0;
  @override
  Future<void> resetConversation() async {
    resets++;
    await pendingReset?.future;
  }

  String? lastPrompt;
  String? lastSystem;
  int calls = 0;

  @override
  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    void Function(String token)? onToken,
  }) async {
    calls++;
    sources.add(source);
    lastPrompt = prompt;
    lastSystem = systemPrompt;
    if (source == toolCompletionSource) return toolCompletions.removeAt(0);
    if (source == InferenceService.toolPlanSource) {
      return decisions[systemPrompt] ??
          (systemPrompt == calculatorOptionsInstructions
              ? calculatorOptions
              : visualDecision);
    }
    onToken?.call(answer);
    return answer;
  }
}

class _TestCloud extends CloudService {
  int calls = 0;
  String? lastInput;
  String answer = 'Reply';
  final replies = <String>[];

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
    void Function(String token)? onToken,
  }) async {
    calls++;
    lastInput = messages.last['content'];
    if (replies.isNotEmpty) return replies.removeAt(0);
    return answer;
  }
}

class _TestWeb extends WebSearchService {
  final queries = <String>[];

  @override
  Future<SearchReport> searchReport(String query,
      {int max = 4, String? freshness, Future<void>? abort}) async {
    queries.add(query);
    final isFollowUp = query.endsWith('methodology');
    return SearchReport([
      if (isFollowUp)
        const WebResult(
            'Methodology', 'https://example.com/methodology', 'Second test')
      else
        const WebResult(
            'Benchmark', 'https://example.com/benchmark', 'First test'),
    ], {}, 1);
  }
}

class _UnusedPlayer implements AudioPlayer {
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WhisperFixture extends VoiceModelStore {
  _WhisperFixture(this.directory);

  final String directory;

  @override
  Future<void> scan() async {
    installed.add('whisper-tiny');
  }

  @override
  Future<String> dirFor(VoiceModelInfo model) async => directory;
}

class _TestTranscription extends VoiceService {
  _TestTranscription() : super(player: _UnusedPlayer());

  String? path;

  @override
  Future<String> transcribeFile(String path,
      {String language = '',
      String modelId = '',
      Future<void>? cancelled}) async {
    this.path = path;
    return 'A recorded note.';
  }
}

class _PendingSearch extends WebSearchService {
  final started = Completer<void>();
  final aborted = Completer<void>();

  @override
  Future<SearchReport> searchReport(String query,
      {int max = 4, String? freshness, Future<void>? abort}) async {
    started.complete();
    await abort;
    aborted.complete();
    return const SearchReport([], {}, 0);
  }
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
