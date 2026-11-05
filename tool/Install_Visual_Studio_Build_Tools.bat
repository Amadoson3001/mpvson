@echo off
setlocal
title Visual Studio C++ Build Tools Installer (System-Wide)

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

echo ==============================================================
echo Installing Visual Studio C++ Build Tools (System-Wide for All Users)...
echo Location: C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
echo This allows domain user a.2478 to build Windows apps with Flutter.
echo ==============================================================

if not exist "C:\Users\Public\vs_BuildTools.exe" (
    echo Downloading vs_BuildTools.exe to C:\Users\Public...
    curl.exe -L -o "C:\Users\Public\vs_BuildTools.exe" "https://aka.ms/vs/17/release/vs_BuildTools.exe"
)

echo Starting Visual Studio Installer with C++ Desktop Workload...
"C:\Users\Public\vs_BuildTools.exe" --passive --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended

echo.
echo ==============================================================
echo Installation Complete!
echo You can now close this window. Your main a.2478 session will compile the app.
echo ==============================================================
pause
