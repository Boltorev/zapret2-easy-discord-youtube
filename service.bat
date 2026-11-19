@echo off
setlocal
title Zapret2 Easy
cd /d "%~dp0"

rem ---------------------------------------------------------------
rem  Zapret2 Easy launcher.
rem  ASCII only on purpose: batch files are read in the OEM codepage,
rem  and any non-ASCII byte here breaks the parser. All Russian text
rem  lives in PowerShell (UTF-8 with BOM).
rem  No chcp: encoding is configured inside Common.ps1 via .NET.
rem ---------------------------------------------------------------

net session >nul 2>&1
if not errorlevel 1 goto run

echo.
echo  Administrator rights are required.
echo  Requesting elevation...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
if errorlevel 1 (
    echo.
    echo  Elevation failed. Right-click service.bat and choose
    echo  "Run as administrator".
    echo.
    pause
)
exit /b 0

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0core\Menu.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo  Menu exited with code %RC%.
    pause
)
endlocal
exit /b %RC%
