import 'chat_math.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../controllers/chat_controller.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/chat_message.dart';
import '../utils/text_direction.dart';
import '../utils/thought_parser.dart';
import 'agent_steps.dart';
import 'attachment_preview.dart';
import 'image_viewer.dart';
import 'thought_disclosure.dart';
import '../core/haptics.dart';
import '../services/agent_service.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Premium Generated Image Card (Assistant only)
    if (!isUser && message.decodedImageBytes != null) {
      return _buildGeneratedImageCard(context, isDark);
    }

    if (isUser) return _buildUser(context, isDark, message.visibleUserText);

    final thoughtParts = splitThoughtTags(_cleanAssistantText(message.content));
    final answerContent = thoughtParts.answer.trim();
    return _buildAssistant(context, isDark, thoughtParts, answerContent);
  }

  /// Splits the trailing "Sources:" list the web search appends into
  /// (answer text, [(title, url)]) so the links can be shown as tappable chips.
  static (String, List<(String, String)>) splitSources(String content) {
    final i = content.lastIndexOf('\n\nSources:\n');
    if (i < 0) return (content, const []);
    final links = <(String, String)>[];
    for (final m
        in RegExp(r'^\d+\. \[(.*)\]\((https?://[^)\s]+)\)\s*$', multiLine: true)
            .allMatches(content.substring(i))) {
      links.add((m.group(1)!, m.group(2)!));
    }
    if (links.isEmpty) return (content, const []);
    return (content.substring(0, i).trimRight(), links);
  }

  static Future<void> openLink(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    var ok = false;
    if (uri != null &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'http' || uri.scheme == 'https')) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  bool _isLastMessage() {
    if (!Get.isRegistered<ChatController>()) return false;
    final c = Get.find<ChatController>();
    return c.messages.isNotEmpty && c.messages.last.id == message.id;
  }

  bool _isLastUserMessage() {
    if (!Get.isRegistered<ChatController>()) return false;
    final c = Get.find<ChatController>();
    final i = c.messages.lastIndexWhere((m) => m.role == 'user');
    return i >= 0 && c.messages[i].id == message.id;
  }

  Future<void> _editAndResend(BuildContext context, String text) async {
    var edited = text;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextFormField(
          initialValue: text,
          onChanged: (value) => edited = value,
          maxLines: 6,
          minLines: 1,
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, edited),
              child: const Text('Resend')),
        ],
      ),
    );
    if (context.mounted && result != null && result.trim().isNotEmpty) {
      await Get.find<ChatController>()
          .resendLast(result, messageId: message.id);
    }
  }

  // ── User: compact neutral bubble on the right ──
  Widget _buildUser(BuildContext context, bool isDark, String text) {
    final maxW = MediaQuery.of(context).size.width * 0.8;
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 14, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (message.decodedImageBytes != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: () => ImageViewer.show(context, message.imageBase64!),
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: maxW * 0.7, maxHeight: 260),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.memory(
                    message.decodedImageBytes!,
                    gaplessPlayback: true,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 160,
                      height: 120,
                      color: _userFill(isDark),
                      child: const Center(
                          child: Icon(Icons.broken_image_rounded, size: 24)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (message.fileName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: AttachmentPreview(
                fileName: message.fileName!,
                fileType: message.fileType,
                fileSize: message.fileSize,
                imageBase64: message.imageBase64,
                imagePath: message.imagePath,
                compact: true,
              ),
            ),
          ),
        if (text.trim().isNotEmpty && _isLastUserMessage())
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Edit and resend',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              color: Theme.of(context).hintColor,
              icon: const Icon(Icons.edit_outlined),
              onPressed: Get.find<ChatController>().isLoading.value
                  ? null
                  : () => _editAndResend(context, text),
            ),
          ),
        if (text.trim().isNotEmpty)
          Container(
            constraints: BoxConstraints(maxWidth: maxW),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _userFill(isDark),
              borderRadius: BorderRadius.circular(20),
            ),
            child: SelectableText(
              text,
              textDirection: detectDirection(text),
              style: GoogleFonts.inter(
                fontSize: 15.5,
                height: 1.45,
                letterSpacing: -0.1,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
      ]),
    );
  }

  // ── Assistant: full-width text, no bubble, quiet actions underneath ──
  Widget _buildAssistant(BuildContext context, bool isDark,
      ThoughtParts thoughtParts, String fullAnswer) {
    final muted = Theme.of(context).hintColor;
    final (steps, withoutSteps) = splitSteps(fullAnswer);
    final (answerContent, sources) = splitSources(withoutSteps);
    final meta = <String>[
      if (message.tokensPerSec != null && message.tokensPerSec! > 0)
        '${message.tokensPerSec!.toStringAsFixed(1)} chunks/s',
      if (message.imageGenDurationMs != null && message.imageGenDurationMs! > 0)
        _formatGenTime(message.imageGenDurationMs!),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (thoughtParts.hasThought)
          ThoughtDisclosure(
            thought: thoughtParts.thought,
            durationSeconds: message.thoughtDurationSeconds,
            styleSheet: _thoughtMarkdownStyle(context),
          ),
        if (answerContent.isNotEmpty)
          Directionality(
            textDirection: detectDirection(answerContent),
            child: SizedBox(
              width: double.infinity,
              child: AssistantMarkdown(
                text: answerContent,
                workspaceProject: message.workspaceProject,
                showWorkspaceImages: true,
              ),
            ),
          ),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          ChatSourcesList(sources: sources, muted: muted),
        ],
        if (steps.isNotEmpty) ...[
          if (answerContent.isNotEmpty) const SizedBox(height: 10),
          AgentStepsView(steps: steps, messageId: message.id),
        ],
        if (message.fileName != null) ...[
          const SizedBox(height: 10),
          AttachmentPreview(
            fileName: message.fileName!,
            fileType: message.fileType,
            fileSize: message.fileSize,
            imageBase64: message.imageBase64,
            imagePath: message.imagePath,
            compact: true,
          ),
        ],
        const SizedBox(height: 4),
        // Nudge left so the copy glyph lines up with the text edge.
        Transform.translate(
            offset: const Offset(-6, 0),
            child: Row(children: [
              if (answerContent.isNotEmpty)
                _CopyButton(text: answerContent, color: muted),
              if (_isLastMessage())
                IconButton(
                  tooltip: 'Regenerate',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: muted,
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: Get.find<ChatController>().isLoading.value
                      ? null
                      : () => Get.find<ChatController>().regenerate(),
                ),
              if (meta.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(meta.join(' · '),
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: muted.withValues(alpha: 0.8),
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ])),
      ]),
    );
  }

  static Color _userFill(bool isDark) =>
      isDark ? const Color(0xFF1E1E21) : const Color(0xFFF0F0F2);

  /// Answer text style — shared with the streaming reply so text doesn't
  /// shift when generation finishes.
  static MarkdownStyleSheet answerStyle(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).hintColor;
    final base = GoogleFonts.inter(
        fontSize: 15.5, color: color, height: 1.6, letterSpacing: -0.1);
    final codeBlockBg =
        isDark ? const Color(0xFF161618) : const Color(0xFFF3F3F5);

    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w600),
      em: base.copyWith(fontStyle: FontStyle.italic),
      listBullet: base,
      code: GoogleFonts.firaCode(
        fontSize: 13,
        color: color,
        backgroundColor: codeBlockBg,
      ),
      codeblockDecoration: BoxDecoration(
        color: codeBlockBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.06),
            width: 0.5),
      ),
      h1: base.copyWith(fontSize: 22, fontWeight: FontWeight.w700, height: 1.3),
      h2: base.copyWith(fontSize: 19, fontWeight: FontWeight.w700, height: 1.3),
      h3: base.copyWith(
          fontSize: 17, fontWeight: FontWeight.w600, height: 1.35),
      pPadding: const EdgeInsets.only(bottom: 2),
      codeblockPadding: const EdgeInsets.all(14),
      blockquote: base.copyWith(color: muted),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.15)
                : Colors.black.withValues(alpha: 0.15),
            width: 3,
          ),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
    );
  }

  MarkdownStyleSheet _thoughtMarkdownStyle(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    final base = GoogleFonts.inter(fontSize: 13, color: muted, height: 1.4);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w600),
      em: base.copyWith(fontStyle: FontStyle.italic),
      listBullet: base,
      code: GoogleFonts.firaCode(
        fontSize: 11,
        color: muted,
        backgroundColor:
            isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
      ),
      codeblockDecoration: BoxDecoration(
        color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
        borderRadius: BorderRadius.circular(10),
      ),
    );
  }

  String _formatGenTime(int ms) {
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    return s > 0 ? '${m}m ${s}s' : '${m}m';
  }

  String _cleanAssistantText(String text) {
    return text
        .replaceAll('<|endoftext|>', '')
        .replaceAll('<|im_end|>', '')
        .replaceAll('<|end|>', '')
        .trim();
  }

  Widget _buildGeneratedImageCard(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: () => ImageViewer.show(context, message.imageBase64!),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
                width: 0.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(19),
              child: Stack(
                children: [
                  Image.memory(
                    message.decodedImageBytes!,
                    width: double.infinity,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => Container(
                      height: 150,
                      color: isDark
                          ? const Color(0xFF1C1C1E)
                          : const Color(0xFFF2F2F7),
                      child: const Center(
                          child: Icon(Icons.broken_image_rounded, size: 28)),
                    ),
                  ),
                  // Time elapsed overlay
                  if (message.imageGenDurationMs != null &&
                      message.imageGenDurationMs! > 0)
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.2),
                              width: 0.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.timer_outlined,
                                size: 10, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              _formatGenTime(message.imageGenDurationMs!),
                              style: GoogleFonts.inter(
                                  fontSize: 10,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  final String text;
  final Color color;
  const _CopyButton({required this.text, required this.color});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    Haptics.lightImpact();
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Copy',
      child: InkResponse(
        onTap: _copy,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: Icon(
              _copied ? Icons.check_rounded : Icons.content_copy_rounded,
              key: ValueKey(_copied),
              size: 16,
              color: widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Sources" row that stays collapsed (showing the first site names) until
/// tapped, then lists every source as a tappable chip.
/// Displays clickable Markdown links while keeping the full answer selectable.
class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown({
    super.key,
    required this.text,
    this.workspaceProject,
    this.showWorkspaceImages = false,
  });

  final String text;
  final String? workspaceProject;
  final bool showWorkspaceImages;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: MarkdownBody(
        data: text,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        inlineSyntaxes: chatMathSyntax(),
        blockSyntaxes: const [ChatMathBlock()],
        builders: {...chatMathBuilders(), 'pre': _CodeBlockBuilder(context)},
        styleSheet: ChatBubble.answerStyle(context),
        sizedImageBuilder: (cfg) =>
            showWorkspaceImages && cfg.uri.toString().startsWith(nmFileScheme)
                ? agentImage(cfg.uri, cfg.alt, project: workspaceProject)
                : const SizedBox.shrink(),
        onTapLink: (_, href, __) {
          if (href == null) return;
          if (href.startsWith(nmFileScheme)) {
            Get.find<AgentService>().inProject(
              workspaceProject ?? '',
              () => openAgentFile(context, href.substring(nmFileScheme.length)),
            );
          } else {
            ChatBubble.openLink(context, href);
          }
        },
      ),
    );
  }
}

class ChatSourcesList extends StatefulWidget {
  final List<(String, String)> sources;
  final Color muted;
  const ChatSourcesList({required this.sources, required this.muted});

  @override
  State<ChatSourcesList> createState() => _SourcesListState();
}

class _SourcesListState extends State<ChatSourcesList> {
  bool _open = false;

  String _host(int i) =>
      Uri.tryParse(widget.sources[i].$2)?.host.replaceFirst('www.', '') ??
      widget.sources[i].$1;

  @override
  Widget build(BuildContext context) {
    final muted = widget.muted;
    final n = widget.sources.length;
    final preview = [for (var i = 0; i < n && i < 2; i++) _host(i)].join(', ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.link_rounded, size: 16, color: muted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _open
                    ? 'Sources ($n)'
                    : 'Sources ($n) · $preview${n > 2 ? ' …' : ''}',
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                    fontSize: 12.5, fontWeight: FontWeight.w600, color: muted),
              ),
            ),
            Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                size: 18, color: muted),
          ]),
        ),
      ),
      if (_open) ...[
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < n; i++)
            ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: CircleAvatar(
                  radius: 9,
                  backgroundColor: muted.withValues(alpha: 0.18),
                  child: Text('${i + 1}',
                      style: GoogleFonts.inter(fontSize: 10, color: muted))),
              label: Text(_host(i), style: GoogleFonts.inter(fontSize: 12)),
              tooltip: '${widget.sources[i].$1}\n${widget.sources[i].$2}',
              onPressed: () =>
                  ChatBubble.openLink(context, widget.sources[i].$2),
            ),
        ]),
      ],
    ]);
  }
}

/// Fenced code blocks get their own copy button, so a file's text can be
/// copied without copying the whole message.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  _CodeBlockBuilder(this.context);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final text = element.textContent.replaceAll(RegExp(r'\n$'), '');
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF161618) : const Color(0xFFF3F3F5);
    final muted = Theme.of(context).hintColor;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.06),
            width: 0.5),
      ),
      child: Stack(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 12, 44, 12),
          child: SelectableText(
            text,
            style: GoogleFonts.firaCode(
                fontSize: 13,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: IconButton(
            tooltip: 'Copy this block',
            visualDensity: VisualDensity.compact,
            iconSize: 17,
            color: muted,
            icon: const Icon(Icons.copy_rounded),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
                  content: Text('Copied'), duration: Duration(seconds: 1)));
            },
          ),
        ),
      ]),
    );
  }
}
