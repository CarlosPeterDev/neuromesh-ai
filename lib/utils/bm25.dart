import 'dart:math' as math;

/// Splits text into overlapping chunks, preferring paragraph/sentence breaks.
List<String> chunkText(String text,
    {int size = 800, int overlap = 120}) {
  final clean = text.replaceAll('\r', '').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  if (clean.isEmpty) return [];
  final out = <String>[];
  var start = 0;
  while (start < clean.length) {
    var end = math.min(start + size, clean.length);
    if (end < clean.length) {
      // Prefer to cut at a paragraph or sentence end in the last 25%.
      final window = clean.substring(start + (size * 0.75).round(), end);
      final cut = math.max(window.lastIndexOf('\n'),
          math.max(window.lastIndexOf('. '), window.lastIndexOf('؟ ')));
      if (cut >= 0) end = start + (size * 0.75).round() + cut + 1;
    }
    final piece = clean.substring(start, end).trim();
    if (piece.isNotEmpty) out.add(piece);
    if (end >= clean.length) break;
    start = math.max(end - overlap, start + 1);
  }
  return out;
}

final _splitter = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
const _stop = {
  'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'is', 'are', 'was',
  'it', 'for', 'with', 'as', 'at', 'by', 'this', 'that', 'what', 'how', 'do',
  'في', 'من', 'على', 'إلى', 'عن', 'ما', 'هو', 'هي', 'و',
};

List<String> tokenize(String s) => s
    .toLowerCase()
    .split(_splitter)
    .where((t) => t.length > 1 && !_stop.contains(t))
    .toList();

/// Keyword ranking (BM25). Returns chunk indexes, best first.
/// This is keyword matching, not semantic search.
List<int> bm25Top(List<String> chunks, String query,
    {int k = 4, double k1 = 1.4, double b = 0.75}) {
  final q = tokenize(query).toSet().toList();
  if (q.isEmpty || chunks.isEmpty) return [];
  final docs = chunks.map(tokenize).toList();
  final avg = docs.fold<int>(0, (a, d) => a + d.length) / docs.length;
  final df = <String, int>{};
  for (final d in docs) {
    for (final t in d.toSet()) {
      df[t] = (df[t] ?? 0) + 1;
    }
  }
  final n = docs.length;
  final scores = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final tf = <String, int>{};
    for (final t in docs[i]) {
      tf[t] = (tf[t] ?? 0) + 1;
    }
    for (final term in q) {
      final f = tf[term];
      if (f == null) continue;
      final idf = math.log(1 + (n - (df[term] ?? 0) + 0.5) / ((df[term] ?? 0) + 0.5));
      final denom = f + k1 * (1 - b + b * docs[i].length / (avg == 0 ? 1 : avg));
      scores[i] += idf * (f * (k1 + 1)) / denom;
    }
  }
  final idx = List<int>.generate(n, (i) => i)
    ..sort((a, b2) => scores[b2].compareTo(scores[a]));
  return idx.where((i) => scores[i] > 0).take(k).toList();
}
