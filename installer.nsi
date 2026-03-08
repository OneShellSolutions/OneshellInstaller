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
    nsExec::ExecToLog 'powershell -NoProfile -Command "$procs = @(\"mongod\",\"nats-server\",\"nginx\",\"OneShellMonitor\"); $running = Get-Process -Name $procs -ErrorAction SilentlyContinue; if ($running) { Write-Output \"WARNING: Still running: $($running.Name -join \", \")\"; Start-Sleep 5 } else { Write-Output \"All processes stopped.\" }"'

    ; ======= Uninstall old services =======
    DetailPrint "Removing old service registrations..."
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMonitorService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellFrontendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosPythonBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosNodeBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellNATSService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMongoDBService.exe" uninstall'
    ; Fallback: force-remove via sc delete (handles orphaned service registrations)
    nsExec::ExecToLog 'sc delete OneShellMonitor'
    nsExec::ExecToLog 'sc delete OneShellFrontend'
    nsExec::ExecToLog 'sc delete OneShellPosPythonBackend'
    nsExec::ExecToLog 'sc delete OneShellPosNodeBackend'
    nsExec::ExecToLog 'sc delete OneShellPosBackend'
    nsExec::ExecToLog 'sc delete OneShellNATS'
    nsExec::ExecToLog 'sc delete OneShellMongoDB'
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
    File "${BUNDLE_DIR}/config/mime.types"

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
    ; Nginx temp dirs - must be under $INSTDIR\temp (matching nginx.conf paths)
    CreateDirectory "$INSTDIR\temp"
    CreateDirectory "$INSTDIR\temp\client_body_temp"
    CreateDirectory "$INSTDIR\temp\proxy_temp"
    CreateDirectory "$INSTDIR\temp\fastcgi_temp"
    CreateDirectory "$INSTDIR\temp\uwsgi_temp"
    CreateDirectory "$INSTDIR\temp\scgi_temp"

    ; ======= Verify Python path file (._pth already configured by build script) =======
    IfFileExists "$INSTDIR\python\python311._pth" 0 +2
    DetailPrint "Python path file (python311._pth) present."

    ; ======= Install Python pip + deps (OFFLINE from bundled wheels) =======
    DetailPrint "Installing Python dependencies (offline)..."
    IfFileExists "$INSTDIR\python\wheels\pip*" 0 +5
        ; Install pip itself from bundled wheel (no internet needed)
        DetailPrint "Installing pip from bundled wheels..."
        nsExec::ExecToLog '"$INSTDIR\python\python.exe" "$INSTDIR\python\get-pip.py" --no-index --find-links "$INSTDIR\python\wheels"'
        ; Install all app dependencies from bundled wheels (no internet needed)
        DetailPrint "Installing Python app dependencies..."
        nsExec::ExecToLog '"$INSTDIR\python\python.exe" -m pip install --no-index --find-links "$INSTDIR\python\wheels" -r "$INSTDIR\apps\PosPythonBackend\requirements.txt"'
    ; Fallback: try online install if wheels not bundled
    IfFileExists "$INSTDIR\python\wheels\pip*" +4 0
        DetailPrint "WARNING: No bundled wheels found. Trying online pip install..."
        nsExec::ExecToLog '"$INSTDIR\python\python.exe" "$INSTDIR\python\get-pip.py"'
        nsExec::ExecToLog '"$INSTDIR\python\python.exe" -m pip install -r "$INSTDIR\apps\PosPythonBackend\requirements.txt"'

    ; Node.js: node_modules pre-installed in bundle, nothing to do on customer machine

    ; ======= Version file =======
    SetOutPath "$INSTDIR"
    FileOpen $0 "$INSTDIR\version.txt" w
    FileWrite $0 "${VERSION}"
    FileClose $0

    ; ======= Install Visual C++ Redistributable (MongoDB 8.0 REQUIRES it) =======
    ; MUST happen BEFORE service registration - SCM may auto-start delayed services
    ; Exit code 0xC0000135 = STATUS_DLL_NOT_FOUND if VC++ is missing
    IfFileExists "$INSTDIR\vc_redist.x64.exe" 0 vc_not_found
    DetailPrint "Installing Visual C++ Redistributable (required by MongoDB 8.0)..."
    ; Use ExecWait to guarantee DLLs are fully registered before proceeding
    ExecWait '"$INSTDIR\vc_redist.x64.exe" /install /quiet /norestart' $0
    DetailPrint "Visual C++ Redistributable exit code: $0"
    Goto vc_done
    vc_not_found:
    DetailPrint "ERROR: vc_redist.x64.exe not found! MongoDB 8.0 will NOT start without it."
    DetailPrint "Download from: https://aka.ms/vs/17/release/vc_redist.x64.exe"
    vc_done:

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
    nsExec::ExecToLog 'taskkill /F /IM OneShellMonitor.exe'
    nsExec::ExecToLog 'taskkill /F /IM nginx.exe'
    nsExec::ExecToLog 'taskkill /F /IM nats-server.exe'
    nsExec::ExecToLog 'powershell -NoProfile -Command "Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like \"*posbackend*\" } | Stop-Process -Force -ErrorAction SilentlyContinue"'
    nsExec::ExecToLog 'powershell -NoProfile -Command "Get-Process python* -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like \"*PosPythonBackend*\" } | Stop-Process -Force -ErrorAction SilentlyContinue"'
    nsExec::ExecToLog 'taskkill /F /IM mongod.exe'
    Sleep 3000

    ; Uninstall services (WinSW first, then sc delete as fallback)
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMonitorService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellFrontendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosPythonBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosNodeBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellPosBackendService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellNATSService.exe" uninstall'
    nsExec::ExecToLog '"$INSTDIR\services\OneShellMongoDBService.exe" uninstall'
    Sleep 2000
    ; Fallback: force-remove any leftover service registrations via sc delete
    nsExec::ExecToLog 'sc delete OneShellMonitor'
    nsExec::ExecToLog 'sc delete OneShellFrontend'
    nsExec::ExecToLog 'sc delete OneShellPosPythonBackend'
    nsExec::ExecToLog 'sc delete OneShellPosNodeBackend'
    nsExec::ExecToLog 'sc delete OneShellPosBackend'
    nsExec::ExecToLog 'sc delete OneShellNATS'
    nsExec::ExecToLog 'sc delete OneShellMongoDB'

    ; Remove scheduled task
    nsExec::ExecToLog 'schtasks /Delete /TN "OneShellPOS-AutoUpdate" /F'

    ; Remove firewall rules
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell HTTP"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell Backend"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell Monitor"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell MongoDB"'
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="OneShell NATS"'

    Sleep 2000

    ; Remove tray from startup (legacy cleanup)
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
    RMDir /r "$INSTDIR\temp"
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
