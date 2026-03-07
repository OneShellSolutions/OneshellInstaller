const { exec, spawn } = require('child_process');
const http = require('http');
const https = require('https');
const path = require('path');
const fs = require('fs');
const os = require('os');

// Determine install directory
const INSTALL_DIR = process.pkg
    ? path.resolve(path.dirname(process.execPath), '..')
    : path.resolve(__dirname);

const MONITOR_URL = 'http://127.0.0.1:3005';
const POS_URL = 'http://localhost';
const GITHUB_REPO = 'OneShellSolutions/OneshellInstallerExe';
const VERSION_FILE = path.join(INSTALL_DIR, 'version.txt');

// Service health state
let trayStatus = 'checking';
let previousStatus = null;
let serviceDetails = [];
let updateAvailable = null;
const MAX_TRAY_RESTARTS = 5;
let trayRestartCount = 0;

// --- Logging ---
function log(msg) { console.log(`[TRAY] ${new Date().toISOString()} ${msg}`); }
function logError(msg) { console.error(`[TRAY] ${new Date().toISOString()} ERROR: ${msg}`); }
function logWarn(msg) { console.warn(`[TRAY] ${new Date().toISOString()} WARN: ${msg}`); }

// --- Startup diagnostics (like TallyConnector SystemTrayConfig.init()) ---
log('=== OneShell Tray Initialization Start ===');
log(`Platform: ${os.platform()} ${os.release()} (${os.arch()})`);
log(`Node: ${process.version}, PID: ${process.pid}`);
log(`Packaged (pkg): ${!!process.pkg}`);
log(`INSTALL_DIR: ${INSTALL_DIR}`);
log(`Exec path: ${process.execPath}`);
log(`__dirname: ${__dirname}`);
log(`VERSION_FILE: ${VERSION_FILE}, exists=${fs.existsSync(VERSION_FILE)}`);

// Check if PowerShell is available
try {
    const psVersion = require('child_process').execSync(
        'powershell.exe -NoProfile -Command "$PSVersionTable.PSVersion.ToString()"',
        { timeout: 10000 }
    ).toString().trim();
    log(`PowerShell version: ${psVersion}`);
} catch (e) {
    logError(`PowerShell NOT available: ${e.message}`);
}

function getLocalVersion() {
    try {
        return fs.readFileSync(VERSION_FILE, 'utf8').trim();
    } catch (e) { return '0.0.0'; }
}

// Check services via monitor API
function checkServices() {
    const req = http.get(`${MONITOR_URL}/api/services`, { timeout: 5000 }, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
            try {
                const result = JSON.parse(data);
                const services = result.services || [];
                serviceDetails = services;
                const nonSystem = services.filter(s => s.type !== 'system');
                const running = nonSystem.filter(s => s.running);
                const critical = nonSystem.filter(s =>
                    ['OneShellMongoDB', 'OneShellNATS'].includes(s.serviceId)
                );
                const criticalDown = critical.filter(s => !s.running);

                const oldStatus = trayStatus;
                if (criticalDown.length > 0) {
                    trayStatus = 'error';
                } else if (running.length < nonSystem.length) {
                    trayStatus = 'warning';
                } else {
                    trayStatus = 'ok';
                }

                if (oldStatus !== trayStatus) {
                    log(`Status changed: ${oldStatus} -> ${trayStatus} (running=${running.length}/${nonSystem.length})`);
                    const downNames = nonSystem.filter(s => !s.running).map(s => s.name).join(', ');
                    if (downNames) log(`Down services: ${downNames}`);
                }

                // Notify on status transitions
                if (previousStatus !== null && previousStatus !== trayStatus) {
                    if (trayStatus === 'error') {
                        const downNames = nonSystem.filter(s => !s.running).map(s => s.name.replace('OneShell ', '')).join(', ');
                        showNotification('Services Down', downNames + ' stopped', 'Error');
                    } else if (trayStatus === 'warning') {
                        const downNames = nonSystem.filter(s => !s.running).map(s => s.name.replace('OneShell ', '')).join(', ');
                        showNotification('Service Warning', downNames + ' not running', 'Warning');
                    } else if (trayStatus === 'ok' && (previousStatus === 'error' || previousStatus === 'warning')) {
                        showNotification('Services Recovered', 'All services are running', 'Info');
                    }
                }
                previousStatus = trayStatus;
                updateTrayIcon();
            } catch (e) {
                logError(`Failed to parse monitor response: ${e.message}`);
                trayStatus = 'error';
                updateTrayIcon();
            }
        });
    });
    req.on('error', (e) => {
        if (trayStatus !== 'error') {
            logWarn(`Monitor API unreachable: ${e.message}`);
        }
        trayStatus = 'error';
        updateTrayIcon();
    });
}

