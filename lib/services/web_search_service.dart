import 'dart:async';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../utils/page_text.dart';
import '../utils/web_search_parse.dart';
import 'hive_service.dart';

enum WebSearchMode { off, auto, always }

class WebContext {
  final String block;
  final List<WebResult> sources;
  WebContext(this.block, this.sources);

  String sourcesMarkdown() => sources.isEmpty
      ? ''
      : '\n\nSources:\n${[
          for (var i = 0; i < sources.length; i++)
            '${i + 1}. [${sources[i].title}](${sources[i].url})'
        ].join('\n')}';
}

/// Free web search with no account or key: DuckDuckGo's HTML page, with
/// Wikipedia as a backup. Your question is sent to those sites, so this is
/// off by default.
class WebSearchService extends GetxService {
  static const _kMode = 'web_search_mode';
  final mode = WebSearchMode.off.obs;

  static const _ua =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Mobile Safari/537.36';

  @override
  void onInit() {
    super.onInit();
    final v = Get.find<HiveService>().getSetting<String>(_kMode) ?? 'off';
    mode.value = WebSearchMode.values.firstWhere((m) => m.name == v,
        orElse: () => WebSearchMode.off);
  }

  Future<void> setMode(WebSearchMode m) async {
    mode.value = m;
    await Get.find<HiveService>().setSetting(_kMode, m.name);
  }

  bool shouldSearch(String question) {
    switch (mode.value) {
      case WebSearchMode.off:
        return false;
      case WebSearchMode.always:
        return question.trim().length >= 3;
      case WebSearchMode.auto:
        return needsWebSearch(question);
    }
  }

  static final _fresh = RegExp(
      r'\b(latest|newest|newly|recent(ly)?|current(ly)?|today|tonight|now|this (week|month|year)|just (released|launched)|new|release[sd]?|news|update[sd]?|202\d)\b|اليوم|الآن|آخر|أخر|أحدث|احدث|جديد',
      caseSensitive: false);

  /// DuckDuckGo date filter for questions about "the latest …": past month.
  String? freshnessFor(String question) => _fresh.hasMatch(question) ? 'm' : null;

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];

  /// One or two search queries for a question: the cleaned question, plus the
  /// same with the current month and year when it asks for fresh information.
  List<String> researchQueries(String question, {String? previous}) {
    final base = searchQuery(question, previous: previous);
    final out = <String>[base];
    if (freshnessFor(base) != null || freshnessFor(question) != null) {
      final now = DateTime.now();
      final stamp = '${_months[now.month - 1]} ${now.year}';
      if (!base.contains('${now.year}')) out.add('$base $stamp');
    }
    return out;
  }

  Future<List<WebResult>> search(String query, {int max = 4, String? freshness}) async {
    final q = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    final trimmed = q.length > 200 ? q.substring(0, 200) : q;
    for (final df in [if (freshness != null) freshness, null]) {
      try {
        final res = await http
            .post(Uri.parse('https://html.duckduckgo.com/html/'),
                headers: {
                  'User-Agent': _ua,
                  'Content-Type': 'application/x-www-form-urlencoded'
                },
                body: {'q': trimmed, if (df != null) 'df': df})
            .timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) {
          final r = parseDdgHtml(res.body, max: max);
          if (r.isNotEmpty) return r;
        }
      } catch (_) {}
    }
    // Backup: Wikipedia.
    try {
      final ar = RegExp(r'[؀-ۿ]').hasMatch(trimmed);
      final lang = ar ? 'ar' : 'en';
      final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'generator': 'search',
        'gsrsearch': trimmed,
        'gsrlimit': '3',
        'prop': 'extracts',
        'exintro': '1',
        'explaintext': '1',
        'exchars': '700',
        'format': 'json',
      });
      final res = await http
          .get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) return parseWikipedia(res.body, lang);
    } catch (_) {}
    return [];
  }

  /// Reads a page and returns the passages that best match [query].
  Future<String> pageText(String url, String query, {int maxChars = 1800}) =>
      _pageText(url, query, maxChars: maxChars);

  Future<String> _pageText(String url, String query, {int maxChars = 1100}) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 7));
      if (res.statusCode != 200) return '';
      final ct = res.headers['content-type'] ?? '';
      if (!ct.contains('text/html') && !ct.contains('text/plain')) return '';
      final body = res.body.length > 600000 ? res.body.substring(0, 600000) : res.body;
      return bestPassages(readableText(body), query, maxChars: maxChars);
    } catch (_) {
      return '';
    }
  }

  final _cache = <String, (DateTime, WebContext?)>{};

  /// Runs the search and builds the text block added to the prompt.
  /// [previous] is the user's earlier question, used for short follow-ups.
  Future<WebContext?> buildContext(String question,
      {String? previous, bool refresh = false}) async {
    final query = searchQuery(question, previous: previous);
    final hit = _cache[query];
    if (!refresh &&
        hit != null &&
        DateTime.now().difference(hit.$1).inMinutes < 10) {
      return hit.$2;
    }
    final fresh = freshnessFor(question) ?? freshnessFor(query);
    final merged = <WebResult>[];
    for (final q in researchQueries(question, previous: previous)) {
      merged.addAll(await search(q, max: 8, freshness: fresh));
    }
    final results = dedupeByHost(merged, (r) => r.url).take(6).toList();
    if (results.isEmpty) return null;
    // Read the top four pages and keep only the passages that match.
    final pages = await Future.wait(
        results.take(4).map((r) => _pageText(r.url, query, maxChars: 1600)));
    final b = StringBuffer(
        'Web search results for "$query". Today is ${DateTime.now().toIso8601String().substring(0, 10)}. '
        'Your own knowledge of recent events is out of date, so answer ONLY from these results. '
        'Give a complete, specific answer (names, versions, dates, numbers) and never a one-word reply. '
        'Prefer the newest information by date; if sources disagree, say so. Cite sources like [1]. '
        'If the results do not answer the question, say that plainly.\n');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      final body = i < pages.length && pages[i].length > r.snippet.length
          ? pages[i]
          : r.snippet;
      b.writeln('\n[${i + 1}] ${r.title} (${r.url})\n$body');
    }
    final ctx = WebContext(b.toString(), results);
    _cache[query] = (DateTime.now(), ctx);
    return ctx;
  }
}
