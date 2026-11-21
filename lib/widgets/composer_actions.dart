import 'package:flutter/material.dart';

/// Separate dictation and voice-conversation controls. Keeping this stateless
/// leaves text/focus and persisted thinking state with their controllers.
class ComposerActions extends StatelessWidget {
  const ComposerActions(
      {super.key,
      required this.thinking,
      required this.hasContent,
      required this.loading,
      required this.listening,
      required this.onThink,
      required this.onMicrophone,
      required this.onVoice,
      required this.onSend,
      required this.onStop,
      this.leading = const []});
  final bool thinking, hasContent, loading, listening;
  final VoidCallback onThink, onMicrophone, onVoice, onSend, onStop;
  final List<Widget> leading;
  @override
  Widget build(BuildContext context) => Row(children: [
        ...leading,
        Semantics(
            toggled: thinking,
            button: true,
            label: 'Think',
            child: TextButton.icon(
              key: const ValueKey('think'),
              style: TextButton.styleFrom(
                  backgroundColor:
                      thinking ? const Color(0xFF147DFF) : Colors.transparent,
                  foregroundColor:
                      thinking ? Colors.white : Theme.of(context).hintColor,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(64, 40)),
              onPressed: loading ? null : onThink,
              icon: const Icon(Icons.psychology_outlined, size: 18),
              label: const Text('Think'),
            )),
        const Spacer(),
        IconButton(
            key: const ValueKey('microphone'),
            tooltip: listening ? 'Stop dictation' : 'Microphone',
            onPressed: loading ? null : onMicrophone,
            color: listening ? Colors.red : null,
            icon: Icon(listening ? Icons.mic : Icons.mic_none_rounded)),
        IconButton.filled(
            key: ValueKey(loading
                ? 'stop'
                : hasContent
                    ? 'send'
                    : 'voice-mode'),
            tooltip: loading
                ? 'Stop'
                : hasContent
                    ? 'Send'
                    : 'Voice Mode',
            onPressed: loading
                ? onStop
                : hasContent
                    ? onSend
                    : onVoice,
            icon: Icon(loading
                ? Icons.stop_rounded
                : hasContent
                    ? Icons.arrow_upward_rounded
                    : Icons.graphic_eq_rounded)),
      ]);
}
