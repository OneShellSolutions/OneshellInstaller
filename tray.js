const { exec, spawn } = require('child_process');
const http = require('http');
const https = require('https');
const path = require('path');
const fs = require('fs');

// Determine install directory
const INSTALL_DIR = process.pkg
    ? path.resolve(path.dirname(process.execPath), '..')
    : path.resolve(__dirname);

const MONITOR_URL = 'http://127.0.0.1:3005';
const POS_URL = 'http://localhost';
const GITHUB_REPO = 'OneShellSolutions/OneshellInstaller';
const VERSION_FILE = path.join(INSTALL_DIR, 'version.txt');

// Service health state
let trayStatus = 'checking';
let previousStatus = null;
let serviceDetails = [];
let updateAvailable = null;

function getLocalVersion() {
    try {
        return fs.readFileSync(VERSION_FILE, 'utf8').trim();
    } catch { return '0.0.0'; }
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

                if (criticalDown.length > 0) {
                    trayStatus = 'error';
                } else if (running.length < nonSystem.length) {
                    trayStatus = 'warning';
                } else {
                    trayStatus = 'ok';
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
            } catch {
                trayStatus = 'error';
                updateTrayIcon();
            }
        });
    });
    req.on('error', () => {
        trayStatus = 'error';
        updateTrayIcon();
    });
}

// Check for updates via GitHub API
function checkForUpdates() {
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
                if (remoteVersion && remoteVersion !== localVersion) {
                    updateAvailable = remoteVersion;
                    showNotification('Update Available', `v${remoteVersion} is available (current: v${localVersion})`, 'Info');
                } else {
                    updateAvailable = null;
                }
            } catch { /* ignore parse errors */ }
        });
    });
    req.on('error', () => {});
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
    if (trayProcess && trayProcess.stdin && !trayProcess.stdin.destroyed) {
        try {
            trayProcess.stdin.write(`NOTIFY|${type}|${title}|${message}\n`);
        } catch { /* ignore */ }
    }
}

// SysTrayIcon via PowerShell (Windows native, no npm deps)
let trayProcess = null;

function startTray() {
    const installDirEscaped = INSTALL_DIR.replace(/\\/g, '\\\\');
    const ps1 = `
[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('System.Drawing') | Out-Null

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$notify.Text = "OneShell POS"

# Load icon
$iconPath = "${installDirEscaped}\\icon.ico"
if (Test-Path $iconPath) {
    $notify.Icon = New-Object System.Drawing.Icon($iconPath)
} else {
    # Fallback: create colored circle icon
    $bmp = New-Object System.Drawing.Bitmap(16,16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.FillEllipse([System.Drawing.Brushes]::LimeGreen, 2, 2, 12, 12)
    $g.Dispose()
    $notify.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# Status icon updater
function Set-StatusOverlay($color) {
    $bmp = New-Object System.Drawing.Bitmap(16,16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $brush = switch($color) {
        'green'  { [System.Drawing.Brushes]::LimeGreen }
        'yellow' { [System.Drawing.Brushes]::Gold }
        'red'    { [System.Drawing.Brushes]::Red }
        default  { [System.Drawing.Brushes]::Gray }
    }
    # Draw main icon background
    $g.FillRectangle([System.Drawing.Brushes]::DarkSlateBlue, 0, 0, 16, 16)
    $g.DrawString('OS', (New-Object System.Drawing.Font('Segoe UI', 6, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 0, 0)
    # Status dot in bottom-right corner
    $g.FillEllipse($brush, 9, 9, 7, 7)
    $g.Dispose()
    $notify.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# Reload custom icon if available, otherwise use status overlay
function Update-Icon($status) {
    $iconPath = "${installDirEscaped}\\icon.ico"
    if (Test-Path $iconPath) {
        # Keep custom icon but update tooltip
        switch($status) {
            'ok'      { $notify.Text = "OneShell POS - All services running" }
            'warning' { $notify.Text = "OneShell POS - Some services down" }
            'error'   { $notify.Text = "OneShell POS - Services offline" }
            default   { $notify.Text = "OneShell POS - Checking..." }
        }
    } else {
        switch($status) {
            'ok'      { Set-StatusOverlay 'green'; $notify.Text = "OneShell POS - All services running" }
            'warning' { Set-StatusOverlay 'yellow'; $notify.Text = "OneShell POS - Some services down" }
            'error'   { Set-StatusOverlay 'red'; $notify.Text = "OneShell POS - Services offline" }
            default   { Set-StatusOverlay 'gray'; $notify.Text = "OneShell POS - Checking..." }
        }
    }
}

# Context menu
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
    [System.Windows.Forms.MessageBox]::Show("OneShell POS v$ver`n`nInstall: ${installDirEscaped}`nMonitor: ${MONITOR_URL}`nPOS: ${POS_URL}", "About OneShell POS", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
})

$exitItem = $menu.Items.Add("Exit Tray")
$exitItem.add_Click({
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notify.ContextMenuStrip = $menu

# Double-click opens POS
$notify.add_DoubleClick({ Start-Process "${POS_URL}" })

# Read commands from stdin
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
    while ([Console]::In.Peek() -ne -1) {
        $line = [Console]::In.ReadLine()
        if ($line -match '^NOTIFY\\|') {
            $parts = $line -split '\\|', 4
            if ($parts.Count -ge 4) {
                $tipType = switch($parts[1]) {
                    'Error'   { [System.Windows.Forms.ToolTipIcon]::Error }
                    'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
                    default   { [System.Windows.Forms.ToolTipIcon]::Info }
                }
                $notify.ShowBalloonTip(5000, $parts[2], $parts[3], $tipType)
            }
        } else {
            Update-Icon $line
        }
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run()
`;

    trayProcess = spawn('powershell.exe', [
        '-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps1
    ], { stdio: ['pipe', 'ignore', 'ignore'] });

    trayProcess.on('exit', () => {
        process.exit(0);
    });
}

function updateTrayIcon() {
    if (trayProcess && trayProcess.stdin && !trayProcess.stdin.destroyed) {
        try {
            trayProcess.stdin.write(trayStatus + '\n');
        } catch { /* ignore write errors */ }
    }
}

// Start
startTray();
checkServices();
setInterval(checkServices, 10000);

// Check for updates every 6 hours, and once at startup (30s delay)
setTimeout(checkForUpdates, 30000);
setInterval(checkForUpdates, 6 * 60 * 60 * 1000);
