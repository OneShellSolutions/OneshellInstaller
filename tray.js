const { exec } = require('child_process');
const http = require('http');
const path = require('path');

// Determine install directory
const INSTALL_DIR = process.pkg
    ? path.resolve(path.dirname(process.execPath), '..')
    : path.resolve(__dirname);

const MONITOR_URL = 'http://127.0.0.1:3005';
const POS_URL = 'http://localhost';

// Service health state
let trayStatus = 'checking'; // 'ok', 'warning', 'error', 'checking'

// Check services via monitor API
function checkServices() {
    const req = http.get(`${MONITOR_URL}/api/services`, { timeout: 5000 }, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
            try {
                const result = JSON.parse(data);
                const services = result.services || [];
                const running = services.filter(s => s.running);
                const critical = services.filter(s =>
                    ['OneShellMongoDB', 'OneShellNATS'].includes(s.serviceId)
                );
                const criticalDown = critical.filter(s => !s.running);

                if (criticalDown.length > 0) {
                    trayStatus = 'error';
                } else if (running.length < services.length) {
                    trayStatus = 'warning';
                } else {
                    trayStatus = 'ok';
                }
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

// SysTrayIcon via PowerShell (Windows native, no npm deps)
let trayProcess = null;

function startTray() {
    const ps1 = `
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$notify.Text = "OneShell POS"

# Create colored icon based on status
function Set-TrayIcon($color) {
    $bmp = New-Object System.Drawing.Bitmap(16,16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $brush = switch($color) {
        'green'  { [System.Drawing.Brushes]::LimeGreen }
        'yellow' { [System.Drawing.Brushes]::Gold }
        'red'    { [System.Drawing.Brushes]::Red }
        default  { [System.Drawing.Brushes]::Gray }
    }
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $g.Dispose()
    $notify.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# Try to load custom icon
$iconPath = "${INSTALL_DIR.replace(/\\/g, '\\\\')}\\icon.ico"
if (Test-Path $iconPath) {
    $notify.Icon = New-Object System.Drawing.Icon($iconPath)
} else {
    Set-TrayIcon 'gray'
}

# Context menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$openPOS = $menu.Items.Add("Open POS")
$openPOS.add_Click({ Start-Process "${POS_URL}" })

$openMonitor = $menu.Items.Add("Open Monitor Dashboard")
$openMonitor.add_Click({ Start-Process "${MONITOR_URL}" })

$menu.Items.Add("-")

$startAll = $menu.Items.Add("Start All Services")
$startAll.add_Click({
    Start-Process -FilePath "${INSTALL_DIR.replace(/\\/g, '\\\\')}\\Start-OneShell.bat" -Verb RunAs -WindowStyle Hidden
})

$stopAll = $menu.Items.Add("Stop All Services")
$stopAll.add_Click({
    Start-Process -FilePath "${INSTALL_DIR.replace(/\\/g, '\\\\')}\\Stop-OneShell.bat" -Verb RunAs -WindowStyle Hidden
})

$menu.Items.Add("-")

$exitItem = $menu.Items.Add("Exit")
$exitItem.add_Click({
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notify.ContextMenuStrip = $menu

# Double-click opens POS
$notify.add_DoubleClick({ Start-Process "${POS_URL}" })

# Read status from stdin and update icon color
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
    if ([Console]::In.Peek() -ne -1) {
        $line = [Console]::In.ReadLine()
        switch($line) {
            'ok'      { Set-TrayIcon 'green'; $notify.Text = "OneShell POS - All services running" }
            'warning' { Set-TrayIcon 'yellow'; $notify.Text = "OneShell POS - Some services down" }
            'error'   { Set-TrayIcon 'red'; $notify.Text = "OneShell POS - Services offline" }
        }
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run()
`;

    trayProcess = require('child_process').spawn('powershell.exe', [
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