// Check for updates via GitHub API
function checkForUpdates() {
    log('Checking for updates...');
    const options = {
        hostname: 'api.github.com',
        path: `/repos/${GITHUB_REPO}/releases/latest`,
        headers: { 'User-Agent': 'OneShellPOS-Updater' },
        timeout: 15000
    };

    const req = https.get(options, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
            try {
                const release = JSON.parse(data);
                const remoteTag = release.tag_name || '';
                const remoteVersion = remoteTag.replace(/^v/, '');
                const localVersion = getLocalVersion();
                log(`Version check: local=${localVersion}, remote=${remoteVersion}`);
                if (remoteVersion && remoteVersion !== localVersion) {
                    updateAvailable = remoteVersion;
                    log(`Update available: v${remoteVersion}`);
                    showNotification('Update Available', `v${remoteVersion} is available (current: v${localVersion})`, 'Info');
                } else {
                    updateAvailable = null;
                    log('No update available');
                }
            } catch (e) {
                logWarn(`Failed to parse GitHub release: ${e.message}`);
            }
        });
    });
    req.on('error', (e) => {
        logWarn(`GitHub API unreachable: ${e.message}`);
    });
    req.end();
}

// Trigger silent update via monitor API
function triggerUpdate() {
    const req = http.request(`${MONITOR_URL}/api/updater/check`, { method: 'POST', timeout: 10000 }, (res) => {
        res.resume();
    });
    req.on('error', () => {});
    req.end();
}

// Show Windows notification
function showNotification(title, message, type) {
    log(`Notification: [${type}] ${title} - ${message}`);
    if (trayProcess && trayProcess.stdin && !trayProcess.stdin.destroyed) {
        try {
            trayProcess.stdin.write(`NOTIFY|${type}|${title}|${message}\n`);
        } catch (e) {
            logWarn(`Failed to send notification to tray: ${e.message}`);
        }
    } else {
        logWarn('Cannot send notification - tray process not available');
    }
}

// SysTrayIcon via PowerShell (Windows native, no npm deps)
let trayProcess = null;

