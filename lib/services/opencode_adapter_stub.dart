import 'agent_adapter.dart';

bool get hasDesktopAgents => false;

AgentAdapter createOpenCodeAdapter() =>
    throw UnsupportedError('Desktop agents are unavailable.');
