import 'thought_parser.dart';

/// Voice transcripts keep sources in the UI, while speech reads the answer.
String spokenAnswer(String text) {
  final answer = splitThoughtTags(text).answer;
  final sources = RegExp(
    r'^\s*(?:#{1,6}\s*)?(?:\*\*)?(?:sources|references|مصادر|المصادر)\s*(?::|：|\*\*|$)',
    caseSensitive: false,
    multiLine: true,
  ).firstMatch(answer);
  return (sources == null ? answer : answer.substring(0, sources.start))
      .split('\n')
      .where((line) => !line.startsWith('>'))
      .join('\n')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(
          RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
      .replaceAll(RegExp(r'\s*\[\d+(?:\s*[,–-]\s*\d+)*\]'), '')
      .replaceAll(RegExp(r'https?://\S+'), '')
      .replaceAll(RegExp(r'[*_`#]+'), '')
      .trim();
}
