import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../utils/page_text.dart';
import '../utils/web_search_parse.dart';

enum SearchFailure {
  network,
  timeout,
  provider,
  invalidResponse,
  rateLimited,
  parsing
}

class SearchReport {
  const SearchReport(this.results, this.failures, this.respondingProviders);
  final List<WebResult> results;
  final Map<String, SearchFailure> failures;
  final int respondingProviders;

  String get emptyMessage => respondingProviders > 0
      ? 'No matching results.'
      : 'Search unavailable: ${failures.entries.map((entry) => '${entry.key} (${entry.value.name})').join(', ')}.';
}

class SearchUnavailable implements Exception {
  const SearchUnavailable(this.report);
  final SearchReport report;
  @override
  String toString() => report.emptyMessage;
}

/// Executes validated model-selected search queries.
class WebSearchService extends GetxService {
  WebSearchService({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36';

  static final _fresh = RegExp(
      r'\b(latest|newest|newly|recent(ly)?|current(ly)?|today|tonight|now|this (week|month|year)|just (released|launched)|new|release[sd]?|news|update[sd]?|202\d)\b|اليوم|الآن|آخر|أخر|أحدث|احدث|جديد',
      caseSensitive: false);

  /// DuckDuckGo date filter for questions about "the latest …": past month.
  String? freshnessFor(String question) =>
      _fresh.hasMatch(question) ? 'm' : null;

  Future<List<WebResult>> search(String query,
      {int max = 4, String? freshness}) async {
    final report = await searchReport(query, max: max, freshness: freshness);
    if (report.respondingProviders == 0 && report.failures.isNotEmpty) {
      throw SearchUnavailable(report);
    }
    return report.results;
  }

  Future<SearchReport> searchReport(String query,
      {int max = 4, String? freshness, Future<void>? abort}) async {
    final q = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    final trimmed = q.length > 200 ? q.substring(0, 200) : q;
    if (trimmed.isEmpty || max <= 0) return const SearchReport([], {}, 0);
    final ar = RegExp(r'[؀-ۿ]').hasMatch(trimmed);
    final lang = ar ? 'ar' : 'en';
    final ddg = Uri.https('html.duckduckgo.com', '/html/', {
      'q': trimmed,
      if (freshness != null) 'df': freshness,
    });
    final news = Uri.https('news.google.com', '/rss/search', {
      'q': trimmed,
      'hl': lang,
      'gl': 'US',
      'ceid': 'US:$lang',
    });
    final bing = Uri.https('www.bing.com', '/search', {
      'q': trimmed,
      'format': 'rss',
      'setlang': lang,
    });
    final wiki = Uri.https('$lang.wikipedia.org', '/w/index.php', {
      'search': trimmed,
      'ns0': '1',
    });
    final groups = await Future.wait([
      if (freshness != null)
        _provider(news, (body) => parseNewsRss(body, max: max), abort: abort),
      _provider(ddg, (body) => parseDdgHtml(body, max: max), abort: abort),
      _provider(bing, (body) => parseBingRss(body, max: max), abort: abort),
      if (freshness == null) ...[
        _provider(wiki, (body) => parseWikipediaSearch(body, lang, max: max),
            abort: abort),
        _provider(news, (body) => parseNewsRss(body, max: max), abort: abort),
      ],
    ]);
    final terms = _terms(trimmed);
    final seen = <String>{};
    final relevant = <({WebResult result, int score, int rank})>[];
    for (final (rank, result)
        in groups.expand((group) => group.results).indexed) {
      if (!seen.add(result.url)) continue;
      final title = _terms(result.title);
      final description = _terms(result.snippet);
      final score = terms.intersection(title).length * 2 +
          terms.intersection(description).length;
      if (score > 0 || terms.isEmpty) {
        relevant.add((result: result, score: score, rank: rank));
      }
    }
    relevant.sort((a, b) {
      final difference = b.score.compareTo(a.score);
      return difference == 0 ? a.rank.compareTo(b.rank) : difference;
    });
    return SearchReport(
      relevant.map((entry) => entry.result).take(max).toList(),
      {
        for (final group in groups)
          if (group.failure != null) group.host: group.failure!
      },
      groups.where((group) => group.failure == null).length,
    );
  }

  static Set<String> _terms(String text) {
    const filler = {
      'what',
      'which',
      'when',
      'where',
      'with',
      'from',
      'about',
      'this',
      'that',
      'there',
      'today',
      'latest',
      'current',
      'your',
    };
    return RegExp(r'[a-z0-9؀-ۿ]{2,}')
        .allMatches(text.toLowerCase())
        .map((match) => match.group(0)!)
        .where((word) =>
            word.length >= 3 &&
            !filler.contains(word) &&
            word != 'the' &&
            word != 'and' &&
            word != 'for')
        .map((word) => word.length > 4 && word.endsWith('s')
            ? word.substring(0, word.length - 1)
            : word)
        .toSet();
  }

  Future<({String host, List<WebResult> results, SearchFailure? failure})>
      _provider(Uri uri, List<WebResult> Function(String) parse,
          {Future<void>? abort}) async {
    final client = _clientFactory();
    final host = uri.host;
    final timer = Stopwatch()..start();
    final abortRequest = Completer<void>();
    if (abort != null) {
      unawaited(abort.then((_) {
        if (!abortRequest.isCompleted) abortRequest.complete();
      }));
    }

    ({String host, List<WebResult> results, SearchFailure? failure}) failed(
            SearchFailure reason) =>
        (host: host, results: const [], failure: reason);

    try {
      const limit = Duration(seconds: 5);
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abortRequest.future)
            ..headers['User-Agent'] = _ua
            ..followRedirects = false;
      final response = await client.send(request).timeout(limit);
      if (response.statusCode == 429) return failed(SearchFailure.rateLimited);
      if (response.statusCode != 200) return failed(SearchFailure.provider);
      final bytes = await response.stream.fold<List<int>>([], (buffer, chunk) {
        if (buffer.length + chunk.length > 1024 * 1024) {
          throw const FormatException('Search response is too large.');
        }
        return buffer..addAll(chunk);
      }).timeout(limit - timer.elapsed);
      final body = utf8.decode(bytes);
      final rss =
          uri.path.contains('/rss') || uri.queryParameters['format'] == 'rss';
      if (rss) {
        if (XmlDocument.parse(body).rootElement.name.local != 'rss') {
          return failed(SearchFailure.invalidResponse);
        }
      } else if (!body.toLowerCase().contains('<html')) {
        return failed(SearchFailure.invalidResponse);
      }
      final results = parse(body);
      if (!rss &&
          results.isEmpty &&
          !RegExp(r'no[_ -]results|mw-search-nonefound|result--no-result',
                  caseSensitive: false)
              .hasMatch(body)) {
        return failed(SearchFailure.parsing);
      }
      return (host: host, results: results, failure: null);
    } on TimeoutException {
      return failed(SearchFailure.timeout);
    } on XmlException {
      return failed(SearchFailure.parsing);
    } on FormatException {
      return failed(SearchFailure.invalidResponse);
    } on http.ClientException {
      return failed(SearchFailure.network);
    } finally {
      if (!abortRequest.isCompleted) abortRequest.complete();
      client.close();
    }
  }

  /// Search indexes can return syndicated headline links. The feed already
  /// supplies their titles and dates, so don't ingest the aggregator's UI.
  static bool _isNewsLink(String url) =>
      Uri.tryParse(url)?.host == 'news.google.com';

  /// Reads a page and returns the passages that best match [query].
  Future<String> pageText(String url, String query, {int maxChars = 1800}) =>
      _pageText(url, query, maxChars: maxChars);

  Future<String> _pageText(String url, String query,
      {int maxChars = 1100}) async {
    if (_isNewsLink(url)) return '';
    try {
      final res = await http.get(Uri.parse(url),
          headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return '';
      final ct = res.headers['content-type'] ?? '';
      if (!ct.contains('text/html') && !ct.contains('text/plain')) return '';
      final body =
          res.body.length > 600000 ? res.body.substring(0, 600000) : res.body;
      return bestPassages(readableText(body), query, maxChars: maxChars);
    } catch (_) {
      return '';
    }
  }
}
