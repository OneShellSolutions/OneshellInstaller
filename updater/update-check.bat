@echo off
setlocal enabledelayedexpansion

:: ============================================
:: OneShell POS Auto-Updater
:: Runs via Windows Task Scheduler (every 6 hours)
:: Checks GitHub for new releases and silently
:: installs the latest version.
:: ============================================

set GITHUB_REPO=OneShellSolutions/oneshell-installer
set INSTALL_DIR=%~dp0..
set VERSION_FILE=%INSTALL_DIR%\version.txt
set LOG_FILE=%~dp0update.log

:: Timestamp for log
for /f "tokens=1-3 delims=/ " %%a in ('date /t') do set LOG_DATE=%%a-%%b-%%c
for /f "tokens=1-2 delims=: " %%a in ('time /t') do set LOG_TIME=%%a:%%b
set TIMESTAMP=%LOG_DATE% %LOG_TIME%

call :log "=========================================="
call :log "Update check started at %TIMESTAMP%"

:: Read current local version
set LOCAL_VERSION=0.0.0
if exist "%VERSION_FILE%" (
    set /p LOCAL_VERSION=<"%VERSION_FILE%"
)
call :log "Current version: %LOCAL_VERSION%"

:: Skip if last check was less than 5 hours ago (prevents rapid retries)
set LAST_CHECK_FILE=%~dp0last-check.txt
if exist "%LAST_CHECK_FILE%" (
    for /f "tokens=*" %%t in (%LAST_CHECK_FILE%) do set LAST_CHECK=%%t
    :: PowerShell time diff check - skip if < 5 hours
    for /f "tokens=*" %%r in ('powershell -NoProfile -Command "try { $last = [datetime]::Parse('%LAST_CHECK%'); if (([datetime]::Now - $last).TotalHours -lt 5) { 'SKIP' } else { 'OK' } } catch { 'OK' }"') do set CHECK_RESULT=%%r
    if "!CHECK_RESULT!"=="SKIP" (
        call :log "Skipping: last check was less than 5 hours ago."
        goto :done
    )
)

:: Query GitHub API for latest release
call :log "Checking GitHub for latest release..."
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/%GITHUB_REPO%/releases/latest' -TimeoutSec 15; Write-Output $r.tag_name } catch { Write-Output 'ERROR' }"') do set LATEST_TAG=%%i

:: Save check timestamp (even on error, to avoid hammering GitHub on rate limit)
powershell -NoProfile -Command "[datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')" > "%LAST_CHECK_FILE%"

if "%LATEST_TAG%"=="ERROR" (
    call :log "ERROR: Could not reach GitHub API. Aborting."
    goto :done
)
if "%LATEST_TAG%"=="" (
    call :log "No releases found on GitHub. Aborting."
    goto :done
)

:: Strip 'v' prefix if present (v1.0.3 -> 1.0.3)
set LATEST_VERSION=%LATEST_TAG%
if "%LATEST_VERSION:~0,1%"=="v" set LATEST_VERSION=%LATEST_VERSION:~1%

call :log "Latest version on GitHub: %LATEST_VERSION%"

:: Compare versions - if same, nothing to do
if "%LOCAL_VERSION%"=="%LATEST_VERSION%" (
    call :log "Already up to date. No action needed."
    goto :done
)

call :log "New version available: %LATEST_VERSION%. Downloading installer..."

:: Download the installer exe from GitHub release assets
set INSTALLER_NAME=OneShellPOS-Setup-%LATEST_VERSION%.exe
set DOWNLOAD_URL=https://github.com/%GITHUB_REPO%/releases/download/%LATEST_TAG%/%INSTALLER_NAME%
set DOWNLOAD_PATH=%~dp0%INSTALLER_NAME%

powershell -NoProfile -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%DOWNLOAD_PATH%' -TimeoutSec 600; Write-Output 'OK' } catch { Write-Output 'FAIL' }" > "%TEMP%\pos_dl_result.txt"
set /p DL_RESULT=<"%TEMP%\pos_dl_result.txt"
del "%TEMP%\pos_dl_result.txt" 2>nul

if not "%DL_RESULT%"=="OK" (
    call :log "ERROR: Download failed. Aborting update."
    if exist "%DOWNLOAD_PATH%" del "%DOWNLOAD_PATH%"
    goto :done
)

call :log "Download complete. Killing tray app before update..."

:: Kill tray app first (prevents file locking)
taskkill /F /IM OneShellTray.exe >nul 2>&1
timeout /t 3 /nobreak >nul

call :log "Running silent installer..."

:: Run the installer silently (/S = NSIS silent flag)
:: The installer will stop services, replace files, restart services
"%DOWNLOAD_PATH%" /S

call :log "Installer completed. Cleaning up..."

:: Clean up downloaded installer
if exist "%DOWNLOAD_PATH%" del "%DOWNLOAD_PATH%"

:: Verify the update
set NEW_VERSION=0.0.0
if exist "%VERSION_FILE%" (
    set /p NEW_VERSION=<"%VERSION_FILE%"
)

if "%NEW_VERSION%"=="%LATEST_VERSION%" (
    call :log "SUCCESS: Updated from %LOCAL_VERSION% to %NEW_VERSION%"
) else (
    call :log "WARNING: Version file shows %NEW_VERSION%, expected %LATEST_VERSION%"
)

:done
call :log "Update check finished."
call :log ""
goto :eof

:log
echo %~1 >> "%LOG_FILE%"
goto :eof
