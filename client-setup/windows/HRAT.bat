@echo off
chcp 65001 >nul
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT_DIR%klient.ps1"
if errorlevel 1 (
    echo.
    echo [CHYBA] Spusteni grafickeho klienta selhalo. Zkousim spustit s viditelnou konzoli pro diagnostiku...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_DIR%klient.ps1"
    pause
)
