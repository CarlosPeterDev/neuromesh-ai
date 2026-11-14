import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/hf_service.dart';

void main() {
  test('searchModels asks for gguf repos sorted by downloads', () async {
    late Uri seen;
    final svc = HfService(
      client: MockClient((req) async {
        seen = req.url;
        return http.Response(
          jsonEncode([
            {'id': 'unsloth/DeepSeek-R1-GGUF', 'downloads': 10, 'likes': 2, 'gated': false},
            {'id': 'x/gated-one', 'gated': 'manual'},
          ]),
          200,
        );
      }),
    );
    final repos = await svc.searchModels('deepseek');
    expect(seen.queryParameters['search'], 'deepseek');
    expect(seen.queryParameters['filter'], 'gguf');
    expect(seen.queryParameters['sort'], 'downloads');
    expect(repos.length, 2);
    expect(repos.first.name, 'DeepSeek-R1-GGUF');
    expect(repos.first.gated, false);
    expect(repos.last.gated, true);
  });

  test('listGgufFiles drops split shards and projector files, sorts by size', () async {
    final svc = HfService(
      client: MockClient((req) async => http.Response(
            jsonEncode([
              {'type': 'file', 'path': 'm-Q8_0.gguf', 'lfs': {'size': 800}},
              {'type': 'file', 'path': 'm-Q4_K_M.gguf', 'size': 400},
              {'type': 'file', 'path': 'big-00001-of-00002.gguf', 'size': 9000},
              {'type': 'file', 'path': 'mmproj-F16.gguf', 'size': 100},
              {'type': 'file', 'path': 'README.md', 'size': 1},
              {'type': 'directory', 'path': 'sub'},
            ]),
            200,
          )),
    );
    final files = await svc.listGgufFiles('a/b');
    expect(files.map((f) => f.filename).toList(), ['m-Q4_K_M.gguf', 'm-Q8_0.gguf']);
    expect(files.first.quant, 'Q4_K_M');
  });

  test('errors become readable messages', () async {
    final svc = HfService(client: MockClient((_) async => http.Response('no', 500)));
    expect(svc.searchModels('x'), throwsA(isA<HfException>()));
  });

  test('downloadUrl encodes path segments', () {
    expect(HfService.downloadUrl('a/b', 'dir/my file.gguf'),
        'https://huggingface.co/a/b/resolve/main/dir/my%20file.gguf');
  });
}
