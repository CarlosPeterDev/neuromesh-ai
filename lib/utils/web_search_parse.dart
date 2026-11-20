import 'package:xml/xml.dart';

class WebResult {
  final String title;
  final String url;
  final String snippet;
  final String? publisher;
  const WebResult(this.title, this.url, this.snippet, {this.publisher});
}

String _clean(String s) => s
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#x27;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// DuckDuckGo wraps result links as //duckduckgo.com/l/?uddg=<encoded url>.
String unwrapDdgUrl(String href) {
  var h = href.replaceAll('&amp;', '&');
  if (h.startsWith('//')) h = 'https:$h';
  final u = Uri.tryParse(h);
  if (u != null &&
      u.host.endsWith('duckduckgo.com') &&
      u.path.startsWith('/l')) {
    final real = u.queryParameters['uddg'];
    if (real != null && real.isNotEmpty) return real;
  }
  return h;
}

/// Parses the HTML results page of html.duckduckgo.com.
List<WebResult> parseDdgHtml(String html, {int max = 5}) {
  final out = <WebResult>[];
  final link = RegExp(
      r'<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>');
  final snip =
      RegExp(r'<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</a>');
  final links = link.allMatches(html).toList();
  final snips = snip.allMatches(html).toList();
  for (var i = 0; i < links.length && out.length < max; i++) {
    final url = unwrapDdgUrl(links[i].group(1)!);
    if (!url.startsWith('http')) continue;
    if (url.contains('duckduckgo.com/y.js')) continue; // ads
    final title = _clean(links[i].group(2)!);
    final s = i < snips.length ? _clean(snips[i].group(1)!) : '';
    if (title.isEmpty) continue;
    out.add(WebResult(title, url, s));
  }
  return out;
}

/// Parses dated publisher headlines from a Google News search feed.
List<WebResult> parseNewsRss(String body, {int max = 5}) {
  try {
    final results = <WebResult>[];
    for (final item in XmlDocument.parse(body).findAllElements('item')) {
      final title = _clean(item.getElement('title')?.innerText ?? '');
      final url = Uri.tryParse(item.getElement('link')?.innerText.trim() ?? '');
      final source = item.getElement('source');
      final host = Uri.tryParse(source?.getAttribute('url') ?? '')?.host;
      if (title.isEmpty ||
          url?.scheme != 'https' ||
          url?.host != 'news.google.com' ||
          host == null ||
          host.isEmpty) {
        continue;
      }
      final date = item.getElement('pubDate')?.innerText.trim();
      results.add(WebResult(title, url.toString(),
          '${source?.innerText ?? host}${date == null ? '' : ' · $date'}',
          publisher: host));
      if (results.length >= max) break;
    }
    return results;
  } on XmlException {
    return [];
  }
}

/// Parses Wikipedia's public search page.
List<WebResult> parseWikipediaSearch(String body, String lang, {int max = 4}) {
  final out = <WebResult>[];
  final entries =
      RegExp(r'<li\b[^>]*class="mw-search-result\b[^"]*"[^>]*>([\s\S]*?)</li>');
  final heading = RegExp(
      r'<div\s+class="mw-search-result-heading"[^>]*>\s*<a[^>]+href="(/wiki/[^"]+)"[^>]*>([\s\S]*?)</a>');
  final snippet = RegExp(r'<div\s+class="searchresult"[^>]*>([\s\S]*?)</div>');
  for (final entry in entries.allMatches(body)) {
    final item = entry.group(1)!;
    final link = heading.firstMatch(item);
    if (link == null) continue;
    final url =
        Uri.https('$lang.wikipedia.org').resolve(_clean(link.group(1)!));
    final title = _clean(link.group(2)!);
    if (title.isEmpty ||
        !url.path.startsWith('/wiki/') ||
        url.path.substring('/wiki/'.length).contains(':')) {
      continue;
    }
    out.add(WebResult(title, url.toString(),
        _clean(snippet.firstMatch(item)?.group(1) ?? '')));
    if (out.length >= max) break;
  }
  return out;
}

/// Parses public Bing RSS results and keeps their direct publisher URLs.
List<WebResult> parseBingRss(String body, {int max = 5}) {
  try {
    final results = <WebResult>[];
    for (final item in XmlDocument.parse(body).findAllElements('item')) {
      final title = _clean(item.getElement('title')?.innerText ?? '');
      final url = Uri.tryParse(item.getElement('link')?.innerText.trim() ?? '');
      if (title.isEmpty ||
          url == null ||
          (url.scheme != 'http' && url.scheme != 'https') ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) continue;
      final snippet = _clean(item.getElement('description')?.innerText ?? '');
      results.add(WebResult(title, url.toString(), snippet));
      if (results.length >= max) break;
    }
    return results;
  } on XmlException {
    return [];
  }
}

final _recency = RegExp(
    r'\b(today|tonight|tomorrow|yesterday|right now|latest|current(ly)?|recent(ly)?|news|headline|price of|how much (is|does|are)|cost of|weather|forecast|score|who won|results?|release date|released|stock|exchange rate|trending|this (week|month|year)|202\d|search|look ?up|google|find out|what happened|is .* (open|available))\b',
    caseSensitive: false);
final _arabic = RegExp(
    r'(اليوم|الآن|حاليا|حالياً|آخر|أخر|أخبار|اخبار|سعر|أسعار|طقس|الطقس|نتيجة|نتائج|ابحث|دور|بحث|ماذا حدث|هذا الأسبوع|هذا الشهر|202\d)');

final _modelRanking = RegExp(
    r'\b(?:best|strongest|leading|top)\b.{0,45}\b(?:ai|llm|language model|model)s?\b',
    caseSensitive: false);

/// Cheap check for "this question probably needs fresh information".
bool needsWebSearch(String question) {
  final q = question.trim();
  if (q.length < 8) return false;
  return _recency.hasMatch(q) ||
      _arabic.hasMatch(q) ||
      _modelRanking.hasMatch(q);
}

/// Questions whose answers depend on current information.
bool asksForCurrentFacts(String question) => RegExp(
      r'\b(?:today|tonight|right now|latest|currently|current|newest|recent|news|weather|forecast|trending|release date|this (?:week|month|year))\b|اليوم|الآن|الحالي|أحدث|آخر الأخبار|الطقس',
      caseSensitive: false,
    ).hasMatch(question);

/// An explicit request can turn on search for one chat turn.
bool explicitlyRequestsWebSearch(String question) => RegExp(
      r'^\s*(?:(?:ok(?:ay)?|yes|please|now|can you|could you|would you)[,.!]?\s+)*(?:search(?:\s+(?:the web|online))?|look\s+up|google)\b(?!\s+(?:my|this|the)\s+(?:files?|attachments?|documents?|workspace)\b)|^\s*ابحث',
      caseSensitive: false,
    ).hasMatch(question);
