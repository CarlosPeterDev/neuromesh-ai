import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/web_search_service.dart';

void main() {
  test(
      'valid empty feeds differ from rate limits, protocol and parsing failures',
      () async {
    final search = WebSearchService(
        clientFactory: () => MockClient((request) async {
              return switch (request.url.host) {
                'news.google.com' =>
                  http.Response('<rss><channel/></rss>', 200),
                'www.bing.com' => http.Response('<rss><channel>', 200),
                'html.duckduckgo.com' => http.Response('Retry later', 429),
                _ => http.Response('not HTML', 200),
              };
            }));
    final report = await search.searchReport('query');
    expect(report.results, isEmpty);
    expect(report.respondingProviders, 1);
    expect(report.emptyMessage, 'No matching results.');
    expect(report.failures, {
      'html.duckduckgo.com': SearchFailure.rateLimited,
      'www.bing.com': SearchFailure.parsing,
      'en.wikipedia.org': SearchFailure.invalidResponse,
    });
  });

  test('all unavailable providers surface typed failures', () async {
    final search = WebSearchService(
        clientFactory: () => MockClient((request) async {
              if (request.url.host == 'news.google.com') {
                throw http.ClientException('Connection refused');
              }
              if (request.url.host == 'www.bing.com') {
                throw TimeoutException('Provider timed out');
              }
              return http.Response('Provider failed', 503);
            }));
    final report = await search.searchReport('query');
    expect(report.respondingProviders, 0);
    expect(
        report.failures.values,
        containsAll([
          SearchFailure.network,
          SearchFailure.timeout,
          SearchFailure.provider,
        ]));
    await expectLater(
        search.search('query'), throwsA(isA<SearchUnavailable>()));
  });
}
