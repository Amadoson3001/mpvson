@echo off
setlocal enabledelayedexpansion

:: =============================================================================
:: Mpvson Portable Unregistration Helper
:: Cleanly unregisters ProgID, shell commands, capabilities, and file associations
:: in HKCU without affecting other installations.
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
    set "DART_ARGS=unregister --exe="%TARGET_EXE%""
    if "%FORCE%"=="1" set "DART_ARGS=!DART_ARGS! --force"
    dart run "%DART_TOOL%" !DART_ARGS!
    exit /b %ERRORLEVEL%
)

:: PowerShell native fallback (for standalone portable installations without Dart SDK)
echo [Mpvson] Unregistering associations via Windows PowerShell...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$target = '%TARGET_EXE%';" ^
    "$force = %FORCE% -eq 1;" ^
    "$progId = 'Mpvson.AssocFile';" ^
    "$appName = 'Mpvson';" ^
    "$exts = @('mp3','flac','wav','m4a','aac','ogg','oga','opus','wma','aiff','aif','ape','mp4','mkv','avi','webm','mov','flv','wmv','m4v','ts','m2ts','vob','ogv','3gp');" ^
    "$regCmd = (Get-ItemProperty -Path 'HKCU:\Software\Classes\Mpvson.AssocFile\shell\open\command' -ErrorAction SilentlyContinue).'(default)';" ^
    "if ($regCmd) { " ^
    "    if ($regCmd -match '\"?([^\"]+mpvson\.exe)\"?') { " ^
    "        $existing = $matches[1];" ^
    "        if ($existing -ne $target -and (Test-Path $existing) -and -not $force) { " ^
    "            Write-Warning \"Registration points to a different install: $existing`nUnregistration aborted to protect the other install. Use --force to override.\";" ^
    "            exit 0;" ^
    "        }" ^
    "    }" ^
    "}" ^
    "foreach ($ext in $exts) {" ^
    "    Remove-ItemProperty -Path (\"HKCU:\Software\Classes\.\" + $ext + \"\OpenWithProgids\") -Name $progId -ErrorAction SilentlyContinue;" ^
    "    Remove-Item -Path (\"HKCU:\Software\Classes\.\" + $ext + \"\OpenWithList\mpvson.exe\") -Recurse -Force -ErrorAction SilentlyContinue;" ^
    "};" ^
    "Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name $appName -ErrorAction SilentlyContinue;" ^
    "Remove-Item -Path 'HKCU:\Software\Mpvson' -Recurse -Force -ErrorAction SilentlyContinue;" ^
    "Remove-Item -Path 'HKCU:\Software\Classes\Applications\mpvson.exe' -Recurse -Force -ErrorAction SilentlyContinue;" ^
    "Remove-Item -Path 'HKCU:\Software\Classes\Mpvson.AssocFile' -Recurse -Force -ErrorAction SilentlyContinue;" ^
    "$code = '[DllImport(\"\"shell32.dll\"\")] public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);';" ^
    "Add-Type -TypeDefinition \"using System; using System.Runtime.InteropServices; public class ShellNotify { $code }\";" ^
    "[ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero);" ^
    "Write-Host 'Successfully unregistered Mpvson file associations.';"

exit /b %ERRORLEVEL%
