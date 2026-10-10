@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-local.ps1"
echo.
echo O executor foi encerrado. Se apareceu erro, siga a mensagem acima.
pause
endlocal
