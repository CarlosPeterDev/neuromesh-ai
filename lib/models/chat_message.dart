import 'chat_tool_choice.dart';
import 'dart:convert';
import 'dart:typed_data';

class ChatMessage {
  final String id;
  final String chatId;
  final String role; // 'user', 'assistant', 'system', 'cmd'
  final String content;
  final String? imageBase64; // For multimodal
  final String? imagePath;
  final String? workspaceProject;
  final String? workspaceAttachment;
  final String? fileName;
  final String? fileContent;
  final String? filePath;
  final String? fileType;
  final int? fileSize;
  final String? cmdOutput; // Result of CMD: execution
  final bool isCommand;
  final double? tokensPerSec;
  final int? thoughtDurationSeconds;
  final int? imageGenDurationMs; // Time taken to generate image locally
  final DateTime timestamp;
  final List<Map<String, dynamic>> toolSearches;
  final ChatToolChoice toolChoice;

  // Cache decoded bytes to prevent flickering on re-build
  Uint8List? _decodedImageBytes;
  Uint8List? get decodedImageBytes {
    if (imageBase64 == null) return null;
    try {
      return _decodedImageBytes ??= base64Decode(imageBase64!);
    } on FormatException {
      return null;
    }
  }

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    this.imageBase64,
    this.imagePath,
    this.workspaceProject,
    this.workspaceAttachment,
    this.fileName,
    this.fileContent,
    this.filePath,
    this.fileType,
    this.fileSize,
    this.cmdOutput,
    this.isCommand = false,
    this.tokensPerSec,
    this.thoughtDurationSeconds,
    this.imageGenDurationMs,
    this.toolSearches = const [],
    this.toolChoice = ChatToolChoice.auto,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  static const _attachmentSeparator = '\n\nAttached file:';

  int get _attachmentStart {
    final index = content.indexOf(_attachmentSeparator);
    return index >= 0 ? index : content.indexOf('\n\nAttached workspace file:');
  }

  String get visibleUserText {
    final start = fileName == null ? -1 : _attachmentStart;
    return start < 0 ? content : content.substring(0, start);
  }

  ChatMessage withUserText(String text) {
    final start = fileName == null ? -1 : _attachmentStart;
    return ChatMessage.fromMap({
      ...toMap(),
      'content': start < 0 ? text : '$text${content.substring(start)}',
    });
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'chatId': chatId,
        'role': role,
        'content': content,
        'imageBase64': imageBase64,
        'imagePath': imagePath,
        'workspaceProject': workspaceProject,
        if (workspaceAttachment != null)
          'workspaceAttachment': workspaceAttachment,
        'fileName': fileName,
        'fileContent': fileContent,
        'filePath': filePath,
        'fileType': fileType,
        'fileSize': fileSize,
        'cmdOutput': cmdOutput,
        'isCommand': isCommand,
        // Older backups used tokensPerSec for output chunks per second.
        if (tokensPerSec != null) 'measuredTokensPerSec': tokensPerSec,
        'thoughtDurationSeconds': thoughtDurationSeconds,
        'imageGenDurationMs': imageGenDurationMs,
        'timestamp': timestamp.toIso8601String(),
        if (toolChoice.isDirect) 'toolChoice': toolChoice.name,
        if (toolSearches.isNotEmpty) 'toolSearches': toolSearches,
      };

  factory ChatMessage.fromMap(Map<dynamic, dynamic> map) => ChatMessage(
        id: map['id'] ?? '',
        chatId: map['chatId'] ?? '',
        role: map['role'] ?? 'user',
        content: map['content'] ?? '',
        imageBase64: map['imageBase64'],
        imagePath: map['imagePath'],
        workspaceProject: map['workspaceProject'] as String?,
        workspaceAttachment: map['workspaceAttachment'] as String?,
        fileName: map['fileName'],
        fileContent: map['fileContent'],
        filePath: map['filePath'],
        fileType: map['fileType'],
        fileSize:
            map['fileSize'] != null ? (map['fileSize'] as num).toInt() : null,
        cmdOutput: map['cmdOutput'],
        isCommand: map['isCommand'] ?? false,
        tokensPerSec: (map['measuredTokensPerSec'] as num?)?.toDouble(),
        thoughtDurationSeconds: map['thoughtDurationSeconds'] != null
            ? (map['thoughtDurationSeconds'] as num).toInt()
            : null,
        imageGenDurationMs: map['imageGenDurationMs'] != null
            ? (map['imageGenDurationMs'] as num).toInt()
            : null,
        toolChoice: ChatToolChoice.fromName(map['toolChoice']),
        toolSearches: [
          for (final item
              in (map['toolSearches'] as List? ?? const []).whereType<Map>())
            Map<String, dynamic>.from(item),
        ],
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      );
}
