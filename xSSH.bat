@echo off
::
:: xSSH File Transfer Client — Launcher
:: Author  : xsukax
:: License : GNU General Public License v3.0
::
:: Place this file in the same folder as xSSH.ps1
:: Double-click to launch. If the app fails to start, the error
:: message will be visible in this window before it closes.
::

title xSSH File Transfer

if not exist "%~dp0xSSH.ps1" (
    echo.
    echo  [ERROR] xSSH.ps1 was not found next to this launcher.
    echo  Expected: %~dp0xSSH.ps1
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0xSSH.ps1"

if %errorlevel% neq 0 (
    echo.
    echo  [ERROR] xSSH exited unexpectedly  ^(code: %errorlevel%^)
    echo  Check that Posh-SSH can be installed and that xSSH.ps1 is not blocked.
    echo.
    pause
)