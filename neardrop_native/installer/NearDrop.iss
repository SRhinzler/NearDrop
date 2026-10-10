; NearDrop native Windows installer.
; Build the Flutter Windows release first:
;   flutter build windows --release

#define AppName "NearDrop"
#define AppVersion "1.0.0"
#define AppPublisher "NearDrop"
#define AppExeName "NearDrop.exe"
#define SourceDir "..\build\windows\x64\runner\Release"
#define IconFile "..\windows\runner\resources\app_icon.ico"

[Setup]
AppId={{B2BB7C88-30D1-4E0E-B9E4-1F5E6D3C7F31}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\NearDrop
DefaultGroupName=NearDrop
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
OutputDir=..\..\artifacts
OutputBaseFilename=NearDrop-Setup
SetupIconFile={#IconFile}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExeName}
ChangesAssociations=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\NearDrop"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\NearDrop"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch NearDrop"; Flags: nowait postinstall skipifsilent