function startTray() {
    log(`=== Starting Tray (attempt ${trayRestartCount + 1}/${MAX_TRAY_RESTARTS + 1}) ===`);

    const installDirEscaped = INSTALL_DIR.replace(/\\/g, '\\\\');
    log(`Install dir (escaped): ${installDirEscaped}`);

    const ps1 = `
# --- PowerShell Tray Diagnostics ---
Write-Output "[PS-TRAY] === PowerShell Tray Init Start ==="
Write-Output "[PS-TRAY] PowerShell: $($PSVersionTable.PSVersion)"
Write-Output "[PS-TRAY] OS: $([System.Environment]::OSVersion.VersionString)"
Write-Output "[PS-TRAY] Session: $([System.Diagnostics.Process]::GetCurrentProcess().SessionId)"
Write-Output "[PS-TRAY] User: $([System.Environment]::UserName)"
Write-Output "[PS-TRAY] Interactive: $([System.Environment]::UserInteractive)"
Write-Output "[PS-TRAY] Install dir: ${installDirEscaped}"

# Load assemblies
try {
    Add-Type -AssemblyName System.Windows.Forms
    Write-Output "[PS-TRAY] Loaded System.Windows.Forms"
} catch {
    Write-Output "[PS-TRAY] FAILED to load System.Windows.Forms: $_"
    exit 1
}
try {
    Add-Type -AssemblyName System.Drawing
    Write-Output "[PS-TRAY] Loaded System.Drawing"
} catch {
    Write-Output "[PS-TRAY] FAILED to load System.Drawing: $_"
    exit 1
}

# Check if we have a desktop (Session 0 = no desktop = Windows Service)
$sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
if ($sessionId -eq 0) {
    Write-Output "[PS-TRAY] ABORT: Running in Session 0 (Windows Service) - no desktop available for tray icon"
    exit 2
}

if (-not [System.Environment]::UserInteractive) {
    Write-Output "[PS-TRAY] WARNING: Non-interactive session detected - tray may not be visible"
}

# Create NotifyIcon
try {
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Visible = $true
    $notify.Text = "OneShell POS"
    Write-Output "[PS-TRAY] NotifyIcon created, Visible=True"
} catch {
    Write-Output "[PS-TRAY] FAILED to create NotifyIcon: $_"
    exit 1
}

# Status icon with colored dot overlay
function Set-StatusOverlay($color) {
    try {
        $bmp = New-Object System.Drawing.Bitmap(16,16)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $brush = switch($color) {
            'green'  { [System.Drawing.Brushes]::LimeGreen }
            'yellow' { [System.Drawing.Brushes]::Gold }
            'red'    { [System.Drawing.Brushes]::Red }
            default  { [System.Drawing.Brushes]::Gray }
        }
        $g.FillRectangle([System.Drawing.Brushes]::DarkSlateBlue, 0, 0, 16, 16)
        $g.DrawString('OS', (New-Object System.Drawing.Font('Segoe UI', 6, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 0, 0)
        $g.FillEllipse($brush, 9, 9, 7, 7)
        $g.Dispose()
        $oldIcon = $notify.Icon
        $notify.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        if ($oldIcon -ne $null) { try { $oldIcon.Dispose() } catch {} }
    } catch {
        Write-Output "[PS-TRAY] ERROR in Set-StatusOverlay($color): $_"
    }
}

# Initial icon
Set-StatusOverlay 'gray'
Write-Output "[PS-TRAY] Initial icon set (gray)"

function Update-Icon($status) {
    Write-Output "[PS-TRAY] Update-Icon: status=$status"
    switch($status) {
        'ok'      { Set-StatusOverlay 'green'; $notify.Text = "OneShell POS - All services running" }
        'warning' { Set-StatusOverlay 'yellow'; $notify.Text = "OneShell POS - Some services down" }
        'error'   { Set-StatusOverlay 'red'; $notify.Text = "OneShell POS - Services offline" }
        default   { Set-StatusOverlay 'gray'; $notify.Text = "OneShell POS - Checking..." }
    }
}

# Context menu
Write-Output "[PS-TRAY] Building context menu..."
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$openPOS = $menu.Items.Add("Open POS")
$openPOS.Font = New-Object System.Drawing.Font($openPOS.Font, [System.Drawing.FontStyle]::Bold)
$openPOS.add_Click({ Start-Process "${POS_URL}" })

$openMonitor = $menu.Items.Add("Monitor Dashboard")
$openMonitor.add_Click({ Start-Process "${MONITOR_URL}" })

$menu.Items.Add("-")

$restartAll = $menu.Items.Add("Restart All Services")
$restartAll.add_Click({
    try { Invoke-RestMethod -Uri '${MONITOR_URL}/api/services/restart-all' -Method POST -TimeoutSec 30 | Out-Null } catch {}
    $notify.ShowBalloonTip(3000, 'OneShell POS', 'Restarting all services...', [System.Windows.Forms.ToolTipIcon]::Info)
})

$checkUpdate = $menu.Items.Add("Check for Updates")
$checkUpdate.add_Click({
    try { Invoke-RestMethod -Uri '${MONITOR_URL}/api/updater/check' -Method POST -TimeoutSec 10 | Out-Null } catch {}
    $notify.ShowBalloonTip(3000, 'OneShell POS', 'Checking for updates...', [System.Windows.Forms.ToolTipIcon]::Info)
})

$viewLogs = $menu.Items.Add("View Logs")
$viewLogs.add_Click({ Start-Process "${MONITOR_URL}"; Start-Process "${installDirEscaped}\\logs" })

$menu.Items.Add("-")

$aboutItem = $menu.Items.Add("About")
$aboutItem.add_Click({
    $ver = 'unknown'
    $verFile = "${installDirEscaped}\\version.txt"
    if (Test-Path $verFile) { $ver = (Get-Content $verFile -Raw).Trim() }
    [System.Windows.Forms.MessageBox]::Show("OneShell POS v$ver\`n\`nInstall: ${installDirEscaped}\`nMonitor: ${MONITOR_URL}\`nPOS: ${POS_URL}", "About OneShell POS", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
})

$exitItem = $menu.Items.Add("Exit Tray")
$exitItem.add_Click({
    Write-Output "[PS-TRAY] Exit clicked - disposing tray"
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notify.ContextMenuStrip = $menu
Write-Output "[PS-TRAY] Context menu attached (${($menu.Items.Count)} items)"

# Double-click opens POS
$notify.add_DoubleClick({ Start-Process "${POS_URL}" })

# Read commands from stdin
Write-Output "[PS-TRAY] Setting up stdin reader..."
try {
    $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput())
    Write-Output "[PS-TRAY] StreamReader created for stdin"
} catch {
    Write-Output "[PS-TRAY] FAILED to create stdin reader: $_"
    Write-Output "[PS-TRAY] Continuing without stdin (no status updates)"
    $reader = $null
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
    if ($reader -eq $null) { return }
    try {
        while ($reader.Peek() -ne -1) {
            $line = $reader.ReadLine()
            if ($line -match '^NOTIFY\\|') {
                $parts = $line -split '\\|', 4
                if ($parts.Count -ge 4) {
                    $tipType = switch($parts[1]) {
                        'Error'   { [System.Windows.Forms.ToolTipIcon]::Error }
                        'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
                        default   { [System.Windows.Forms.ToolTipIcon]::Info }
                    }
                    $notify.ShowBalloonTip(5000, $parts[2], $parts[3], $tipType)
                    Write-Output "[PS-TRAY] Notification shown: $($parts[2]) - $($parts[3])"
                }
            } else {
                Update-Icon $line
            }
        }
    } catch {
        Write-Output "[PS-TRAY] Stdin read error: $_"
    }
})
$timer.Start()
Write-Output "[PS-TRAY] Timer started (interval=1000ms)"

Write-Output "[PS-TRAY] === Tray Ready - entering Application.Run() ==="
[System.Windows.Forms.Application]::Run()
Write-Output "[PS-TRAY] Application.Run() exited"
`;

    log(`PowerShell script length: ${ps1.length} chars`);
    log('Spawning powershell.exe...');

    trayProcess = spawn('powershell.exe', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command', ps1
    ], { stdio: ['pipe', 'pipe', 'pipe'] });

    log(`PowerShell spawned, PID: ${trayProcess.pid}`);

    trayProcess.stdout.on('data', (data) => {
        const lines = data.toString().trim().split('\n');
        lines.forEach(line => {
            if (line.trim()) console.log(`[Tray] ${line.trim()}`);
        });
    });

    trayProcess.stderr.on('data', (data) => {
        const lines = data.toString().trim().split('\n');
        lines.forEach(line => {
            if (line.trim()) console.error(`[Tray Error] ${line.trim()}`);
        });
    });

    trayProcess.on('error', (err) => {
        logError(`Failed to spawn PowerShell: ${err.message}`);
        trayProcess = null;
    });

    trayProcess.on('exit', (code, signal) => {
        log(`PowerShell process exited (code=${code}, signal=${signal})`);
        trayProcess = null;

        if (code === 2) {
            logError('Session 0 detected (Windows Service context) - tray not available, will not retry');
            return;
        }

        if (trayRestartCount < MAX_TRAY_RESTARTS) {
            trayRestartCount++;
            log(`Scheduling tray restart (attempt ${trayRestartCount}/${MAX_TRAY_RESTARTS}) in 3s...`);
            setTimeout(startTray, 3000);
        } else {
            logError(`Max restart attempts (${MAX_TRAY_RESTARTS}) reached. Tray will not restart.`);
        }
    });
}

function updateTrayIcon() {
    if (trayProcess && trayProcess.stdin && !trayProcess.stdin.destroyed) {
        try {
            trayProcess.stdin.write(trayStatus + '\n');
        } catch (e) {
            logWarn(`Failed to write status to tray: ${e.message}`);
        }
    }
}

// Start
log('Starting tray icon...');
startTray();

log('Starting service health checks (interval=10s)...');
checkServices();
setInterval(checkServices, 10000);

// Check for updates every 6 hours, and once at startup (30s delay)
log('Update checks scheduled (first in 30s, then every 6h)');
setTimeout(checkForUpdates, 30000);
setInterval(checkForUpdates, 6 * 60 * 60 * 1000);

log('=== OneShell Tray Initialization End ===');
