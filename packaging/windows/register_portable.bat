@echo off
setlocal enabledelayedexpansion

:: =============================================================================
:: Mpvson Portable Registration Helper
:: Registers ProgID, shell commands, capabilities, and file associations in HKCU
:: without requiring administrator privileges or overwriting other installs.
:: =============================================================================

set "FORCE=0"
for %%A in (%*) do (
    if /I "%%A"=="--force" set "FORCE=1"
    if /I "%%A"=="/force" set "FORCE=1"
    if /I "%%A"=="-f" set "FORCE=1"
)

:: Locate mpvson.exe
set "TARGET_EXE="
if exist "%~dp0mpvson.exe" (
    set "TARGET_EXE=%~dp0mpvson.exe"
) else if exist "%~dp0..\..\build\windows\x64\runner\Release\mpvson.exe" (
    set "TARGET_EXE=%~dp0..\..\build\windows\x64\runner\Release\mpvson.exe"
) else if exist "%CD%\mpvson.exe" (
    set "TARGET_EXE=%CD%\mpvson.exe"
) else if exist "%CD%\build\windows\x64\runner\Release\mpvson.exe" (
    set "TARGET_EXE=%CD%\build\windows\x64\runner\Release\mpvson.exe"
)

if "%TARGET_EXE%"=="" (
    echo [ERROR] Could not locate mpvson.exe.
    echo Please run this script from the directory containing mpvson.exe.
    exit /b 1
)

:: Normalize path
for %%F in ("%TARGET_EXE%") do set "TARGET_EXE=%%~fF"

echo [Mpvson] Target executable: %TARGET_EXE%

:: Check for dart tool
set "DART_TOOL="
if exist "%~dp0..\..\tool\windows_associations.dart" (
    set "DART_TOOL=%~dp0..\..\tool\windows_associations.dart"
) else if exist "%~dp0tool\windows_associations.dart" (
    set "DART_TOOL=%~dp0tool\windows_associations.dart"
)

where dart >nul 2>nul
if %ERRORLEVEL% equ 0 if not "%DART_TOOL%"=="" (
    echo [Mpvson] Running via Dart association tool...
    set "DART_ARGS=register --exe="%TARGET_EXE%""
    if "%FORCE%"=="1" set "DART_ARGS=!DART_ARGS! --force"
    dart run "%DART_TOOL%" !DART_ARGS!
    exit /b %ERRORLEVEL%
)

