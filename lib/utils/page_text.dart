import 'bm25.dart';

String _decode(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#x27;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'&[a-z#0-9]+;'), ' ');

String _strip(String s) => _decode(s
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' '))
    .trim();

/// Pulls the readable body text out of an HTML page: prefers <article> or
/// <main>, keeps paragraphs, list items and headings, and drops menus,
/// scripts and footers. Returns paragraphs separated by blank lines.
String readableText(String html) {
  var h = html.replaceAll(
      RegExp(
          r'<(script|style|noscript|svg|nav|header|footer|aside|form|iframe)\b[\s\S]*?</\1>',
          caseSensitive: false),
      ' ');
  final scope = RegExp(r'<(article|main)\b[\s\S]*?</\1>', caseSensitive: false)
      .firstMatch(h);
  if (scope != null && scope.group(0)!.length > 600) h = scope.group(0)!;
  final out = <String>[];
  for (final m in RegExp(r'<(p|li|h[1-4]|td)\b[^>]*>([\s\S]*?)</\1>',
          caseSensitive: false)
      .allMatches(h)) {
    final t = _strip(m.group(2)!);
    // Skip one-word nav-ish crumbs; keep real sentences and headings.
    if (t.length >= 25 || (m.group(1)!.startsWith('h') && t.length >= 4)) {
      out.add(t);
    }
  }
  if (out.isEmpty) return _strip(h);
  return out.join('\n\n');
}

/// The passages of [text] that best match [query] (keyword ranking), kept in
/// reading order and capped at [maxChars].
String bestPassages(String text, String query, {int maxChars = 1000}) {
  if (text.trim().isEmpty) return '';
  final chunks = chunkText(text, size: 450, overlap: 40);
  final ranked = bm25Top(chunks, query, k: 3); // best match first
  final picked = <int>[];
  var used = 0;
  for (final i in ranked) {
    if (picked.isNotEmpty && used + chunks[i].length > maxChars) continue;
    picked.add(i);
    used += chunks[i].length;
  }
  picked.sort(); // read in page order
  final b = StringBuffer();
  for (final i in picked) {
    if (b.isNotEmpty) b.write(' … ');
    b.write(chunks[i].replaceAll('\n\n', ' '));
  }
  final s = b.toString();
  if (s.isNotEmpty) return s.length > maxChars ? s.substring(0, maxChars) : s;
  return text.length > maxChars ? text.substring(0, maxChars) : text;
}

final _filler = RegExp(
    r'^(please|pls|hey|hi|ok|okay|can you|could you|would you|i want you to|i want to know|tell me|search( the web| online)?( for)?|look up|find( out)?|google)\b[\s,:]*',
    caseSensitive: false);

/// Turns a chat message into a search query: drops politeness, and when the
/// message is a short follow-up ("and in 2025?") borrows the previous
/// question for context.
String searchQuery(String question, {String? previous}) {
  var q = question.trim();
  for (var i = 0; i < 3; i++) {
    final next = q.replaceFirst(_filler, '');
    if (next == q) break;
    q = next;
  }
  q = q.replaceAll(RegExp(r'[?؟!]+$'), '').trim();
  if (q.isEmpty) q = question.trim();
  final retry = RegExp(
    r'^\s*(?:(?:ok(?:ay)?|yes|please)[,.!]?\s+)*(?:search|look up)(?:\s+(?:the web|online|again|please|for it))*(?:\s+(?:because|since|as)\b.*)?[.!?]*\s*$',
    caseSensitive: false,
  ).hasMatch(question);
  if (retry && previous != null && previous.trim().isNotEmpty) {
    return searchQuery(previous);
  }
  final words = q.split(RegExp(r'\s+')).length;
  if (words <= 3 && previous != null && previous.trim().isNotEmpty) {
    final prev = searchQuery(previous);
    q = '$prev $q';
  }
  return q.length > 200 ? q.substring(0, 200) : q;
}

/// Keeps the first result per website so one site can't fill the list.
List<T> dedupeByHost<T>(List<T> items, String Function(T) urlOf) {
  final seen = <String>{};
  final out = <T>[];
  for (final it in items) {
    final host = Uri.tryParse(urlOf(it))?.host.replaceFirst('www.', '') ?? '';
    if (host.isEmpty || seen.add(host)) out.add(it);
  }
  return out;
}
