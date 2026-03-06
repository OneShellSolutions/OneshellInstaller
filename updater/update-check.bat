@echo off
setlocal enabledelayedexpansion

:: ============================================
:: OneShell POS Auto-Updater
:: Runs via Windows Task Scheduler (every 6 hours)
:: Downloads from PUBLIC repo (no auth needed)
:: ============================================

set GITHUB_REPO=OneShellSolutions/OneshellInstallerExe
set INSTALL_DIR=%~dp0..
set VERSION_FILE=%INSTALL_DIR%\version.txt
set LOG_FILE=%~dp0update.log
set LOCK_FILE=%~dp0update.lock
set LAST_CHECK_FILE=%~dp0last-check.txt
set FAIL_COUNT_FILE=%~dp0fail-count.txt

:: Timestamp for log
for /f "tokens=*" %%d in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'"') do set TIMESTAMP=%%d

call :log "=========================================="
call :log "Update check started at %TIMESTAMP%"

:: ============================================
:: MUTEX: prevent concurrent updates
:: ============================================
if exist "%LOCK_FILE%" (
    :: Check if lock is stale (older than 30 minutes)
    for /f "tokens=*" %%r in ('powershell -NoProfile -Command "try { $lock = Get-Item '%LOCK_FILE%'; if (([datetime]::Now - $lock.LastWriteTime).TotalMinutes -gt 30) { 'STALE' } else { 'ACTIVE' } } catch { 'STALE' }"') do set LOCK_STATUS=%%r
    if "!LOCK_STATUS!"=="ACTIVE" (
        call :log "Another update is in progress (lock file exists). Aborting."
        goto :done
    ) else (
        call :log "Removing stale lock file."
        del "%LOCK_FILE%" 2>nul
    )
)

:: ============================================
:: THROTTLE: skip if checked recently
:: ============================================
if exist "%LAST_CHECK_FILE%" (
    for /f "tokens=*" %%t in (%LAST_CHECK_FILE%) do set LAST_CHECK=%%t
    for /f "tokens=*" %%r in ('powershell -NoProfile -Command "try { $last = [datetime]::Parse('!LAST_CHECK!'); if (([datetime]::Now - $last).TotalHours -lt 5) { 'SKIP' } else { 'OK' } } catch { 'OK' }"') do set CHECK_RESULT=%%r
    if "!CHECK_RESULT!"=="SKIP" (
        call :log "Skipping: last check was less than 5 hours ago."
        goto :done
    )
)

:: ============================================
:: FAIL LIMIT: stop retrying after 3 consecutive failures
:: ============================================
set FAIL_COUNT=0
if exist "%FAIL_COUNT_FILE%" (
    set /p FAIL_COUNT=<"%FAIL_COUNT_FILE%"
)
if %FAIL_COUNT% GEQ 3 (
    call :log "Skipping: %FAIL_COUNT% consecutive failures. Resetting after 24h."
    for /f "tokens=*" %%r in ('powershell -NoProfile -Command "try { $f = Get-Item '%FAIL_COUNT_FILE%'; if (([datetime]::Now - $f.LastWriteTime).TotalHours -gt 24) { 'RESET' } else { 'WAIT' } } catch { 'RESET' }"') do set FAIL_RESET=%%r
    if "!FAIL_RESET!"=="RESET" (
        call :log "24h passed since last failure, resetting counter."
        echo 0 > "%FAIL_COUNT_FILE%"
    ) else (
        goto :done
    )
)

:: Read current local version
set LOCAL_VERSION=0.0.0
if exist "%VERSION_FILE%" (
    set /p LOCAL_VERSION=<"%VERSION_FILE%"
)
call :log "Current version: %LOCAL_VERSION%"

:: ============================================
:: CHECK: Query GitHub API (public repo, no auth)
:: ============================================
call :log "Checking GitHub for latest release..."
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/%GITHUB_REPO%/releases/latest' -TimeoutSec 15; Write-Output $r.tag_name } catch { Write-Output 'ERROR' }"') do set LATEST_TAG=%%i

:: Save check timestamp
powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'" > "%LAST_CHECK_FILE%"

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
    :: Reset fail counter on successful check
    echo 0 > "%FAIL_COUNT_FILE%"
    goto :done
)

:: ============================================
:: DOWNLOAD: Get installer from GitHub release
:: ============================================
call :log "New version available: %LATEST_VERSION%. Downloading installer..."

:: Create lock file
echo %TIMESTAMP% > "%LOCK_FILE%"

set INSTALLER_NAME=OneShellPOS-Setup-%LATEST_VERSION%.exe
set DOWNLOAD_URL=https://github.com/%GITHUB_REPO%/releases/download/%LATEST_TAG%/%INSTALLER_NAME%
set DOWNLOAD_PATH=%~dp0%INSTALLER_NAME%

:: Clean up any previous failed download
if exist "%DOWNLOAD_PATH%" del "%DOWNLOAD_PATH%"

