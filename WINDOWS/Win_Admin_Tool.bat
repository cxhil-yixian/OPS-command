@echo off
chcp 65001 >nul
title Windows Admin Tool (OPS-command)

set "PS1=%~dp0Win_Admin_Tool.ps1"

rem The .ps1 is UTF-8; code page 65001 keeps the Chinese output readable.
rem Messages in this .bat stay ASCII on purpose: cmd parses the file with the
rem console code page, so non-ASCII here would break depending on the locale.

if not exist "%PS1%" (
    echo [ERROR] Cannot find "%PS1%"
    echo         Keep Win_Admin_Tool.bat and Win_Admin_Tool.ps1 in the same folder.
    pause
    exit /b 1
)

where powershell >nul 2>&1
if errorlevel 1 (
    echo [ERROR] powershell.exe not found in PATH.
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%"
exit /b 0
