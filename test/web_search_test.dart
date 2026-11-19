import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/utils/web_search_parse.dart';
import 'package:neuromesh_ai/utils/page_text.dart';

void main() {
  const html = '''
<div class="result"><h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1&amp;rut=abc">Example <b>Title</b></a></h2>
<a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">A &amp; B snippet <b>text</b></a></div>
<div class="result"><a class="result__a" href="https://duckduckgo.com/y.js?ad=1">Ad</a></div>
<div class="result"><a class="result__a" href="https://other.org/p">Other</a><a class="result__snippet" href="#">Second snippet</a></div>
''';

  test('parses ddg results and unwraps urls', () {
    final r = parseDdgHtml(html);
    expect(r.length, 2);
    expect(r[0].title, 'Example Title');
    expect(r[0].url, 'https://example.com/a?x=1');
    expect(r[0].snippet, 'A & B snippet text');
    expect(r[1].url, 'https://other.org/p');
  });

  test('wikipedia parsing', () {
    const body =
        '{"query":{"pages":{"1":{"title":"Cairo","index":1,"extract":"Cairo is the capital."}}}}';
    final r = parseWikipedia(body, 'en');
    expect(r.single.url, 'https://en.wikipedia.org/wiki/Cairo');
    expect(r.single.snippet, 'Cairo is the capital.');
    expect(parseWikipedia('nope', 'en'), isEmpty);
  });

  test('an explicit search retry reuses the earlier question', () {
    const retry = 'Please search because this is old';
    const first = 'What is the strongest AI model today for coding?';
    expect(explicitlyRequestsWebSearch(retry), isTrue);
    expect(searchQuery(retry, previous: first), searchQuery(first));
    expect(
        explicitlyRequestsWebSearch('Search my files for the report'), isFalse);
  });

  test('news fallback reads dated headlines and publisher domains', () {
    final results = parseNewsRss('''
<rss><channel>
  <item><title>Model &amp; benchmark</title>
    <link>https://news.google.com/rss/articles/abc</link>
    <pubDate>Thu, 19 Nov 2026 00:00:00 GMT</pubDate>
    <source url="https://www.example.org">Example</source>
  </item>
</channel></rss>
''');
    expect(results.single.title, 'Model & benchmark');
    expect(results.single.publisher, 'www.example.org');
    expect(results.single.snippet, contains('19 Nov 2026'));
    expect(needsWebSearch('What is the strongest ai model for coding'), isTrue);
  });

  test('auto detection', () {
    expect(needsWebSearch('What is the weather in Cairo today?'), true);
    expect(needsWebSearch('latest news about AI'), true);
    expect(needsWebSearch('سعر الدولار اليوم'), true);
    expect(needsWebSearch('Write a poem about the sea'), false);
    expect(needsWebSearch('hi'), false);
  });
}
