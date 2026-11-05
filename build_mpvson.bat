@echo off
setlocal enabledelayedexpansion
title mpvson Windows Build System

:: 1. Ensure Flutter & Dart are always available in PATH for this session
set "PATH=C:\src\flutter\bin;C:\src\mingw64\bin;%PATH%"

cd /d "%~dp0"

echo ==============================================================
echo                 mpvson Windows Build System
echo ==============================================================
echo User: %USERNAME%
echo Working Directory: %CD%
echo.

:: 2. Check for Flutter
where flutter >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Flutter SDK not found at C:\src\flutter\bin.
    echo Please ensure Flutter is installed at C:\src\flutter.
    pause
    exit /b 1
)

:: 3. Check for Visual Studio C++ Compiler
set "VS_INSTALLED=0"
if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" (
    for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
        if not "%%i"=="" set "VS_INSTALLED=1"
    )
)

if "!VS_INSTALLED!"=="0" (
    echo [NOTICE] Visual Studio C++ Toolchain is not installed yet.
    echo [NOTICE] A one-time administrator setup is required to install MSVC and Windows SDK.
    echo.
    echo Requesting Administrator permission for one-time installation...
    echo (Please click 'Yes' on the Windows prompt on your screen)
    echo.
    
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~dp0tool\install_system_prereqs.bat\"\"' -Verb RunAs -Wait"
    
    :: Re-check after installation
    if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" (
        for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
            if not "%%i"=="" set "VS_INSTALLED=1"
        )
    )
    
    if "!VS_INSTALLED!"=="0" (
        echo [ERROR] Visual Studio C++ Toolchain installation was cancelled or incomplete.
        echo Cannot proceed with Windows build without MSVC.
        pause
        exit /b 1
    )
)

:: 4. Configure Plugin Junctions (bypasses Windows Developer Mode)
echo [1/3] Configuring Flutter plugin junctions...
call dart run tool/setup_windows_build.dart
if %errorlevel% neq 0 (
    echo [ERROR] Failed to configure plugin junctions.
    pause
    exit /b 1
)

:: 5. Compile Native Windows Release
echo.
echo [2/3] Building native Windows release executable...
call flutter build windows --release
if %errorlevel% neq 0 (
    echo [ERROR] Build failed. Please inspect compiler errors above.
    pause
    exit /b 1
)

:: 6. Launch Application
echo.
echo [3/3] Build SUCCESSFUL!
if exist "build\windows\x64\runner\Release\mpvson.exe" (
    echo Executable: %CD%\build\windows\x64\runner\Release\mpvson.exe
    echo Launching mpvson...
    start "" "build\windows\x64\runner\Release\mpvson.exe"
) else (
    echo [WARNING] Executable not found at expected path.
)

echo ==============================================================
pause
