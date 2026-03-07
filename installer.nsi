; OneShell POS - NSIS Installer Script
; Single .exe that installs EVERYTHING: runtimes + apps + services + monitor
;
; Build: makensis -DVERSION=1.0.0 -DBUNDLE_DIR=target/bundle installer.nsi
; Output: target/OneShellPOS-Setup-{VERSION}.exe

!include "MUI2.nsh"
!include "FileFunc.nsh"

; --- Configuration ---
Name "OneShell POS ${VERSION}"
OutFile "target/OneShellPOS-Setup-${VERSION}.exe"
InstallDir "$PROGRAMFILES\OneShellPOS"
RequestExecutionLevel admin
ShowInstDetails show

; --- Icon ---
!define MUI_ICON "${BUNDLE_DIR}\icon.ico"
!define MUI_UNICON "${BUNDLE_DIR}\icon.ico"

; --- Modern UI ---
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "OneShell POS ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "This will install OneShell POS on your computer.$\r$\n$\r$\nBundled components:$\r$\n  - Java Runtime (JRE 24)$\r$\n  - Node.js 20$\r$\n  - Python 3.11$\r$\n  - MongoDB 8.0$\r$\n  - NATS Server 2.10$\r$\n  - Nginx Web Server$\r$\n$\r$\nAll run as auto-start Windows Services with crash recovery."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; --- DumpLog: save installer detail log to file ---
!ifndef LVM_GETITEMCOUNT
  !define LVM_GETITEMCOUNT 0x1004
!endif
!ifndef LVM_GETITEMTEXTA
  !define LVM_GETITEMTEXTA 0x102D
!endif
Function DumpLog
    Exch $5
    Push $0
    Push $1
    Push $2
    Push $3
    Push $4
    Push $6
    FindWindow $0 "#32770" "" $HWNDPARENT
    GetDlgItem $0 $0 1016
    StrCmp $0 0 exit
    FileOpen $5 $5 w
    StrCmp $5 "" exit
        SendMessage $0 ${LVM_GETITEMCOUNT} 0 0 $6
        System::Alloc ${NSIS_MAX_STRLEN}
        Pop $3
        StrCpy $2 0
        System::Call "*(i, i, i, i, i, i, i, i, i) i \
            (0, 0, 0, 0, 0, r3, ${NSIS_MAX_STRLEN}) .r1"
        loop: StrCmp $2 $6 done
            System::Call "User32::SendMessage(i, i, i, i) i \
                ($0, ${LVM_GETITEMTEXTA}, $2, r1)"
            System::Call "*$3(&t${NSIS_MAX_STRLEN} .r4)"
            FileWrite $5 "$4$\r$\n"
            IntOp $2 $2 + 1
            Goto loop
        done:
            FileClose $5
            System::Free $1
            System::Free $3
    exit:
        Pop $6
        Pop $4
        Pop $3
        Pop $2
        Pop $1
        Pop $0
        Exch $5
FunctionEnd

