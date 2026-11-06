@echo off
setlocal
title Installing System Prerequisites for mpvson (One-Time)

echo ==============================================================
echo Installing Visual Studio C++ Build Tools and Windows SDK...
echo This installs system-wide for ALL users on this machine.
echo ==============================================================

if not exist "C:\Users\Public\vs_BuildTools.exe" (
    echo Downloading vs_BuildTools.exe to C:\Users\Public...
    curl.exe -L -o "C:\Users\Public\vs_BuildTools.exe" "https://aka.ms/vs/17/release/vs_BuildTools.exe"
)

echo Installing C++ compiler workload (MSVC, Windows SDK, CMake)...
"C:\Users\Public\vs_BuildTools.exe" --passive --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended

echo.
echo Adding Flutter to system PATH for all users...
powershell -Command "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';C:\src\flutter\bin;C:\src\mingw64\bin', 'Machine')" 2>nul

echo.
echo ==============================================================
echo System Prerequisites Installed Successfully!
echo ==============================================================
timeout /t 3
