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

; --- Installer ---
Section "Install"
    SetOutPath "$INSTDIR"

    ; ======= Stop existing services =======
    DetailPrint "Stopping existing services..."
    nsExec::ExecToLog 'net stop OneShellMonitor'
    nsExec::ExecToLog 'net stop OneShellFrontend'
    nsExec::ExecToLog 'net stop OneShellPosPythonBackend'
    nsExec::ExecToLog 'net stop OneShellPosNodeBackend'
    nsExec::ExecToLog 'net stop OneShellPosBackend'
    nsExec::ExecToLog 'net stop OneShellNATS'
    nsExec::ExecToLog 'net stop OneShellMongoDB'

    ; Uninstall old services
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

    ; Python
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
    CreateDirectory "$INSTDIR\logs\posnodebackend"
    CreateDirectory "$INSTDIR\logs\pospythonbackend"
    CreateDirectory "$INSTDIR\logs\nginx"
    CreateDirectory "$INSTDIR\logs\monitor"

    ; ======= Install Python pip + deps =======
    DetailPrint "Installing Python dependencies..."
    IfFileExists "$INSTDIR\apps\PosPythonBackend\requirements.txt" 0 +3
        nsExec::ExecToLog '"$INSTDIR\python\python.exe" "$INSTDIR\python\get-pip.py" --quiet'
        nsExec::ExecToLog '"$INSTDIR\python\python.exe" -m pip install -r "$INSTDIR\apps\PosPythonBackend\requirements.txt" --quiet'

    ; ======= Install Node deps =======
    DetailPrint "Installing Node.js dependencies..."
    IfFileExists "$INSTDIR\apps\posNodeBackend\package.json" 0 +2
        nsExec::ExecToLog '"$INSTDIR\node\npm.cmd" install --production --prefix "$INSTDIR\apps\posNodeBackend"'

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

    ; ======= Start services (dependency order) =======
    DetailPrint "Starting MongoDB..."
    nsExec::ExecToLog 'net start OneShellMongoDB'
    Sleep 5000

    DetailPrint "Starting NATS..."
    nsExec::ExecToLog 'net start OneShellNATS'
    Sleep 2000

    DetailPrint "Starting POS Backend..."
    nsExec::ExecToLog 'net start OneShellPosBackend'
    Sleep 3000

    DetailPrint "Starting Node Backend..."
    nsExec::ExecToLog 'net start OneShellPosNodeBackend'

    DetailPrint "Starting Python Backend..."
    nsExec::ExecToLog 'net start OneShellPosPythonBackend'

    DetailPrint "Starting Frontend..."
    nsExec::ExecToLog 'net start OneShellFrontend'

    DetailPrint "Starting Monitor..."
    nsExec::ExecToLog 'net start OneShellMonitor'

    ; ======= Auto-update scheduled task =======
    DetailPrint "Creating auto-update task..."
    nsExec::ExecToLog 'schtasks /Create /SC HOURLY /TN "OneShellPOS-AutoUpdate" /TR "\"$INSTDIR\updater\update-check.bat\"" /F /RL HIGHEST'

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

    ; Launch tray app now
    IfFileExists "$INSTDIR\tray\OneShellTray.exe" 0 +2
    Exec '"$INSTDIR\tray\OneShellTray.exe"'

    ; Open monitor in browser (skip for silent/auto-update)
    IfSilent +2
    ExecShell "open" "http://localhost:3005"

    DetailPrint "OneShell POS installed successfully!"
SectionEnd

; --- Uninstaller ---
Section "Uninstall"
    ; Stop all services
    nsExec::ExecToLog 'net stop OneShellMonitor'
    nsExec::ExecToLog 'net stop OneShellFrontend'
    nsExec::ExecToLog 'net stop OneShellPosPythonBackend'
    nsExec::ExecToLog 'net stop OneShellPosNodeBackend'
    nsExec::ExecToLog 'net stop OneShellPosBackend'
    nsExec::ExecToLog 'net stop OneShellNATS'
    nsExec::ExecToLog 'net stop OneShellMongoDB'

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
    ; Kill tray app if running
    nsExec::ExecToLog 'taskkill /F /IM OneShellTray.exe'

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
