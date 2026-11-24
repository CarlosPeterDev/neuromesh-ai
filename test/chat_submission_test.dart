import 'dart:async';
import 'dart:io';

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
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/cloud_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/image_generation_notification_service.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/services/local_image_service.dart';
import 'package:neuromesh_ai/services/web_search_service.dart';
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
    Get.put(ImageGenerationNotificationService());
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
    local.answer = 'Here it is.';
    const request = 'A vintage spaceport at sunrise on a postcard, please.';

    chat.textController.text = request;
    await chat.sendMessage();

    expect(local.sources, [InferenceService.visualPlanSource, 'chat-tools']);
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

    expect(local.sources, [InferenceService.visualPlanSource, 'chat-tools']);
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

    expect(local.sources, ['chat-tools']);
    expect(agent.imageCall, isNull);
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
    if (source == InferenceService.visualPlanSource) return visualDecision;
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

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
