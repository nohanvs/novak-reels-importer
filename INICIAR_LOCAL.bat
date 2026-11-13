@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-local.ps1"
if errorlevel 1 (
  echo.
  echo O atualizador/executor foi encerrado com erro. Veja a mensagem acima.
  pause
)
endlocal
