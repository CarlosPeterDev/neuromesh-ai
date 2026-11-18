/// Distinguishes work requests from information that can carry across chats.
final _taskRequest = RegExp(
  r'^\s*(?:please\s+|(?:can|could|would) you\s+|to\s+)?'
  r'(?:add|build|create|delete|deploy|download|edit|fix|install|make|open|perform|publish|remove|run|schedule|send|set up|solve|test|update|upload|write)\b'
  r'|^\s*(?:اعمل|أنشئ|انشئ|ابني|صلح|عدّل|عدل|اكتب|ابعث|ابعت|حمّل|حمل|نزّل|نزل|شغّل|شغل|انشر|امسح|نفذ)(?:\s|$)'
  r'|^\s*(?:the\s+)?(?:user|i|they|he|she)\s+(?:has\s+)?(?:asked|requested|instructed)\b'
  r'|^\s*(?:the\s+)?user\s+(?:wants|needs)\s+(?:the\s+)?(?:assistant|agent|ai)\s+to\b'
  r'|^\s*(?:المستخدم|اليوزر)\s+(?:طلب|عايزك|عاوزك)(?:\s|$)'
  r'|^\s*(?:task|to-?do|action item)\s*:',
  caseSensitive: false,
);

bool isMemoryTask(String text) => _taskRequest.hasMatch(text);
