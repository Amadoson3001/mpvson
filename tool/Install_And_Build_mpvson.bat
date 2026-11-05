@echo off
setlocal
title mpvson C++ Setup and Release Build

:: Check for admin rights and elevate if needed
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo ==============================================================
echo Installing Visual Studio C++ Build Tools for mpvson...
echo This will install the MSVC C++ compiler and Windows SDK.
echo Please keep this window open.
echo ==============================================================

if not exist "%TEMP%\vs_BuildTools.exe" (
    echo Downloading vs_BuildTools.exe...
    powershell -Command "Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile '$env:TEMP\vs_BuildTools.exe'"
)

echo Starting Visual Studio Installer with C++ Workload...
"%TEMP%\vs_BuildTools.exe" --passive --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended

echo.
echo ==============================================================
echo Toolchain Installed! Configuring and Building mpvson Release...
echo ==============================================================
cd /d "%~dp0\.."
call dart run tool/setup_windows_build.dart
call flutter build windows --release

echo.
echo ==============================================================
if exist "build\windows\x64\runner\Release\mpvson.exe" (
    echo Build SUCCESSFUL! Launching mpvson...
    start "" "build\windows\x64\runner\Release\mpvson.exe"
) else (
    echo Build failed. Please check the logs above.
)
echo ==============================================================
pause
