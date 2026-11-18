import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/services/hf_service.dart';
import 'package:neuromesh_ai/utils/llama_archs.dart';

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

  test('searchModels maps the task filter to a pipeline tag', () async {
    final seen = <Uri>[];
    final svc = HfService(
      client: MockClient((req) async {
        seen.add(req.url);
        return http.Response(jsonEncode([]), 200);
      }),
    );
    await svc.searchModels('a', task: 'embedding');
    await svc.searchModels('a', task: 'vision');
    await svc.searchModels('a', task: 'text');
    await svc.searchModels('a');
    expect(seen[0].queryParameters['pipeline_tag'], 'feature-extraction');
    expect(seen[1].queryParameters['pipeline_tag'], 'image-text-to-text');
    expect(seen[2].queryParameters['pipeline_tag'], 'text-generation');
    expect(seen[3].queryParameters.containsKey('pipeline_tag'), false);
  });

  test('listGgufFiles drops split shards and projector files, sorts by size', () async {
    final svc = HfService(
      client: MockClient((req) async => http.Response(
            jsonEncode([
              {'type': 'file', 'path': 'm-Q8_0.gguf', 'lfs': {'size': 800}},
              {'type': 'file', 'path': 'm-Q4_K_M.gguf', 'size': 400},
              {'type': 'file', 'path': 'big-00001-of-00002.gguf', 'size': 9000},
              {'type': 'file', 'path': 'mmproj-F16.gguf', 'size': 100},
              {'type': 'file', 'path': 'Qwen3.8-27B-FastMTP-32K.gguf', 'size': 903453952},
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

  test('FastMTP draft names are distinguished from complete MTP models', () {
    const draft = 'Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-FastMTP-32K';
    expect(isFastMtpDraft('$draft.gguf'), isTrue);
    expect(isFastMtpDraft(draft), isTrue);
    expect(isFastMtpDraft('Qwen3.8-27B-MTP-Q4_K_M.gguf'), isFalse);
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