; --- Installer ---
Section "Install"
    SetOutPath "$INSTDIR"

    ; ======= Stop existing services (reverse dependency order) =======
    DetailPrint "Stopping services..."

    ; Stop application services first (they depend on infra)
    nsExec::ExecToLog 'net stop OneShellMonitor'
    nsExec::ExecToLog 'net stop OneShellFrontend'
    nsExec::ExecToLog 'net stop OneShellPosPythonBackend'
    nsExec::ExecToLog 'net stop OneShellPosNodeBackend'
    nsExec::ExecToLog 'net stop OneShellPosBackend'
    Sleep 5000

    ; Stop infrastructure (NATS before MongoDB since NATS depends on MongoDB)
    nsExec::ExecToLog 'net stop OneShellNATS'
    Sleep 2000

    ; Gracefully shut down MongoDB (net stop tells WinSW to send shutdown signal)
    nsExec::ExecToLog 'net stop OneShellMongoDB'
    ; Give MongoDB time to flush and close cleanly
    Sleep 5000

    ; ======= Kill tray app =======
    nsExec::ExecToLog 'taskkill /F /IM OneShellTray.exe'

    ; ======= Kill lingering processes (targeted, not broad) =======
    DetailPrint "Cleaning up processes..."

    ; Kill our specific monitor exe (not all node processes)
    nsExec::ExecToLog 'taskkill /F /IM OneShellMonitor.exe'

    ; Kill nginx (only ours - running from our install dir)
    nsExec::ExecToLog 'taskkill /F /IM nginx.exe'

    ; Kill nats-server
    nsExec::ExecToLog 'taskkill /F /IM nats-server.exe'

    ; Kill Java backend: find java.exe running posbackend.jar (works on Win 10/11)
    ; Use PowerShell instead of deprecated wmic
    nsExec::ExecToLog 'powershell -NoProfile -Command "Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like \"*posbackend*\" } | Stop-Process -Force -ErrorAction SilentlyContinue"'

    ; Kill Python backend: find python.exe running our PosPythonBackend
    nsExec::ExecToLog 'powershell -NoProfile -Command "Get-Process python* -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like \"*PosPythonBackend*\" } | Stop-Process -Force -ErrorAction SilentlyContinue"'

    ; Fallback: kill processes holding our ports (8090=java, 3001=node, 5200=python)
    nsExec::ExecToLog 'powershell -NoProfile -Command "foreach ($p in 8090,3001,5200) { $c = Get-NetTCPConnection -LocalPort $p -ErrorAction SilentlyContinue; if ($c) { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } }"'

    ; Last resort: force kill mongod if still running
    nsExec::ExecToLog 'taskkill /F /IM mongod.exe'

    ; Wait for all handles to release
    Sleep 3000

    ; ======= Verify critical processes are dead =======
    DetailPrint "Verifying processes stopped..."
    nsExec::ExecToLog 'powershell -NoProfile -Command "$procs = @(\"mongod\",\"nats-server\",\"nginx\",\"OneShellMonitor\",\"OneShellTray\"); $running = Get-Process -Name $procs -ErrorAction SilentlyContinue; if ($running) { Write-Output \"WARNING: Still running: $($running.Name -join \", \")\"; Start-Sleep 5 } else { Write-Output \"All processes stopped.\" }"'

    ; ======= Uninstall old services =======
    DetailPrint "Removing old service registrations..."
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMonitorService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellFrontendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosPythonBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosNodeBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellNATSService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMongoDBService.exe" uninstall'
    Sleep 2000

    ; ======= Extract everything =======
    DetailPrint "Installing files..."

    SetOutPath "$INSTDIR"
    File "${BUNDLE_DIR}/icon.ico"

    ; Java JRE
    DetailPrint "Installing Java Runtime..."
    SetOutPath "$INSTDIR\jre"
    File /r "${BUNDLE_DIR}/jre/*"

    ; Node.js
    DetailPrint "Installing Node.js..."
    SetOutPath "$INSTDIR\node"
    File /r "${BUNDLE_DIR}/node/*"

    ; Python (with pre-downloaded wheels for offline pip install)
    DetailPrint "Installing Python..."
    SetOutPath "$INSTDIR\python"
    File /r "${BUNDLE_DIR}/python/*"

    ; MongoDB
    DetailPrint "Installing MongoDB..."
    SetOutPath "$INSTDIR\mongodb\bin"
    File /r "${BUNDLE_DIR}/mongodb/bin/*"

    ; NATS
    DetailPrint "Installing NATS Server..."
    SetOutPath "$INSTDIR\nats"
    File "${BUNDLE_DIR}/nats/nats-server.exe"

    ; Nginx
    DetailPrint "Installing Nginx..."
    SetOutPath "$INSTDIR\nginx"
    File /r "${BUNDLE_DIR}/nginx/*"

    ; Monitor (Node.js packaged exe + public/)
    DetailPrint "Installing Monitor Dashboard..."
    SetOutPath "$INSTDIR\monitor"
    File "${BUNDLE_DIR}/monitor/OneShellMonitor.exe"
    SetOutPath "$INSTDIR\monitor\public"
    File /r "${BUNDLE_DIR}/monitor/public/*"

    ; Tray App
    DetailPrint "Installing Tray App..."
    SetOutPath "$INSTDIR\tray"
    File /nonfatal "${BUNDLE_DIR}/tray/OneShellTray.exe"
    File /nonfatal "${BUNDLE_DIR}/tray/tray.js"

    ; ======= Application artifacts =======
    DetailPrint "Installing POS applications..."

    SetOutPath "$INSTDIR\apps\posbackend"
    File "${BUNDLE_DIR}/apps/posbackend/posbackend.jar"

    SetOutPath "$INSTDIR\apps\posNodeBackend"
    File /r "${BUNDLE_DIR}/apps/posNodeBackend/*"

    SetOutPath "$INSTDIR\apps\posFrontend"
    File /r "${BUNDLE_DIR}/apps/posFrontend/*"

    SetOutPath "$INSTDIR\apps\PosPythonBackend"
    File /r "${BUNDLE_DIR}/apps/PosPythonBackend/*"

    ; ======= Configs =======
    SetOutPath "$INSTDIR\config"
    File "${BUNDLE_DIR}/config/nats-server.conf"
    File "${BUNDLE_DIR}/config/nginx.conf"

    ; ======= WinSW Service wrappers =======
    SetOutPath "$INSTDIR\services"
    File "${BUNDLE_DIR}/services/OneShellMongoDBService.exe"
    File "${BUNDLE_DIR}/services/OneShellMongoDBService.xml"
    File "${BUNDLE_DIR}/services/OneShellNATSService.exe"
    File "${BUNDLE_DIR}/services/OneShellNATSService.xml"
    File "${BUNDLE_DIR}/services/OneShellPosBackendService.exe"
    File "${BUNDLE_DIR}/services/OneShellPosBackendService.xml"
    File "${BUNDLE_DIR}/services/OneShellPosNodeBackendService.exe"
    File "${BUNDLE_DIR}/services/OneShellPosNodeBackendService.xml"
    File "${BUNDLE_DIR}/services/OneShellPosPythonBackendService.exe"
    File "${BUNDLE_DIR}/services/OneShellPosPythonBackendService.xml"
    File "${BUNDLE_DIR}/services/OneShellFrontendService.exe"
    File "${BUNDLE_DIR}/services/OneShellFrontendService.xml"
    File "${BUNDLE_DIR}/services/OneShellMonitorService.exe"
    File "${BUNDLE_DIR}/services/OneShellMonitorService.xml"

    ; ======= Updater =======
    SetOutPath "$INSTDIR\updater"
    File "${BUNDLE_DIR}/updater/update-check.bat"

    ; ======= Visual C++ Redistributable (required by MongoDB 8.0) =======
    SetOutPath "$INSTDIR"
    File /nonfatal "${BUNDLE_DIR}/vc_redist.x64.exe"

    ; ======= Print utility =======
    SetOutPath "$INSTDIR"
    File /nonfatal "${BUNDLE_DIR}/oneshell-print-util-win.exe"

    ; ======= Management scripts =======
    File "${BUNDLE_DIR}/Start-OneShell.bat"
    File "${BUNDLE_DIR}/Stop-OneShell.bat"
    File "${BUNDLE_DIR}/Status-OneShell.bat"

    ; ======= Data directories (survive upgrades) =======
    CreateDirectory "$INSTDIR\data"
    CreateDirectory "$INSTDIR\data\mongodb"
    CreateDirectory "$INSTDIR\data\nats"
    CreateDirectory "$INSTDIR\logs"
    CreateDirectory "$INSTDIR\logs\mongodb"
    CreateDirectory "$INSTDIR\logs\nats"
    CreateDirectory "$INSTDIR\logs\posbackend"
    CreateDirectory "$INSTDIR\logs\posNodeBackend"
    CreateDirectory "$INSTDIR\logs\PosPythonBackend"
    CreateDirectory "$INSTDIR\logs\nginx"
    CreateDirectory "$INSTDIR\logs\monitor"
    ; Nginx needs these temp/log dirs (empty in distribution, NSIS File /r skips empty dirs)
    CreateDirectory "$INSTDIR\nginx\logs"
    CreateDirectory "$INSTDIR\nginx\temp"
    CreateDirectory "$INSTDIR\nginx\temp\client_body_temp"
    CreateDirectory "$INSTDIR\nginx\temp\proxy_temp"
    CreateDirectory "$INSTDIR\nginx\temp\fastcgi_temp"
    CreateDirectory "$INSTDIR\nginx\temp\uwsgi_temp"
    CreateDirectory "$INSTDIR\nginx\temp\scgi_temp"

    ; ======= Install Python pip + deps (OFFLINE from bundled wheels) =======
    DetailPrint "Installing Python dependencies (offline)..."
    IfFileExists "$INSTDIR\python\wheels\pip*" 0 +3
        ; Install pip itself from bundled wheel (no internet needed)
        nsExec::ExecToLog '"$INSTDIR\python\python.exe" "$INSTDIR\python\get-pip.py" --no-index --find-links "$INSTDIR\python\wheels" --quiet'
        ; Install all app dependencies from bundled wheels (no internet needed)
        nsExec::ExecToLog '"$INSTDIR\python\python.exe" -m pip install --no-index --find-links "$INSTDIR\python\wheels" -r "$INSTDIR\apps\PosPythonBackend\requirements.txt" --quiet'

    ; Node.js: node_modules pre-installed in bundle, nothing to do on customer machine

    ; ======= Version file =======
    SetOutPath "$INSTDIR"
    FileOpen $0 "$INSTDIR\version.txt" w
    FileWrite $0 "${VERSION}"
    FileClose $0

    ; ======= Register Windows Services =======
    DetailPrint "Registering services..."
    SetOutPath "$INSTDIR\services"
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMongoDBService.exe" install'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellNATSService.exe" install'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosBackendService.exe" install'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosNodeBackendService.exe" install'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosPythonBackendService.exe" install'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellFrontendService.exe" install'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMonitorService.exe" install'

    ; ======= Install Visual C++ Redistributable (MongoDB 8.0 requires it) =======
    IfFileExists "$INSTDIR\vc_redist.x64.exe" 0 +3
    DetailPrint "Installing Visual C++ Redistributable..."
    nsExec::ExecToLog '"$INSTDIR\vc_redist.x64.exe" /install /quiet /norestart'

    ; ======= Start services (dependency order with verification) =======

    ; Infrastructure first
    DetailPrint "Starting MongoDB..."
    nsExec::ExecToLog 'net start OneShellMongoDB'
    ; Wait for MongoDB to accept connections (poll port 27017)
    nsExec::ExecToLog 'powershell -NoProfile -Command "for ($i=0; $i -lt 30; $i++) { try { $tcp = New-Object Net.Sockets.TcpClient; $tcp.Connect(\"127.0.0.1\", 27017); $tcp.Close(); Write-Output \"MongoDB ready.\"; break } catch { Start-Sleep 1 } }"'

    DetailPrint "Starting NATS..."
    nsExec::ExecToLog 'net start OneShellNATS'
    ; Wait for NATS health endpoint
    nsExec::ExecToLog 'powershell -NoProfile -Command "for ($i=0; $i -lt 15; $i++) { try { $r = Invoke-WebRequest -Uri \"http://127.0.0.1:8222/healthz\" -TimeoutSec 2 -UseBasicParsing; Write-Output \"NATS ready.\"; break } catch { Start-Sleep 1 } }"'

    ; Application services
    DetailPrint "Starting POS Backend..."
    nsExec::ExecToLog 'net start OneShellPosBackend'
    ; Backend takes longer to start (Spring Boot), wait for actuator
    nsExec::ExecToLog 'powershell -NoProfile -Command "for ($i=0; $i -lt 60; $i++) { try { $r = Invoke-WebRequest -Uri \"http://127.0.0.1:8090/actuator/health\" -TimeoutSec 2 -UseBasicParsing; Write-Output \"POS Backend ready.\"; break } catch { Start-Sleep 2 } }"'

    DetailPrint "Starting Node Backend..."
    nsExec::ExecToLog 'net start OneShellPosNodeBackend'

    DetailPrint "Starting Python Backend..."
    nsExec::ExecToLog 'net start OneShellPosPythonBackend'

    DetailPrint "Starting Frontend..."
    nsExec::ExecToLog 'net start OneShellFrontend'

    DetailPrint "Starting Monitor..."
    nsExec::ExecToLog 'net start OneShellMonitor'

    ; ======= Auto-update scheduled task (every 6 hours) =======
    DetailPrint "Creating auto-update task..."
    nsExec::ExecToLog 'schtasks /Create /SC HOURLY /MO 6 /TN "OneShellPOS-AutoUpdate" /TR "\"$INSTDIR\updater\update-check.bat\"" /F /RL HIGHEST'

    ; ======= Firewall rules =======
    DetailPrint "Configuring firewall..."
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="OneShell HTTP" dir=in action=allow protocol=TCP localport=80'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="OneShell Backend" dir=in action=allow protocol=TCP localport=8090'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="OneShell Monitor" dir=in action=allow protocol=TCP localport=3005'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="OneShell MongoDB" dir=in action=allow protocol=TCP localport=27017'
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="OneShell NATS" dir=in action=allow protocol=TCP localport=4222'

    ; ======= Uninstaller + Registry =======
    WriteUninstaller "$INSTDIR\Uninstall.exe"

    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "DisplayName" "OneShell POS ${VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "DisplayIcon" '"$INSTDIR\icon.ico"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "InstallLocation" "$INSTDIR"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "Publisher" "OneShell Solutions"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "DisplayVersion" "${VERSION}"
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "NoRepair" 1
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS" "EstimatedSize" $0

    ; ======= Desktop + Start Menu shortcuts =======
    CreateShortcut "$DESKTOP\OneShell POS.lnk" "http://localhost" "" "$INSTDIR\icon.ico" 0
    CreateShortcut "$DESKTOP\OneShell Monitor.lnk" "http://localhost:3005" "" "$INSTDIR\icon.ico" 0
    CreateDirectory "$SMPROGRAMS\OneShell POS"
    CreateShortcut "$SMPROGRAMS\OneShell POS\OneShell POS.lnk" "http://localhost" "" "$INSTDIR\icon.ico" 0
    CreateShortcut "$SMPROGRAMS\OneShell POS\Monitor Dashboard.lnk" "http://localhost:3005" "" "$INSTDIR\icon.ico" 0
    CreateShortcut "$SMPROGRAMS\OneShell POS\Start Services.lnk" "$INSTDIR\Start-OneShell.bat" "" "$INSTDIR\icon.ico" 0
    CreateShortcut "$SMPROGRAMS\OneShell POS\Stop Services.lnk" "$INSTDIR\Stop-OneShell.bat" "" "$INSTDIR\icon.ico" 0
    CreateShortcut "$SMPROGRAMS\OneShell POS\Uninstall.lnk" "$INSTDIR\Uninstall.exe" "" "$INSTDIR\icon.ico" 0

    ; ======= Tray app auto-start on login =======
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Run" "OneShellTray" '"$INSTDIR\tray\OneShellTray.exe"'

    ; Launch tray app (de-elevate for silent/service context)
    IfSilent 0 +3
    ; Silent mode: use cmd /c start to de-elevate from SYSTEM context
    IfFileExists "$INSTDIR\tray\OneShellTray.exe" 0 +2
    nsExec::Exec 'cmd /c start "" "$INSTDIR\tray\OneShellTray.exe"'
    Goto +3
    ; Interactive mode: launch directly and open browser
    IfFileExists "$INSTDIR\tray\OneShellTray.exe" 0 +2
    Exec '"$INSTDIR\tray\OneShellTray.exe"'
    ExecShell "open" "http://localhost:3005"

    DetailPrint "OneShell POS installed successfully!"

    ; ======= Save installer log for debugging =======
    StrCpy $0 "$INSTDIR\logs\install.log"
    Push $0
    Call DumpLog
