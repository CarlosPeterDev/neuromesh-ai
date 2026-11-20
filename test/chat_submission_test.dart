import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
// Platform mock for the app's existing path_provider dependency.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:neuromesh_ai/services/agent_tools.dart';
import 'package:neuromesh_ai/controllers/chat_controller.dart';
import 'package:neuromesh_ai/controllers/settings_controller.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/models/chat_message.dart';
import 'package:neuromesh_ai/models/chat_session.dart';
import 'package:neuromesh_ai/services/agent_service.dart';
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
    agent = Get.put<AgentService>(_WorkspaceAgent()) as _WorkspaceAgent;
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

  test('explicit image generation works without an active chat model',
      () async {
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    chat.textController.text = 'Create an image of a fox';
    await chat.sendMessage();
    expect(agent.imageCall?.arguments['prompt'], 'Create an image of a fox');
    expect(agent.directImageRequest, isTrue);
    expect(chat.messages.last.content, contains('Generated online'));
    expect(cloud.calls, 0);
  });

  test('local writing goes directly to TTS without creating a text file',
      () async {
    await hive.setSetting(AppConstants.keyInferenceMode, 'local');
    agent.mode.value = AgentChatMode.always;
    local.answer = 'Playing sports builds fitness and teaches teamwork.';
    for (final request in [
      'Write a paragraph about the importance of sports then use the tts tool to convert it to audio file',
      'A paragraph you write about sports and be in audio file',
    ]) {
      chat.textController.text = request;
      await chat.sendMessage();
      expect(local.lastPrompt, contains('Return only the finished text'));
      expect(local.lastPrompt, isNot(contains('audio file')));
      expect(local.lastSystem, isNot(contains('<tool_call>')));
      expect(agent.narration?.arguments['text'], local.answer);
      expect(chat.messages.last.content, contains('nmfile:research.wav'));
      expect(chat.messages.last.content, isNot(contains('notes.txt')));
    }
    expect(local.calls, 2);
    expect(cloud.calls, 0);
  });

  test('web research writes a paragraph, then narrates exactly that paragraph',
      () async {
    Get.put<WebSearchService>(_TestWeb());
    cloud.answer = 'Sport improves fitness and brings communities together [1].';
    chat.textController.text =
        'OK now search for the importance of sport in modern society '
        'then write a paragraph then create an audio file that reads it';
    await chat.sendMessage();
    expect(cloud.lastInput, contains('Write one plain-language paragraph'));
    expect(agent.narration?.arguments['text'],
        'Sport improves fitness and brings communities together.');
    expect(chat.messages.last.content, contains('nmfile:research.wav'));
    expect(chat.messages.last.content, contains('Sources:'));
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

  test('an HTML attachment and its follow-up receive the actual file text',
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
    expect(cloud.lastInput, contains('<title>Platformer Quest</title>'));
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

  test('an explicit search retry reuses the original topic and refreshes sources', () async {
    final web = Get.put<WebSearchService>(_TestWeb()) as _TestWeb;
    const first = 'What is the strongest AI model today for coding?';
    chat.textController.text = first;
    await chat.sendMessage();
    expect(cloud.calls, 1);
    expect(cloud.lastInput, contains('Published benchmark results'));
    chat.textController.text = 'Please search because this is old';
    await chat.sendMessage();

    expect(web.previous, first);
    expect(web.refreshed, isTrue);
    expect(cloud.lastInput, contains('Research question:'));
    expect(cloud.lastInput, contains('Published benchmark results'));
    expect(chat.messages.last.content, contains('https://example.com/benchmark'));
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

    Future<String> write(String project, String text) => agent.inProject(
      project,
      () => agent.executeTool(
        ParsedToolCall('write_file', {'name': 'notes.txt', 'content': text}, ''),
        (_, __, ___) async => true,
      ),
    );
    expect(await write('Project A', 'first draft'), startsWith('Wrote'));
    expect(await write('Project A', 'second draft'), startsWith('Wrote'));
    expect(await write('Project B', 'other project'), startsWith('Wrote'));
    await agent.inProject('Project A', () async {
      final versions = await agent.workspaceVersions('notes.txt');
      expect(versions, hasLength(1));
      expect(await agent.restoreWorkspaceVersion('notes.txt', versions.single), isTrue);
      expect(await File('${(await agent.filesDir()).path}/notes.txt').readAsString(), 'first draft');
    });
    await agent.inProject('Project B', () async {
      expect(await File('${(await agent.filesDir()).path}/notes.txt').readAsString(), 'other project');
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

class _WorkspaceAgent extends AgentService {
  final imported = Completer<String>();
  int imports = 0;
  ParsedToolCall? imageCall;
  ParsedToolCall? narration;
  bool directImageRequest = false;

  @override
  Future<String> executeTool(ParsedToolCall call, ToolConfirm confirm,
      {bool userRequestedOnlineImage = false}) async {
    if (call.name == 'generate_image') {
      imageCall = call;
      directImageRequest = userRequestedOnlineImage;
      return 'Generated online with Pollinations (Sana).';
    }
    if (call.name == 'text_to_speech') {
      narration = call;
      return 'Saved research.wav. Show it with [Audio](nmfile:research.wav).';
    }
    return super.executeTool(call, confirm,
        userRequestedOnlineImage: userRequestedOnlineImage);
  }

  @override
  Future<String> importToWorkspace(String sourcePath, String name) {
    imports++;
    return imported.future;
  }
}

class _TestNarrationInference extends InferenceService {
  String answer = '';
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
    lastPrompt = prompt;
    lastSystem = systemPrompt;
    onToken?.call(answer);
    return answer;
  }
}

class _TestCloud extends CloudService {
  int calls = 0;
  String? lastInput;
  String answer = 'Reply';

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
    return answer;
  }
}


class _TestWeb extends WebSearchService {
  String? previous;
  bool refreshed = false;

  @override
  Future<WebContext?> buildContext(String question, {String? previous, bool refresh = false}) async {
    this.previous = previous;
    refreshed = refresh;
    return WebContext('Published benchmark results', const [
      WebResult('Coding benchmark', 'https://example.com/benchmark', 'Model comparison')
    ]);
  }
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
