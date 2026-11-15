import 'dart:async';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;

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

  Future<List<WebResult>> search(String query, {int max = 4}) async {
    final q = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    final trimmed = q.length > 200 ? q.substring(0, 200) : q;
    try {
      final res = await http
          .post(Uri.parse('https://html.duckduckgo.com/html/'),
              headers: {
                'User-Agent': _ua,
                'Content-Type': 'application/x-www-form-urlencoded'
              },
              body: {'q': trimmed})
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final r = parseDdgHtml(res.body, max: max);
        if (r.isNotEmpty) return r;
      }
    } catch (_) {}
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

  Future<String> _pageText(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return '';
      final ct = res.headers['content-type'] ?? '';
      if (!ct.contains('text/html') && !ct.contains('text/plain')) return '';
      final t = res.body
          .replaceAll(RegExp(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>|<nav[\s\S]*?</nav>|<header[\s\S]*?</header>|<footer[\s\S]*?</footer>', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'&[a-z#0-9]+;'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return t.length > 1400 ? t.substring(0, 1400) : t;
    } catch (_) {
      return '';
    }
  }

  /// Runs the search and builds the text block added to the prompt.
  Future<WebContext?> buildContext(String question) async {
    final results = await search(question);
    if (results.isEmpty) return null;
    // Read the top two pages for more than a snippet.
    final pages = await Future.wait(results.take(2).map((r) => _pageText(r.url)));
    final b = StringBuffer(
        'Web search results (retrieved ${DateTime.now().toIso8601String().substring(0, 10)}). '
        'Use them if they help, cite sources like [1], and say so if they do not answer the question.\n');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      final body = i < pages.length && pages[i].length > r.snippet.length
          ? pages[i]
          : r.snippet;
      b.writeln('\n[${i + 1}] ${r.title} (${r.url})\n$body');
    }
    return WebContext(b.toString(), results);
  }
}
