@echo off
TITLE Service Desk Advanced (SDA)
COLOR 0B
CLS

echo =======================================================
echo  [SDA] SERVICE DESK ADVANCED
echo  Engineered for Enterprise IT
echo =======================================================
echo.
echo [i] Bootstrapping Micro-API Engine...

:: 1. Check for Administrator privileges
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [i] Administrator privileges confirmed.
    goto :RunPayload
) else (
    echo [i] Requesting Administrator privileges...
    goto :Elevate
)

:Elevate
:: 2. Trigger UAC prompt and relaunch THIS batch file as Admin
echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
"%temp%\getadmin.vbs"
del "%temp%\getadmin.vbs"
exit /B

:RunPayload
:: 3. We are now elevated. Force the working directory to the script's exact location.
cd /d "%~dp0"

if not exist "AppLogic.ps1" (
    COLOR 0C
    echo [!] FATAL ERROR: AppLogic.ps1 not found in %CD%
    pause
    exit /B
)

:: 4. Launch the console. 
:: We use -NoExit so if there is a typo in the script, the blue window stays open so you can read the error!
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "AppLogic.ps1"