/// Ready-made MCP servers the user can add with one tap.
class McpPreset {
  final String id;
  final String name;
  final String blurb;
  final String url;

  /// Label for the token field, or null if the server needs no token.
  final String? tokenLabel;
  final String? tokenHelp;
  final String? tokenUrl;

  /// Set when the server can't be used from this app, and why.
  final String? unsupported;

  /// Optional URL parameters the user can fill in (e.g. Supabase project_ref).
  final List<McpPresetField> fields;

  const McpPreset({
    required this.id,
    required this.name,
    required this.blurb,
    required this.url,
    this.tokenLabel,
    this.tokenHelp,
    this.tokenUrl,
    this.unsupported,
    this.fields = const [],
  });
}

class McpPresetField {
  final String key; // URL query parameter
  final String label;
  final String hint;
  const McpPresetField(this.key, this.label, this.hint);
}

const kMcpPresets = <McpPreset>[
  McpPreset(
    id: 'github',
    name: 'GitHub',
    blurb: 'Repos, issues, pull requests, code search',
    url: 'https://api.githubcopilot.com/mcp/',
    tokenLabel: 'GitHub personal access token',
    tokenHelp:
        'Create a token at github.com/settings/tokens. Give it only the scopes you need (e.g. repo for private repos).',
    tokenUrl: 'https://github.com/settings/tokens',
  ),
  McpPreset(
    id: 'supabase',
    name: 'Supabase',
    blurb: 'Databases, SQL, edge functions, logs',
    url: 'https://mcp.supabase.com/mcp',
    tokenLabel: 'Supabase access token',
    tokenHelp:
        'Create a personal access token in your Supabase account settings. Scope it to one project with the field below to limit what the AI can touch.',
    tokenUrl: 'https://supabase.com/dashboard/account/tokens',
    fields: [
      McpPresetField('project_ref', 'Project ref (recommended)', 'abcdefghijklmnop'),
    ],
  ),
  McpPreset(
    id: 'vercel',
    name: 'Vercel',
    blurb: 'Projects, deployments, logs',
    url: 'https://mcp.vercel.com',
    unsupported:
        'Vercel\'s server only accepts browser sign-in (OAuth) from clients Vercel has approved, so a pasted token will not work. To deploy to Vercel, use the Vercel CLI with an access token in the Linux sandbox instead.',
  ),
  McpPreset(
    id: 'deepwiki',
    name: 'DeepWiki',
    blurb: 'Ask questions about public GitHub repos (no key)',
    url: 'https://mcp.deepwiki.com/mcp',
  ),
  McpPreset(
    id: 'context7',
    name: 'Context7',
    blurb: 'Up-to-date library documentation (no key)',
    url: 'https://mcp.context7.com/mcp',
  ),
];

/// Builds the final URL for a preset with its optional parameters.
String presetUrl(McpPreset p, Map<String, String> values) {
  final params = {
    for (final f in p.fields)
      if ((values[f.key] ?? '').trim().isNotEmpty) f.key: values[f.key]!.trim()
  };
  if (params.isEmpty) return p.url;
  final u = Uri.parse(p.url);
  return u.replace(queryParameters: {...u.queryParameters, ...params}).toString();
}
