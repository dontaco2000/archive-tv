; Archive TV installer. Build: see _build\installer-notes.md
; ISCC ArchiveTV.iss [/DReleaseDir=...] [/DCrtDir=...]

#define AppName "Archive TV"
#define AppVersion "0.9.4"
#define AppExe "archive_tv_player.exe"
#ifndef ReleaseDir
  #define ReleaseDir "C:\src\at_rel\player\build\windows\x64\runner\Release"
#endif
#ifndef CrtDir
  #define CrtDir "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.CRT"
#endif

[Setup]
AppId={{BA544716-40F6-4CE1-8D4A-1C089ED036A1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Archive TV
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=ArchiveTV-Setup-{#AppVersion}
SetupIconFile=ArchiveTV.ico
UninstallDisplayIcon={app}\ArchiveTV.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; App-local VC++ runtime so it runs on a clean PC (Flutter does not bundle it).
Source: "{#CrtDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\msvcp140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\msvcp140_2.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "ArchiveTV.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\ArchiveTV.ico"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\ArchiveTV.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; User data (%APPDATA%\com.example\archive_tv_player) is never touched by the uninstaller.

[Code]
// The weather channel's WeatherStar page needs the WebView2 runtime (built into Windows 11 and
// most Windows 10). If it is missing, fetch Microsoft's bootstrapper and install it per-user.
// Any failure is ignored: the app then shows its native weather screens.
const WV2Key = '\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function HasWebView2(Root: Integer; Key: String): Boolean;
var V: String;
begin
  Result := RegQueryStringValue(Root, Key, 'pv', V) and (V <> '') and (V <> '0.0.0.0');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var RC: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  if HasWebView2(HKLM, 'SOFTWARE\WOW6432Node' + WV2Key) or HasWebView2(HKCU, 'Software' + WV2Key) then Exit;
  try
    DownloadTemporaryFile('https://go.microsoft.com/fwlink/p/?LinkId=2124703', 'MicrosoftEdgeWebview2Setup.exe', '', nil);
    Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, RC);
    Log(Format('WebView2 bootstrapper exit code %d', [RC]));
  except
    Log('WebView2 runtime not installed: ' + GetExceptionMessage);
  end;
end;
