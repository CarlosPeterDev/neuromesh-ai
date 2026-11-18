/// True for the normal release configuration used by the AAB and standalone
/// test APKs: no self-updater and no restricted Android permissions.
/// The optional Alpine root filesystem is downloaded only after installation
/// is requested; its native ARM64 launcher is included in Android releases.
const bool kPlayBuild = bool.fromEnvironment('PLAY_BUILD');

/// Legacy channel marker retained for compatibility with earlier builds.
const bool kProBuild = bool.fromEnvironment('PRO_BUILD');
