/// True for the Google Play build (AAB). That build has no self-updater, asks
/// for no restricted permissions and never downloads or runs code.
const bool kPlayBuild = bool.fromEnvironment('PLAY_BUILD');

/// True for the "Pro" APK that bundles the Linux sandbox (not for Play).
const bool kProBuild = bool.fromEnvironment('PRO_BUILD');
