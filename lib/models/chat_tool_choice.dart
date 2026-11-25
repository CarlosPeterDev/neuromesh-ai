/// The user's explicit choice for a single Chat turn.
enum ChatToolChoice {
  auto('Auto', '', ''),
  search('Search', 'web_search', 'Enter a search query'),
  calculator('Calc', 'calculator', 'Enter an arithmetic expression'),
  image('Image', 'generate_image', 'Describe the image'),
  speak('Speak', 'text_to_speech', 'Enter the words to speak'),
  transcribe(
      'Transcribe', 'transcribe_attachment', 'Attach an audio file with +');

  const ChatToolChoice(this.label, this.tool, this.hint);

  final String label;
  final String tool;
  final String hint;

  bool get isDirect => this != auto;

  static ChatToolChoice fromName(Object? name) =>
      values.firstWhere((choice) => choice.name == name, orElse: () => auto);
}