:: PowerShell native fallback (for standalone portable installations without Dart SDK)
echo [Mpvson] Registering associations via Windows PowerShell...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$target = '%TARGET_EXE%';" ^
    "$force = %FORCE% -eq 1;" ^
    "$progId = 'Mpvson.AssocFile';" ^
    "$appName = 'Mpvson';" ^
    "$exts = @('mp3','flac','wav','m4a','aac','ogg','oga','opus','wma','aiff','aif','ape','mp4','mkv','avi','webm','mov','flv','wmv','m4v','ts','m2ts','vob','ogv','3gp');" ^
    "$mimes = @{'mp3'='audio/mpeg';'flac'='audio/flac';'wav'='audio/wav';'m4a'='audio/mp4';'aac'='audio/aac';'ogg'='audio/ogg';'oga'='audio/ogg';'opus'='audio/opus';'wma'='audio/x-ms-wma';'aiff'='audio/x-aiff';'aif'='audio/x-aiff';'ape'='audio/x-ape';'mp4'='video/mp4';'mkv'='video/x-matroska';'avi'='video/x-msvideo';'webm'='video/webm';'mov'='video/quicktime';'flv'='video/x-flv';'wmv'='video/x-ms-wmv';'m4v'='video/x-m4v';'ts'='video/mp2t';'m2ts'='video/mp2t';'vob'='video/x-ms-vob';'ogv'='video/ogg';'3gp'='video/3gpp'};" ^
    "$regCmd = (Get-ItemProperty -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell\open\command' -ErrorAction SilentlyContinue).'(default)';" ^
    "if ($regCmd) { " ^
    "    if ($regCmd -match '\"?([^\"]+mpvson\.exe)\"?') { " ^
    "        $existing = $matches[1];" ^
    "        if ($existing -ne $target -and (Test-Path $existing) -and -not $force) { " ^
    "            Write-Error \"Another Mpvson install is already registered at: $existing`nRegistration aborted to protect existing install. Use --force to override.\";" ^
    "            exit 2;" ^
    "        }" ^
    "    }" ^
    "}" ^
    "New-Item -Path 'HKCU:\Software\Classes\Mpvson.AssocFile' -Value 'Mpvson Media File' -Force | Out-Null;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\Classes\Mpvson.AssocFile' -Name 'FriendlyTypeName' -Value 'Mpvson Media File' -Force;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\DefaultIcon' -Value \"`\"$target`\",0\" -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell' -Value 'open' -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell\open' -Value '&Play with Mpvson' -Force | Out-Null;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell\open' -Name 'Icon' -Value \"`\"$target`\",0\" -Force;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell\open\command' -Value \"`\"$target`\" `\"%%1`\"\" -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell\enqueue' -Value 'Add to &queue' -Force | Out-Null;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell\enqueue' -Name 'Icon' -Value \"`\"$target`\",0\" -Force;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell\enqueue\command' -Value \"`\"$target`\" --enqueue `\"%%1`\"\" -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Applications\mpvson.exe' -Force | Out-Null;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\Classes\Applications\mpvson.exe' -Name 'FriendlyAppName' -Value 'Mpvson' -Force;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Applications\mpvson.exe\DefaultIcon' -Value \"`\"$target`\",0\" -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Applications\mpvson.exe\shell\open\command' -Value \"`\"$target`\" `\"%%1`\"\" -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Applications\mpvson.exe\shell\enqueue' -Value 'Add to queue' -Force | Out-Null;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\Classes\Applications\mpvson.exe\shell\enqueue' -Name 'Icon' -Value \"`\"$target`\",0\" -Force;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Applications\mpvson.exe\shell\enqueue\command' -Value \"`\"$target`\" --enqueue `\"%%1`\"\" -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\Classes\Applications\mpvson.exe\SupportedTypes' -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\RegisteredApplications' -Force | Out-Null;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name 'Mpvson' -Value 'Software\Mpvson\Capabilities' -Force;" ^
    "New-Item -Path 'HKCU:\Software\Mpvson\Capabilities' -Force | Out-Null;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\Mpvson\Capabilities' -Name 'ApplicationName' -Value 'Mpvson' -Force;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\Mpvson\Capabilities' -Name 'ApplicationDescription' -Value 'A modern desktop video player for Windows, powered by mpv.' -Force;" ^
    "Set-ItemProperty -Path 'HKCU:\Software\Mpvson\Capabilities' -Name 'ApplicationIcon' -Value \"`\"$target`\",0\" -Force;" ^
    "New-Item -Path 'HKCU:\Software\Mpvson\Capabilities\FileAssociations' -Force | Out-Null;" ^
    "New-Item -Path 'HKCU:\Software\Mpvson\Capabilities\MIMEAssociations' -Force | Out-Null;" ^
    "foreach ($ext in $exts) {" ^
    "    Set-ItemProperty -Path 'HKCU:\Software\Classes\Applications\mpvson.exe\SupportedTypes' -Name (\".\" + $ext) -Value '' -Force;" ^
    "    Set-ItemProperty -Path 'HKCU:\Software\Mpvson\Capabilities\FileAssociations' -Name (\".\" + $ext) -Value $progId -Force;" ^
    "    New-Item -Path (\"HKCU:\Software\Classes\.\" + $ext + \"\OpenWithProgids\") -Force | Out-Null;" ^
    "    Set-ItemProperty -Path (\"HKCU:\Software\Classes\.\" + $ext + \"\OpenWithProgids\") -Name $progId -Value '' -Force;" ^
    "    New-Item -Path (\"HKCU:\Software\Classes\.\" + $ext + \"\OpenWithList\mpvson.exe\") -Force | Out-Null;" ^
    "};" ^
    "foreach ($pair in $mimes.GetEnumerator()) {" ^
    "    Set-ItemProperty -Path 'HKCU:\Software\Mpvson\Capabilities\MIMEAssociations' -Name $pair.Value -Value $progId -Force;" ^
    "};" ^
    "$code = '[DllImport(\"\"shell32.dll\"\")] public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);';" ^
    "Add-Type -TypeDefinition \"using System; using System.Runtime.InteropServices; public class ShellNotify { $code }\";" ^
    "[ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero);" ^
    "Write-Host 'Successfully registered Mpvson portable shell associations.';"

exit /b %ERRORLEVEL%
