import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'agent_adapter.dart';
import 'openai_server_service_io.dart';

bool get hasDesktopAgents =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

AgentAdapter createOpenCodeAdapter() => OpenCodeAdapter();

class OpenCodeAdapter implements AgentAdapter {
  OpenCodeAdapter({Map<String, String>? environment})
      : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;
  static const verifiedVersion = '1.19.6';
  static const _providerId = 'neuromesh';
  static const _model = '$_providerId/${OpenAiServerService.agentModelId}';
  static const _keyName = 'NEUROMESH_BRIDGE_KEY';

  @override
  String get name => 'OpenCode';

  @override
  Uri get installationGuide => Uri.parse('https://opencode.ai/docs/');

  @override
  Future<AgentInstallation> discover() async {
    if (!hasDesktopAgents) return const AgentInstallation();
    final home = _environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    final path = _environment['PATH'] ?? _environment['Path'] ?? '';
    final directories = [
      ...path.split(Platform.isWindows ? ';' : ':'),
      if (!Platform.isWindows && home != null) ...[
        '$home/.opencode/bin',
        '$home/.local/bin',
        '$home/.bun/bin',
      ],
      if (Platform.isMacOS) ...['/opt/homebrew/bin', '/usr/local/bin'],
    ];
    final executable = _findExecutable(
        Platform.isWindows ? 'opencode.exe' : 'opencode', directories);
    if (executable == null) return const AgentInstallation();
    final version = await _versionOf(executable);
    return AgentInstallation(
      executable: executable,
      version: version,
      terminalAvailable: _terminal != null,
      compatible:
          Platform.isLinux && !_hasManagedConfig && version == verifiedVersion,
    );
  }

  bool get _hasManagedConfig =>
      FileSystemEntity.typeSync('/etc/opencode/opencode.json',
              followLinks: false) !=
          FileSystemEntityType.notFound ||
      FileSystemEntity.typeSync('/etc/opencode/opencode.jsonc',
              followLinks: false) !=
          FileSystemEntityType.notFound;

  ({String executable, List<String> arguments})? get _terminal {
    if (!Platform.isLinux ||
        (_environment['DISPLAY']?.isNotEmpty != true &&
            _environment['WAYLAND_DISPLAY']?.isNotEmpty != true)) {
      return null;
    }
    final path = (_environment['PATH'] ?? '').split(':');
    final xfce = _findExecutable('xfce4-terminal', path);
    if (xfce != null) {
      return (executable: xfce, arguments: ['--disable-server', '--execute']);
    }
    if (_environment['DISPLAY']?.isNotEmpty == true) {
      final xterm = _findExecutable('xterm', path);
      if (xterm != null) return (executable: xterm, arguments: ['-e']);
    }
    return null;
  }

