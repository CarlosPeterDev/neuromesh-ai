/// Runtime/template evidence, independent of the model's author or filename.
enum ReasoningSupport {
  unknown,
  none,
  toggleable,
  alwaysOn;

  static ReasoningSupport fromTemplates(Iterable<String> markers) {
    final values = markers.toSet();
    if (values.contains('metadata-thinking-supported')) return toggleable;
    if (values.contains('metadata-reasoning-always-on')) return alwaysOn;
    return values.contains('metadata-chat-supported') ? none : unknown;
  }

  String get explanation => switch (this) {
        toggleable => 'This template supports turning reasoning on or off.',
        alwaysOn => 'This model uses reasoning without a supported off switch.',
        none => 'This model template does not advertise a reasoning mode.',
        unknown =>
          'This runtime has not detected a controllable reasoning mode.',
      };
}
