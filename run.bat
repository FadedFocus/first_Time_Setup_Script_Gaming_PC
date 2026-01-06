@echo off
setlocal

REM Always run from this script's directory
cd /d "%~dp0"

REM Self-elevate if not running as admin
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrative privileges...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

REM Run the PowerShell script
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DriverHelpers.ps1"

endlocal