  String? _findExecutable(String name, List<String> directories) {
    for (final directory in directories) {
      final absolute = Platform.isWindows
          ? RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\)').hasMatch(directory)
          : directory.startsWith('/');
      if (!absolute) continue;
      final file = File('$directory${Platform.pathSeparator}$name');
      try {
        final stat = file.statSync();
        if (stat.type == FileSystemEntityType.file &&
            (Platform.isWindows || (stat.mode & 0x49) != 0)) {
          return file.resolveSymbolicLinksSync();
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  Future<String?> _versionOf(String executable) async {
    try {
      final output = await _stdout(executable, ['--version']);
      return RegExp(r'^\d+\.\d+\.\d+(?:[-+][\w.-]+)?$').hasMatch(output ?? '')
          ? output
          : null;
    } on ProcessException {
      return null;
    }
  }

  Future<String?> _stdout(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    final stdout = StringBuffer();
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) {
      if (stdout.length < 8192) stdout.write(chunk);
    });
    final stderr = process.stderr.drain<void>();
    return Future.wait<void>(
            [output, stderr, process.exitCode.then<void>((_) {})])
        .then<String?>((_) async =>
            await process.exitCode == 0 ? stdout.toString().trim() : null)
        .timeout(const Duration(seconds: 10), onTimeout: () {
      process.kill();
      return null;
    });
  }

  @override
  Future<AgentTerminalSession> openTerminal({
    required AgentInstallation installation,
    required String modelName,
    required int contextTokens,
  }) async {
    final executable = installation.executable;
    final terminal = _terminal;
    if (!Platform.isLinux ||
        executable == null ||
        !installation.compatible ||
        _hasManagedConfig ||
        await _versionOf(executable) != verifiedVersion) {
      throw StateError('The detected OpenCode installation is incompatible.');
    }
    if (terminal == null) {
      throw StateError('No supported terminal is available.');
    }
    if (modelName.trim().isEmpty || contextTokens < 1024) {
      throw StateError('Load a local model with at least 1024 context tokens.');
    }

    final profile =
        await Directory.systemTemp.createTemp('neuromesh-opencode-');
    final bridge = OpenAiServerService.forAgentModel(modelName);
    try {
      final workspace = await Directory('${profile.path}/workspace').create();
      final random = Random.secure();
      final key =
          base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
      await bridge.start(port: 0, apiKey: key);
      final environment = _sessionEnvironment(
        profile.path,
        key,
        '${bridge.localUrl}/v1',
        modelName,
        contextTokens,
      );
      final models = await _stdout(
          executable, ['models', _providerId, '--pure'],
          workingDirectory: workspace.path, environment: environment);
      if (models != _model || _hasManagedConfig) {
        throw StateError('OpenCode could not validate the NeuroMesh provider.');
      }

      final process = await Process.start(
        terminal.executable,
        [
          ...terminal.arguments,
          executable,
          workspace.path,
          '--model',
          _model,
          '--pure'
        ],
        workingDirectory: workspace.path,
        environment: environment,
        includeParentEnvironment: false,
      );
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      Future<void>? shutdown;
      Future<void> disconnect() => shutdown ??= bridge.stop();
      final closed = process.exitCode.whenComplete(() async {
        try {
          await disconnect();
        } finally {
          await profile.delete(recursive: true);
        }
      });
      return _OpenCodeTerminalSession(closed, disconnect);
    } catch (_) {
      try {
        await bridge.stop();
      } finally {
        await profile.delete(recursive: true);
      }
      rethrow;
    }
  }

  Map<String, String> _sessionEnvironment(
    String profile,
    String key,
    String baseUrl,
    String modelName,
    int contextTokens,
  ) {
    final home = _environment['HOME'];
    return {
      for (final variable in [
        'PATH',
        'LANG',
        'LC_ALL',
        'LC_CTYPE',
        'DISPLAY',
        'WAYLAND_DISPLAY',
        'XDG_RUNTIME_DIR',
        'DBUS_SESSION_BUS_ADDRESS',
        'XDG_SESSION_TYPE',
      ])
        if (_environment[variable] case final String value) variable: value,
      if (_environment['XAUTHORITY'] ??
              (home == null ? null : '$home/.Xauthority')
          case final String authority)
        'XAUTHORITY': authority,
      'HOME': profile,
      for (final folder in ['CONFIG', 'DATA', 'CACHE', 'STATE'])
        'XDG_${folder}_HOME': '$profile/${folder.toLowerCase()}',
      'OPENCODE_DISABLE_PROJECT_CONFIG': 'true',
      'OPENCODE_DISABLE_MODELS_FETCH': 'true',
      'OPENCODE_DISABLE_AUTOUPDATE': 'true',
      'OPENCODE_CONFIG_CONTENT': jsonEncode({
        'enabled_providers': [_providerId],
        'model': _model,
        'small_model': _model,
        'default_agent': 'neuromesh',
        'agent': {
          'neuromesh': {
            'description': 'Local NeuroMesh text chat',
            'mode': 'primary',
            'prompt':
                'You are the NeuroMesh local assistant. Answer the user directly.',
          },
          'title': {'disable': true},
        },
        'share': 'disabled',
        'autoupdate': false,
        'permission': {'*': 'deny'},
        'provider': {
          _providerId: {
            'name': 'NeuroMesh (local)',
            'npm': '@ai-sdk/openai-compatible',
            'env': [_keyName],
            'options': {'baseURL': baseUrl},
            'models': {
              OpenAiServerService.agentModelId: {
                'name': modelName,
                'tool_call': false,
                'attachment': false,
                'limit': {
                  'context': contextTokens,
                  'output': min(1024, contextTokens ~/ 4)
                },
              },
            },
          },
        },
      }),
      _keyName: key,
    };
  }
}

class _OpenCodeTerminalSession implements AgentTerminalSession {
  _OpenCodeTerminalSession(this.exitCode, this._disconnect);

  @override
  final Future<int> exitCode;
  final Future<void> Function() _disconnect;
  @override
  Future<void> disconnect() => _disconnect();
}
