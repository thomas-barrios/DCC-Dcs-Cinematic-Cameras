@echo off
setlocal enabledelayedexpansion
title DCC-Dcs-Cinematic-Cameras (by Harpia) - Install

:: Re-launch elevated (installing the Interception driver requires admin).
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
echo ============================================================
echo  DCC-Dcs-Cinematic-Cameras (by Harpia) setup
echo ============================================================
echo.

:: --- 1. AutoHotkey v2 ---------------------------------------------------
set "AHK_EXE="
if exist "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe" set "AHK_EXE=%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
if not defined AHK_EXE if exist "%ProgramFiles%\AutoHotkey\AutoHotkey64.exe" set "AHK_EXE=%ProgramFiles%\AutoHotkey\AutoHotkey64.exe"
if not defined AHK_EXE if exist "%ProgramFiles(x86)%\AutoHotkey\v2\AutoHotkey64.exe" set "AHK_EXE=%ProgramFiles(x86)%\AutoHotkey\v2\AutoHotkey64.exe"
where AutoHotkey64.exe >nul 2>&1 && if not defined AHK_EXE set "AHK_EXE=found-on-path"

if defined AHK_EXE (
    echo [OK] AutoHotkey v2 found.
) else (
    echo [MISSING] AutoHotkey v2 was not found on this machine.
    echo Opening the download page - install it, then re-run this script.
    start "" "https://www.autohotkey.com/"
    pause
    exit /b 1
)
echo.

:: --- 2. Interception driver ---------------------------------------------
echo [2/2] Installing the Interception driver.
echo       This requires a REBOOT afterward - that is normal for this driver.
echo.
"%~dp0install-interception.exe"
echo.
echo [OK] Interception installer finished. Reboot before first use if prompted.
echo.

echo ============================================================
echo  Setup complete. Reboot if the driver installer asked you to,
echo  then run CameraController.ahk. On first launch it will prompt
echo  you to press a key on your keyboard to auto-detect it.
echo ============================================================
pause
