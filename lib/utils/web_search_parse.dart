import 'dart:convert';

class WebResult {
  final String title;
  final String url;
  final String snippet;
  const WebResult(this.title, this.url, this.snippet);
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
  if (u != null && u.host.endsWith('duckduckgo.com') && u.path.startsWith('/l')) {
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
  final snip = RegExp(
      r'<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</a>');
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

/// Parses the Wikipedia generator=search extract response.
List<WebResult> parseWikipedia(String body, String lang, {int max = 3}) {
  try {
    final data = jsonDecode(body) as Map<String, dynamic>;
    final pages = (data['query']?['pages'] as Map?)?.values.toList() ?? [];
    pages.sort((a, b) =>
        ((a['index'] ?? 99) as num).compareTo((b['index'] ?? 99) as num));
    return pages.take(max).map((p) {
      final title = '${p['title']}';
      return WebResult(
          '$title - Wikipedia',
          'https://$lang.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
          _clean('${p['extract'] ?? ''}'));
    }).toList();
  } catch (_) {
    return [];
  }
}

final _recency = RegExp(
    r'\b(today|tonight|tomorrow|yesterday|right now|latest|current(ly)?|recent(ly)?|news|headline|price of|how much (is|does|are)|cost of|weather|forecast|score|who won|results?|release date|released|stock|exchange rate|trending|this (week|month|year)|202\d|search|look ?up|google|find out|what happened|is .* (open|available))\b',
    caseSensitive: false);
final _arabic = RegExp(
    r'(اليوم|الآن|حاليا|حالياً|آخر|أخر|أخبار|اخبار|سعر|أسعار|طقس|الطقس|نتيجة|نتائج|ابحث|دور|بحث|ماذا حدث|هذا الأسبوع|هذا الشهر|202\d)');

/// Cheap check for "this question probably needs fresh information".
bool needsWebSearch(String question) {
  final q = question.trim();
  if (q.length < 8) return false;
  return _recency.hasMatch(q) || _arabic.hasMatch(q);
}

/// Questions whose answers depend on current information.
bool asksForCurrentFacts(String question) => RegExp(
      r'\b(?:today|tonight|right now|latest|currently|current|newest|recent|news|weather|forecast|trending|release date|this (?:week|month|year))\b|اليوم|الآن|الحالي|أحدث|آخر الأخبار|الطقس',
      caseSensitive: false,
    ).hasMatch(question);

/// An explicit request can turn on search for one chat turn.
bool explicitlyRequestsWebSearch(String question) => RegExp(
      r'^\s*(?:(?:ok(?:ay)?|yes|please|can you|could you)[,.!]?\s+)*(?:search(?:\s+(?:the web|online))?|look\s+up|google)\b(?!\s+(?:my|this|the)\s+(?:files?|attachments?|documents?|workspace)\b)|^\s*ابحث',
      caseSensitive: false,
    ).hasMatch(question);
