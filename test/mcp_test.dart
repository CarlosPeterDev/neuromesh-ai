import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/mcp_client.dart';
import 'package:neuromesh_ai/services/mcp_presets.dart';
import 'package:neuromesh_ai/utils/mcp_import.dart';

void main() {
  test('parses the standard mcpServers config', () {
    final r = parseMcpConfig('''
{"mcpServers":{
  "github":{"url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer abc"}},
  "local":{"command":"npx","args":["-y","thing"]}
}}''');
    expect(r.servers.length, 1);
    expect(r.servers.first.name, 'github');
    expect(r.servers.first.headers['Authorization'], 'Bearer abc');
    expect(r.skipped.single, contains('local'));
  });

  test('accepts a bare URL and a single object', () {
    expect(parseMcpConfig('https://mcp.deepwiki.com/mcp').servers.single.name, 'Deepwiki');
    expect(parseMcpConfig('{"url":"https://x.example/sse"}').servers.single.url,
        'https://x.example/sse');
    expect(parseMcpConfig('not a url').servers, isEmpty);
    expect(parseMcpConfig('{broken').servers, isEmpty);
  });

  test('McpServerConfig round-trips headers and disabled tools', () {
    const c = McpServerConfig(
        id: '1',
        name: 'A',
        url: 'https://a',
        headers: {'X-Key': 'v'},
        disabledTools: {'t1'});
    final b = McpServerConfig.fromMap(c.toMap());
    expect(b.headers['X-Key'], 'v');
    expect(b.disabledTools, {'t1'});
  });

  test('tool signature marks required args', () {
    const t = McpTool(
      serverId: '1',
      serverName: 'S',
      name: 'search',
      description: 'd',
      inputSchema: {
        'properties': {
          'q': {'type': 'string', 'description': 'the query'},
          'n': {'type': 'integer'}
        },
        'required': ['q'],
      },
    );
    expect(t.signature, contains('"q":"string REQUIRED - the query"'));
    expect(t.signature, contains('"n":"integer"'));
  });

  test('preset url gets optional parameters', () {
    final p = kMcpPresets.firstWhere((p) => p.id == 'supabase');
    expect(presetUrl(p, {'project_ref': 'abc'}), 'https://mcp.supabase.com/mcp?project_ref=abc');
    expect(presetUrl(p, {}), 'https://mcp.supabase.com/mcp');
  });
}
