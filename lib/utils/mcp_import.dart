import 'dart:convert';

/// One server read from pasted MCP JSON.
class ImportedMcp {
  final String name;
  final String url;
  final Map<String, String> headers;
  const ImportedMcp(this.name, this.url, this.headers);
}

class McpImportResult {
  final List<ImportedMcp> servers;

  /// Entries that can't work here (e.g. "command": "npx ..." local servers).
  final List<String> skipped;
  const McpImportResult(this.servers, this.skipped);
}

/// Reads the config format every MCP client shares:
/// {"mcpServers": {"name": {"url": "...", "headers": {...}}}}.
/// Also accepts a bare {"name": {...}} map, a single {"url": ...} object,
/// or just a URL.
McpImportResult parseMcpConfig(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const McpImportResult([], []);
  if (!text.startsWith('{') && !text.startsWith('[')) {
    final u = Uri.tryParse(text);
    if (u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty) {
      return McpImportResult([ImportedMcp(_nameFromUrl(u), text, const {})], const []);
    }
    return const McpImportResult([], ['Not JSON or a URL']);
  }
  dynamic data;
  try {
    data = jsonDecode(text);
  } catch (_) {
    return const McpImportResult([], ['Invalid JSON']);
  }
  if (data is! Map) return const McpImportResult([], ['Expected a JSON object']);
  Map entries;
  if (data['mcpServers'] is Map) {
    entries = data['mcpServers'] as Map;
  } else if (data['servers'] is Map) {
    entries = data['servers'] as Map;
  } else if (data['url'] != null || data['serverUrl'] != null) {
    entries = {_nameFromUrl(Uri.tryParse((data['url'] ?? data['serverUrl']).toString())): data};
  } else {
    entries = data;
  }
  final out = <ImportedMcp>[];
  final skipped = <String>[];
  for (final e in entries.entries) {
    final name = e.key.toString();
    final v = e.value;
    if (v is! Map) continue;
    final url = (v['url'] ?? v['serverUrl'] ?? v['httpUrl'])?.toString();
    if (url == null || url.isEmpty) {
      skipped.add(v['command'] != null
          ? '$name (runs a local program: not possible on a phone)'
          : '$name (no url)');
      continue;
    }
    final u = Uri.tryParse(url);
    if (u == null || !(u.scheme == 'https' || u.scheme == 'http') || u.host.isEmpty) {
      skipped.add('$name (bad url)');
      continue;
    }
    final headers = <String, String>{};
    final h = v['headers'];
    if (h is Map) {
      for (final he in h.entries) {
        headers[he.key.toString()] = he.value.toString();
      }
    }
    out.add(ImportedMcp(name, url, headers));
  }
  return McpImportResult(out, skipped);
}

String _nameFromUrl(Uri? u) {
  final host = (u?.host ?? 'server').replaceFirst(RegExp(r'^(www|mcp|api)\.'), '');
  final base = host.split('.').first;
  return base.isEmpty ? 'server' : base[0].toUpperCase() + base.substring(1);
}