SectionEnd

; --- Uninstaller ---
Section "Uninstall"
    ; Stop all services (reverse dependency order)
    nsExec::ExecToLog 'net stop OneShellMonitor'
    nsExec::ExecToLog 'net stop OneShellFrontend'
    nsExec::ExecToLog 'net stop OneShellPosPythonBackend'
    nsExec::ExecToLog 'net stop OneShellPosNodeBackend'
    nsExec::ExecToLog 'net stop OneShellPosBackend'
    nsExec::ExecToLog 'net stop OneShellNATS'
    nsExec::ExecToLog 'net stop OneShellMongoDB'
    Sleep 5000

    ; Kill lingering processes
    nsExec::ExecToLog 'taskkill /F /IM OneShellTray.exe'
    nsExec::ExecToLog 'taskkill /F /IM OneShellMonitor.exe'
    nsExec::ExecToLog 'taskkill /F /IM nginx.exe'
    nsExec::ExecToLog 'taskkill /F /IM nats-server.exe'
    nsExec::ExecToLog 'powershell -NoProfile -Command "Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like \"*posbackend*\" } | Stop-Process -Force -ErrorAction SilentlyContinue"'
    nsExec::ExecToLog 'powershell -NoProfile -Command "Get-Process python* -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like \"*PosPythonBackend*\" } | Stop-Process -Force -ErrorAction SilentlyContinue"'
    nsExec::ExecToLog 'taskkill /F /IM mongod.exe'
    Sleep 3000

    ; Uninstall services
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMonitorService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellFrontendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosPythonBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosNodeBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellNATSService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMongoDBService.exe" uninstall'

    ; Remove scheduled task
    nsExec::ExecToLog 'schtasks /Delete /TN "OneShellPOS-AutoUpdate" /F'

    ; Remove firewall rules
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell HTTP"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell Backend"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell Monitor"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell MongoDB"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell NATS"'

    Sleep 2000

    ; Remove tray from startup
    DeleteRegValue HKLM "Software\Microsoft\Windows\CurrentVersion\Run" "OneShellTray"

    ; Remove files (keep data!)
    RMDir /r "$INSTDIR\tray"
    RMDir /r "$INSTDIR\jre"
    RMDir /r "$INSTDIR\node"
    RMDir /r "$INSTDIR\python"
    RMDir /r "$INSTDIR\mongodb\bin"
    RMDir /r "$INSTDIR\nats"
    RMDir /r "$INSTDIR\nginx"
    RMDir /r "$INSTDIR\monitor"
    RMDir /r "$INSTDIR\services"
    RMDir /r "$INSTDIR\apps"
    RMDir /r "$INSTDIR\config"
    RMDir /r "$INSTDIR\updater"
    RMDir /r "$INSTDIR\logs"
    Delete "$INSTDIR\icon.ico"
    Delete "$INSTDIR\version.txt"
    Delete "$INSTDIR\*.bat"
    Delete "$INSTDIR\vc_redist.x64.exe"
    Delete "$INSTDIR\*.exe"
    ; NOTE: $INSTDIR\data is preserved (MongoDB database)
    RMDir "$INSTDIR\mongodb"
    RMDir "$INSTDIR"

    ; Shortcuts
    Delete "$DESKTOP\OneShell POS.lnk"
    Delete "$DESKTOP\OneShell Monitor.lnk"
    RMDir /r "$SMPROGRAMS\OneShell POS"

    ; Registry
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\OneShellPOS"
SectionEnd
