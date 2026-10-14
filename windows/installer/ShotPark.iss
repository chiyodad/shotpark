; ShotPark for Windows — per-user installer (no admin rights needed).
; Build on Windows with Inno Setup 6:
;   ISCC.exe /DAppVersion=1.2.3 /DSrcX64=..\out\app-x64 /DSrcArm64=..\out\app-arm64 ShotPark.iss
; The two folders are `dotnet publish --self-contained` outputs; only the one matching the PC is installed.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SrcX64
  #define SrcX64 "..\out\app-x64"
#endif
#ifndef SrcArm64
  #define SrcArm64 "..\out\app-arm64"
#endif
#ifndef OutDir
  #define OutDir "..\out"
#endif

[Setup]
AppId={{6F1B5E3A-2C4D-4E8B-9A57-5348504152CB}
AppName=ShotPark
AppVersion={#AppVersion}
AppVerName=ShotPark {#AppVersion}
AppPublisher=chiyodad
AppPublisherURL=https://shotpark.site/
AppSupportURL=https://github.com/chiyodad/shotpark/issues
AppUpdatesURL=https://shotpark.site/
AppCopyright=Copyright (c) chiyodad
VersionInfoVersion={#AppVersion}
VersionInfoDescription=ShotPark Setup
DefaultDirName={localappdata}\Programs\ShotPark
DefaultGroupName=ShotPark
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
MinVersion=10.0.17763
OutputDir={#OutDir}
OutputBaseFilename=ShotPark-Windows-Setup
SetupIconFile=..\src\ShotPark.Win\ShotPark.ico
UninstallDisplayIcon={app}\ShotPark.exe
UninstallDisplayName=ShotPark
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
LZMANumBlockThreads=4
; No AppMutex: it would only tell the user to quit the tray app by hand (and abort silent
; updates). Setup closes a running copy itself instead (Restart Manager + PrepareToInstall).
CloseApplications=force
RestartApplications=no

; Korean is an official Inno Setup translation since 6.5; a copy ships next to this script so
; the installer is Korean on Korean Windows even with an older compiler.
#define HasKorean 1

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\Korean.isl")
Name: "ko"; MessagesFile: "compiler:Languages\Korean.isl"
#else
Name: "ko"; MessagesFile: "Korean.isl"
#endif

[CustomMessages]
en.AutoStart=Start ShotPark when I sign in to Windows
#if HasKorean
ko.AutoStart=Windows에 로그인하면 ShotPark 자동 실행
#endif
en.DesktopIcon=Create a desktop shortcut
#if HasKorean
ko.DesktopIcon=바탕 화면에 바로 가기 만들기
#endif
en.Extra=Additional options:
#if HasKorean
ko.Extra=추가 옵션:
#endif
en.LaunchNow=Start ShotPark now
#if HasKorean
ko.LaunchNow=지금 ShotPark 실행
#endif

[Tasks]
Name: "autostart"; Description: "{cm:AutoStart}"; GroupDescription: "{cm:Extra}"
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:Extra}"; Flags: unchecked

[Files]
Source: "{#SrcX64}\*"; DestDir: "{app}"; Check: not IsArm64; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SrcArm64}\*"; DestDir: "{app}"; Check: IsArm64; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; files from an older version that no longer ship
Type: filesandordirs; Name: "{app}\*.dll"

[Icons]
Name: "{autoprograms}\ShotPark"; Filename: "{app}\ShotPark.exe"
Name: "{autodesktop}\ShotPark"; Filename: "{app}\ShotPark.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ShotPark"; ValueData: """{app}\ShotPark.exe"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\ShotPark.exe"; Description: "{cm:LaunchNow}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CloseRunningShotPark;
var
  Code: Integer;
begin
  { The tray app has no visible window to close; end it so its files can be replaced/removed. }
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM ShotPark.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Sleep(300);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CloseRunningShotPark;
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  CloseRunningShotPark;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { the app's own "start at sign-in" switch writes the same value; never leave it pointing at a removed exe }
  if CurUninstallStep = usPostUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'ShotPark');
end;