powershell -NoProfile -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%DOWNLOAD_PATH%' -TimeoutSec 600; Write-Output 'OK' } catch { Write-Output 'FAIL' }" > "%TEMP%\pos_dl_result.txt"
set /p DL_RESULT=<"%TEMP%\pos_dl_result.txt"
del "%TEMP%\pos_dl_result.txt" 2>nul

if not "%DL_RESULT%"=="OK" (
    call :log "ERROR: Download failed. Aborting update."
    call :increment_fail
    if exist "%DOWNLOAD_PATH%" del "%DOWNLOAD_PATH%"
    goto :cleanup
)

:: Validate download size (must be >10MB to be a valid installer)
for /f "tokens=*" %%s in ('powershell -NoProfile -Command "if ((Get-Item '%DOWNLOAD_PATH%').Length -gt 10MB) { 'OK' } else { 'TOO_SMALL' }"') do set SIZE_CHECK=%%s
if not "%SIZE_CHECK%"=="OK" (
    call :log "ERROR: Downloaded file too small (corrupted/truncated). Aborting."
    call :increment_fail
    del "%DOWNLOAD_PATH%"
    goto :cleanup
)

call :log "Download complete (%INSTALLER_NAME%)."

:: ============================================
:: PRE-INSTALL: Kill tray app and wait for processes
:: ============================================
call :log "Stopping tray app..."
taskkill /F /IM OneShellTray.exe >nul 2>&1

:: Wait and verify tray is dead (poll, don't ping)
call :log "Waiting for processes to exit..."
for /L %%i in (1,1,10) do (
    powershell -NoProfile -Command "Start-Sleep -Seconds 1"
    tasklist /FI "IMAGENAME eq OneShellTray.exe" 2>nul | find /I "OneShellTray.exe" >nul 2>&1
    if errorlevel 1 goto :tray_dead
)
call :log "WARNING: Tray app may still be running."
:tray_dead

:: ============================================
:: INSTALL: Run silent installer
:: ============================================
call :log "Running silent installer..."

:: The installer will: stop services -> replace files -> start services -> launch tray
"%DOWNLOAD_PATH%" /S

:: Wait for installer to finish (poll for version file change)
call :log "Waiting for installer to complete..."
set INSTALL_WAIT=0
:wait_loop
if %INSTALL_WAIT% GEQ 300 (
    call :log "WARNING: Installer timeout after 5 minutes."
    goto :verify
)
powershell -NoProfile -Command "Start-Sleep -Seconds 5"
set /a INSTALL_WAIT+=5

:: Check if version file was updated
set NEW_VERSION=0.0.0
if exist "%VERSION_FILE%" (
    set /p NEW_VERSION=<"%VERSION_FILE%"
)
if "%NEW_VERSION%"=="%LATEST_VERSION%" goto :verify
goto :wait_loop

:: ============================================
:: VERIFY: Check installation succeeded
:: ============================================
:verify
call :log "Verifying installation..."

set NEW_VERSION=0.0.0
if exist "%VERSION_FILE%" (
    set /p NEW_VERSION=<"%VERSION_FILE%"
)

if "%NEW_VERSION%"=="%LATEST_VERSION%" (
    call :log "SUCCESS: Updated from %LOCAL_VERSION% to %NEW_VERSION%"
    :: Reset fail counter
    echo 0 > "%FAIL_COUNT_FILE%"

    :: Verify monitor is responding (wait up to 60 seconds)
    call :log "Waiting for Monitor service..."
    for /L %%i in (1,1,12) do (
        powershell -NoProfile -Command "Start-Sleep -Seconds 5"
        for /f "tokens=*" %%r in ('powershell -NoProfile -Command "try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:3005/api/ping' -TimeoutSec 3; Write-Output 'UP' } catch { Write-Output 'DOWN' }"') do set MONITOR_STATUS=%%r
        if "!MONITOR_STATUS!"=="UP" (
            call :log "Monitor is responding. Update complete."
            goto :cleanup
        )
    )
    call :log "WARNING: Monitor not responding after 60 seconds."
) else (
    call :log "FAILED: Version file shows %NEW_VERSION%, expected %LATEST_VERSION%"
    call :increment_fail
)

:: ============================================
:: CLEANUP
:: ============================================
:cleanup
:: Remove downloaded installer
if exist "%DOWNLOAD_PATH%" del "%DOWNLOAD_PATH%"
:: Remove lock
if exist "%LOCK_FILE%" del "%LOCK_FILE%"

:done
call :log "Update check finished."
call :log ""
goto :eof

:: ============================================
:: FUNCTIONS
:: ============================================
:log
echo %~1 >> "%LOG_FILE%"
goto :eof

:increment_fail
set /a FAIL_COUNT+=1
echo %FAIL_COUNT% > "%FAIL_COUNT_FILE%"
call :log "Failure count: %FAIL_COUNT%/3"
goto :eof
