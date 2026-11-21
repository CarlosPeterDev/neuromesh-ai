/// Template families whose normal reasoning can be switched on and off.
enum ThinkingMode {
  unsupported,
  qwen,
  gemma;

  static ThinkingMode forModel(String name) {
    if (RegExp(r'qwen[-_ ]?3(?![0-9])', caseSensitive: false).hasMatch(name)) {
      return qwen;
    }
    if (RegExp(r'gemma[-_ ]?4(?![0-9])', caseSensitive: false).hasMatch(name)) {
      return gemma;
    }
    return unsupported;
  }

  String? androidTemplate(bool thinking) => switch (this) {
        qwen => thinking ? null : 'qwen3-direct',
        gemma => thinking ? 'gemma4-thinking' : 'gemma4',
        unsupported => null,
      };
}
