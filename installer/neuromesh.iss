; Windows installer for NeuroMesh AI (built in CI with Inno Setup).
; Defines passed on the command line: /DAppVersion=1.0.35 /DSourceDir=<Release folder> /DOutDir=<dir>
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutDir
  #define OutDir "."
#endif

[Setup]
AppId={{6B1F8E2A-4C7D-4E55-9A10-3F5D2C7B8E01}
AppName=NeuroMesh AI
AppVersion={#AppVersion}
AppPublisher=NeuroMesh
DefaultDirName={autopf}\NeuroMesh AI
DefaultGroupName=NeuroMesh AI
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutDir}
OutputBaseFilename=NeuroMesh-AI-Setup-v{#AppVersion}-x64
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\neuromesh_ai.exe
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\NeuroMesh AI"; Filename: "{app}\neuromesh_ai.exe"
Name: "{group}\Uninstall NeuroMesh AI"; Filename: "{uninstallexe}"
Name: "{autodesktop}\NeuroMesh AI"; Filename: "{app}\neuromesh_ai.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\neuromesh_ai.exe"; Description: "Launch NeuroMesh AI"; Flags: nowait postinstall skipifsilent
