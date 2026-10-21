; Inno Setup Script for Mpvson
; Generates a per-user, non-elevated installer with complete shell associations.

#define MyAppName "Mpvson"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "Mpvson"
#define MyAppURL "https://github.com/mpvson/mpvson"
#define MyAppExeName "mpvson.exe"
#define MyAppAssocProgID "Mpvson.AssocFile"
#define MyAppAssocName "Mpvson Media File"

[Setup]
AppId={{5E20E5F1-52B9-45B4-A82F-06EE7C4F1B3E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\build\windows\installer
OutputBaseFilename=MpvsonSetup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Filename: "{app}\{#MyAppExeName}"; Flags: nowait postinstall skipifsilent

[Registry]
; -----------------------------------------------------------------------------
; Registered Application Capabilities for Windows Default Programs
; -----------------------------------------------------------------------------
Root: HKCU; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: "Software\{#MyAppName}\Capabilities"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\{#MyAppName}"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "{#MyAppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "A modern desktop video player for Windows, powered by mpv."; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities"; ValueType: string; ValueName: "ApplicationIcon"; ValueData: """{app}\{#MyAppExeName}"",0"; Flags: uninsdeletekey

; Capabilities FileAssociations (from MediaCatalog)
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mp3"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".flac"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".wav"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".m4a"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".aac"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".ogg"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".oga"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".opus"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".wma"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".aiff"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".aif"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".ape"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mp4"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mkv"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".avi"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".webm"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mov"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".flv"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".wmv"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".m4v"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".ts"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".m2ts"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".vob"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".ogv"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\FileAssociations"; ValueType: string; ValueName: ".3gp"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey

; Capabilities MIMEAssociations (from MediaCatalog)
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/mpeg"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/flac"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/wav"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/mp4"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/aac"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/ogg"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/opus"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/x-ms-wma"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/x-aiff"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "audio/x-ape"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/mp4"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/x-matroska"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/x-msvideo"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/webm"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/quicktime"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/x-flv"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/x-ms-wmv"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/x-m4v"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/mp2t"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/x-ms-vob"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/ogg"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\{#MyAppName}\Capabilities\MIMEAssociations"; ValueType: string; ValueName: "video/3gpp"; ValueData: "{#MyAppAssocProgID}"; Flags: uninsdeletekey

; -----------------------------------------------------------------------------
; Applications Registration under HKCU\Software\Classes\Applications\mpvson.exe
; -----------------------------------------------------------------------------
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "{#MyAppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"",0"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\shell\enqueue"; ValueType: string; ValueName: ""; ValueData: "Add to queue"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\shell\enqueue"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#MyAppExeName}"",0"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\shell\enqueue\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" --enqueue ""%1"""; Flags: uninsdeletekey

; SupportedTypes for Applications\mpvson.exe
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".mp3"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".flac"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".wav"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".m4a"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".aac"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".ogg"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".oga"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".opus"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".wma"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".aiff"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".aif"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".ape"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".mp4"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".mkv"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".avi"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".webm"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".mov"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".flv"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".wmv"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".m4v"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".ts"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".m2ts"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".vob"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".ogv"; ValueData: ""; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#MyAppExeName}\SupportedTypes"; ValueType: string; ValueName: ".3gp"; ValueData: ""; Flags: uninsdeletekey

; -----------------------------------------------------------------------------
; ProgID definition: Mpvson.AssocFile
; -----------------------------------------------------------------------------
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}"; ValueType: string; ValueName: ""; ValueData: "{#MyAppAssocName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}"; ValueType: string; ValueName: "FriendlyTypeName"; ValueData: "{#MyAppAssocName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"",0"; Flags: uninsdeletekey

; Default action: Open with Mpvson
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}\shell"; ValueType: string; ValueName: ""; ValueData: "open"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}\shell\open"; ValueType: string; ValueName: ""; ValueData: "&Play with Mpvson"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}\shell\open"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#MyAppExeName}"",0"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey

; Context menu action: Add to queue
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}\shell\enqueue"; ValueType: string; ValueName: ""; ValueData: "Add to &queue"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}\shell\enqueue"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\{#MyAppExeName}"",0"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#MyAppAssocProgID}\shell\enqueue\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" --enqueue ""%1"""; Flags: uninsdeletekey

; -----------------------------------------------------------------------------
; File Associations (OpenWithProgids, OpenWithList) for all MediaCatalog formats
; -----------------------------------------------------------------------------
; Audio formats
#define RegisterExt(str Ext) \
  "Root: HKCU; Subkey: \"Software\\Classes\\" + Ext + "\\OpenWithProgids\"; ValueType: none; ValueName: \"{#MyAppAssocProgID}\"; Flags: uninsdeletevalue\n" + \
  "Root: HKCU; Subkey: \"Software\\Classes\\" + Ext + "\\OpenWithProgids\"; Flags: uninsdeletekeyifempty\n" + \
  "Root: HKCU; Subkey: \"Software\\Classes\\" + Ext + "\\OpenWithList\\{#MyAppExeName}\"; Flags: uninsdeletekey\n" + \
  "Root: HKCU; Subkey: \"Software\\Classes\\" + Ext + "\\OpenWithList\"; Flags: uninsdeletekeyifempty\n" + \
  "Root: HKCU; Subkey: \"Software\\Classes\\" + Ext + "\"; Flags: uninsdeletekeyifempty\n"

#pragma message "Configuring MediaCatalog file extensions..."
; Audio
Root: HKCU; Subkey: "Software\Classes\.mp3\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.mp3\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.mp3\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.mp3\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.mp3"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.flac\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.flac\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.flac\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.flac\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.flac"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.wav\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.wav\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.wav\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.wav\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.wav"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.m4a\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.m4a\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.m4a\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.m4a\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.m4a"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.aac\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.aac\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.aac\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.aac\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.aac"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.ogg\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.ogg\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.ogg\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.ogg\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.ogg"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.oga\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.oga\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.oga\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.oga\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.oga"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.opus\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.opus\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.opus\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.opus\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.opus"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.wma\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.wma\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.wma\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.wma\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.wma"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.aiff\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.aiff\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.aiff\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.aiff\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.aiff"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.aif\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.aif\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.aif\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.aif\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.aif"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.ape\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.ape\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.ape\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.ape\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.ape"; Flags: uninsdeletekeyifempty

; Video
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.mp4"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.mkv"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.avi"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.webm"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.mov"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.flv\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.flv\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.flv\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.flv\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.flv"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.wmv\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.wmv\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.wmv\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.wmv\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.wmv"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.m4v"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.ts"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.m2ts\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.m2ts\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.m2ts\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.m2ts\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.m2ts"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.vob\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.vob\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.vob\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.vob\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.vob"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.ogv\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.ogv\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.ogv\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.ogv\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.ogv"; Flags: uninsdeletekeyifempty

Root: HKCU; Subkey: "Software\Classes\.3gp\OpenWithProgids"; ValueType: none; ValueName: "{#MyAppAssocProgID}"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.3gp\OpenWithProgids"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.3gp\OpenWithList\{#MyAppExeName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.3gp\OpenWithList"; Flags: uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\Classes\.3gp"; Flags: uninsdeletekeyifempty
