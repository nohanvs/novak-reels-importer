@echo off
setlocal EnableExtensions
cd /d "%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\auto-update-local.ps1"
if errorlevel 1 (
  echo.
  echo O atualizador/executor foi encerrado com erro. Veja a mensagem acima.
  pause
)
endlocal
