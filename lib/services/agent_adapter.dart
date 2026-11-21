/// Capabilities of the detected installation in NeuroMesh.
class AgentInstallation {
  const AgentInstallation({
    this.executable,
    this.version,
    this.terminalAvailable = false,
    this.compatible = false,
  });

  final String? executable;
  final String? version;
  final bool terminalAvailable;
  final bool compatible;
}

abstract interface class AgentTerminalSession {
  Future<int> get exitCode;

  /// Revokes this session's access to the NeuroMesh model.
  Future<void> disconnect();
}

abstract interface class AgentAdapter {
  String get name;
  Uri get installationGuide;
  Future<AgentInstallation> discover();
  Future<AgentTerminalSession> openTerminal({
    required AgentInstallation installation,
    required String modelName,
    required int contextTokens,
  });
}
