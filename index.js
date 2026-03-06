const express = require('express');
const { exec, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const https = require('https');

const app = express();
const PORT = 3005;

// Determine install directory (where the exe is running from, or parent of monitor dir)
const INSTALL_DIR = process.pkg
    ? path.resolve(path.dirname(process.execPath), '..')
    : path.resolve(__dirname, '..');

const SERVICES_DIR = path.join(INSTALL_DIR, 'services');
const VERSION_FILE = path.join(INSTALL_DIR, 'version.txt');
const MANIFEST_FILE = path.join(INSTALL_DIR, 'manifest.json');
const LOGS_DIR = path.join(INSTALL_DIR, 'logs');

// Static files
let staticPath = process.pkg
    ? path.join(path.dirname(process.execPath), 'public')
    : path.join(__dirname, 'public');

if (!fs.existsSync(staticPath) && process.pkg) {
    staticPath = path.join(__dirname, 'public');
}

app.use(express.static(staticPath));
app.use(express.json());

// --- Service definitions ---
const SERVICES = [
    {
        id: 'mongodb',
        name: 'OneShell MongoDB',
        serviceId: 'OneShellMongoDB',
        port: 27017,
        healthUrl: null,
        component: 'mongodb',
        type: 'infrastructure'
    },
    {
        id: 'nats',
        name: 'OneShell NATS',
        serviceId: 'OneShellNATS',
        port: 4222,
        healthUrl: 'http://127.0.0.1:8222/healthz',
        component: 'nats',
        type: 'infrastructure'
    },
    {
        id: 'posbackend',
        name: 'OneShell POS Backend',
        serviceId: 'OneShellPosBackend',
        port: 8090,
        healthUrl: 'http://127.0.0.1:8090/actuator/health',
        component: 'posbackend',
        type: 'application'
    },
    {
        id: 'posNodeBackend',
        name: 'OneShell POS Node Backend',
        serviceId: 'OneShellPosNodeBackend',
        port: 3001,
        healthUrl: 'http://127.0.0.1:3001/health',
        component: 'posNodeBackend',
        type: 'application'
    },
    {
        id: 'posPythonBackend',
        name: 'OneShell POS Python Backend',
        serviceId: 'OneShellPosPythonBackend',
        port: 5200,
        healthUrl: 'http://127.0.0.1:5200/api/assistant/health',
        component: 'PosPythonBackend',
        type: 'application'
    },
    {
        id: 'frontend',
        name: 'OneShell POS Frontend',
        serviceId: 'OneShellFrontend',
        port: 80,
        healthUrl: 'http://127.0.0.1:80',
        component: 'posFrontend',
        type: 'application'
    },
    {
        id: 'monitor',
        name: 'OneShell Monitor',
        serviceId: 'OneShellMonitor',
        port: 3005,
        healthUrl: 'http://127.0.0.1:3005/api/ping',
        component: 'monitor',
        type: 'system'
    }
];

// --- Helper: query Windows service status via sc ---
function getServiceStatus(serviceId) {
    return new Promise((resolve) => {
        exec(`sc query "${serviceId}"`, (error, stdout) => {
            if (error) {
                resolve({ state: 'NOT_INSTALLED', running: false });
                return;
            }
            const stateMatch = stdout.match(/STATE\s+:\s+\d+\s+(\w+)/);
            const state = stateMatch ? stateMatch[1] : 'UNKNOWN';
            resolve({
                state: state,
                running: state === 'RUNNING'
            });
        });
    });
}

// --- Helper: check health endpoint ---
function checkHealth(url, timeout = 3000) {
    if (!url) return Promise.resolve({ healthy: null, detail: 'No health endpoint' });

    return new Promise((resolve) => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeout);

        fetch(url, { signal: controller.signal })
            .then(res => {
                clearTimeout(timer);
                resolve({ healthy: res.ok, status: res.status, detail: 'OK' });
            })
            .catch(err => {
                clearTimeout(timer);
                resolve({ healthy: false, detail: err.message });
            });
    });
}

// --- Helper: get component version ---
function getComponentVersion(componentId) {
    const versionFile = path.join(INSTALL_DIR, 'apps', componentId, 'version.txt');
    if (fs.existsSync(versionFile)) {
        return fs.readFileSync(versionFile, 'utf8').trim();
    }
    // Check top-level for infrastructure components
    const altFile = path.join(INSTALL_DIR, componentId, 'version.txt');
    if (fs.existsSync(altFile)) {
        return fs.readFileSync(altFile, 'utf8').trim();
    }
    return null;
}

// --- Helper: read log tail ---
// Map service IDs to actual log directory names
const LOG_DIR_MAP = {
    'OneShellMongoDB': 'mongodb',
    'OneShellNATS': 'nats',
    'OneShellPosBackend': 'posbackend',
    'OneShellPosNodeBackend': 'posNodeBackend',
    'OneShellPosPythonBackend': 'PosPythonBackend',
    'OneShellFrontend': 'nginx',
    'OneShellMonitor': 'monitor'
};

function readLogTail(serviceId, lines = 50) {
    const dirName = LOG_DIR_MAP[serviceId] || serviceId.replace('OneShell', '').toLowerCase();
    const logDir = path.join(LOGS_DIR, dirName);
    if (!fs.existsSync(logDir)) return 'No logs found.';

    const files = fs.readdirSync(logDir)
        .filter(f => f.endsWith('.log') || f.endsWith('.out.log') || f.includes('stdout'))
        .sort((a, b) => {
            const statA = fs.statSync(path.join(logDir, a));
            const statB = fs.statSync(path.join(logDir, b));
            return statB.mtimeMs - statA.mtimeMs;
        });

    if (files.length === 0) return 'No log files found.';

    const content = fs.readFileSync(path.join(logDir, files[0]), 'utf8');
    const allLines = content.split('\n');
    return allLines.slice(Math.max(0, allLines.length - lines)).join('\n');
}

// ================================================
// API Routes
// ================================================

app.get('/', (req, res) => {
    res.sendFile(path.join(staticPath, 'index.html'));
});

app.get('/api/ping', (req, res) => {
    res.json({ status: 'ok', timestamp: Date.now() });
});

// --- Get all services status ---
app.get('/api/services', async (req, res) => {
    const results = await Promise.all(SERVICES.map(async (svc) => {
        const serviceStatus = await getServiceStatus(svc.serviceId);
        const health = await checkHealth(svc.healthUrl);
        const version = getComponentVersion(svc.component);

        return {
            ...svc,
            serviceState: serviceStatus.state,
            running: serviceStatus.running,
            healthy: health.healthy,
            healthDetail: health.detail,
            version: version
        };
    }));

    res.json({ success: true, services: results });
});

// --- Get single service detail ---
app.get('/api/services/:id', async (req, res) => {
    const svc = SERVICES.find(s => s.id === req.params.id);
    if (!svc) return res.status(404).json({ success: false, message: 'Service not found' });

    const serviceStatus = await getServiceStatus(svc.serviceId);
    const health = await checkHealth(svc.healthUrl);
    const version = getComponentVersion(svc.component);
    const logs = readLogTail(svc.serviceId);

    res.json({
        success: true,
        service: {
            ...svc,
            serviceState: serviceStatus.state,
            running: serviceStatus.running,
            healthy: health.healthy,
            healthDetail: health.detail,
            version: version,
            logs: logs
        }
    });
});

// --- Start a service ---
app.post('/api/services/:id/start', (req, res) => {
    const svc = SERVICES.find(s => s.id === req.params.id);
    if (!svc) return res.status(404).json({ success: false, message: 'Service not found' });

    exec(`net start "${svc.serviceId}"`, (error, stdout, stderr) => {
        res.json({
            success: !error,
            message: error ? stderr || error.message : `${svc.name} started.`
        });
    });
});

// --- Stop a service ---
app.post('/api/services/:id/stop', (req, res) => {
    const svc = SERVICES.find(s => s.id === req.params.id);
    if (!svc) return res.status(404).json({ success: false, message: 'Service not found' });

    exec(`net stop "${svc.serviceId}"`, (error, stdout, stderr) => {
        res.json({
            success: !error,
            message: error ? stderr || error.message : `${svc.name} stopped.`
        });
    });
});

// --- Restart a service ---
app.post('/api/services/:id/restart', (req, res) => {
    const svc = SERVICES.find(s => s.id === req.params.id);
    if (!svc) return res.status(404).json({ success: false, message: 'Service not found' });

    exec(`net stop "${svc.serviceId}"`, () => {
        setTimeout(() => {
            exec(`net start "${svc.serviceId}"`, (error, stdout, stderr) => {
                res.json({
                    success: !error,
                    message: error ? stderr || error.message : `${svc.name} restarted.`
                });
            });
        }, 2000);
    });
});

// --- Restart all services ---
app.post('/api/services/restart-all', (req, res) => {
    const order = ['OneShellMongoDB', 'OneShellNATS', 'OneShellPosBackend',
        'OneShellPosNodeBackend', 'OneShellPosPythonBackend', 'OneShellFrontend'];

    // Stop in reverse order
    const stopOrder = [...order].reverse();
    let stopCmd = stopOrder.map(s => `net stop "${s}"`).join(' & ');
    let startCmd = order.map((s, i) => `timeout /t ${i * 2} /nobreak >nul & net start "${s}"`).join(' & ');

    exec(stopCmd, () => {
        setTimeout(() => {
            exec(startCmd, (error) => {
                res.json({
                    success: !error,
                    message: error ? 'Some services may have failed to start' : 'All services restarted.'
                });
            });
        }, 3000);
    });
});

// --- System resources ---
app.get('/api/system', (req, res) => {
    const cpus = os.cpus();
    const totalMem = os.totalmem();
    const freeMem = os.freemem();
    const usedMem = totalMem - freeMem;
    const loadAvg = os.loadavg();

    res.json({
        success: true,
        system: {
            platform: os.platform(),
            hostname: os.hostname(),
            uptime: Math.floor(os.uptime() / 3600) + 'h ' + Math.floor((os.uptime() % 3600) / 60) + 'm',
            cpuModel: cpus[0]?.model || 'Unknown',
            cpuCores: cpus.length,
            cpuLoad: loadAvg[0]?.toFixed(2),
            totalMemory: (totalMem / (1024 * 1024 * 1024)).toFixed(1) + ' GB',
            usedMemory: (usedMem / (1024 * 1024 * 1024)).toFixed(1) + ' GB',
            memoryPercent: ((usedMem / totalMem) * 100).toFixed(1)
        }
    });
});

// --- Get manifest (installed versions) ---
app.get('/api/manifest', (req, res) => {
    const installerVersion = fs.existsSync(VERSION_FILE)
        ? fs.readFileSync(VERSION_FILE, 'utf8').trim()
        : 'unknown';

    const manifest = {
        installerVersion,
        installDir: INSTALL_DIR,
        components: {}
    };

    SERVICES.forEach(svc => {
        manifest.components[svc.component] = {
            name: svc.name,
            version: getComponentVersion(svc.component) || installerVersion
        };
    });

    res.json({ success: true, manifest });
});

// --- Get logs for a service ---
app.get('/api/logs/:serviceId', (req, res) => {
    const lines = parseInt(req.query.lines) || 100;
    const svc = SERVICES.find(s => s.id === req.params.serviceId);
    if (!svc) return res.status(404).json({ success: false, message: 'Service not found' });

    const logs = readLogTail(svc.serviceId, lines);
    res.json({ success: true, logs });
});

// --- Get updater logs ---
app.get('/api/updater/logs', (req, res) => {
    const logFile = path.join(INSTALL_DIR, 'updater', 'update.log');
    if (!fs.existsSync(logFile)) {
        return res.json({ success: true, logs: 'No update logs yet.' });
    }
    const content = fs.readFileSync(logFile, 'utf8');
    const lines = content.split('\n');
    res.json({ success: true, logs: lines.slice(Math.max(0, lines.length - 50)).join('\n') });
});

// --- Trigger manual update check ---
app.post('/api/updater/check', (req, res) => {
    const batFile = path.join(INSTALL_DIR, 'updater', 'update-check.bat');
    if (!fs.existsSync(batFile)) {
        return res.json({ success: false, message: 'Updater not found.' });
    }

    exec(`"${batFile}"`, { cwd: path.join(INSTALL_DIR, 'updater') }, (error, stdout, stderr) => {
        res.json({
            success: !error,
            message: error ? stderr || error.message : 'Update check triggered.'
        });
    });
});

// ================================================
// Watchdog: auto-restart crashed services
// ================================================
const RESTART_ORDER = ['OneShellMongoDB', 'OneShellNATS', 'OneShellPosBackend',
    'OneShellPosNodeBackend', 'OneShellPosPythonBackend', 'OneShellFrontend'];

// Track restart attempts to avoid restart storms
const restartAttempts = {};
const RESTART_COOLDOWN_MS = 120000; // 2 minutes between restart attempts per service
let watchdogEnabled = true;

async function watchdogCheck() {
    if (!watchdogEnabled) return;

    // Check infrastructure first, then applications (dependency order)
    const ordered = [...SERVICES].sort((a, b) => {
        const order = { infrastructure: 0, application: 1, system: 2 };
        return (order[a.type] || 1) - (order[b.type] || 1);
    });

    for (const svc of ordered) {
        if (svc.type === 'system') continue; // Don't watchdog the monitor itself

        const status = await getServiceStatus(svc.serviceId);
        if (status.state === 'STOPPED') {
            const now = Date.now();
            const lastAttempt = restartAttempts[svc.serviceId] || 0;
            if (now - lastAttempt < RESTART_COOLDOWN_MS) continue;

            // Check if dependencies are running before restarting
            const deps = getDependencies(svc.serviceId);
            let depsOk = true;
            for (const dep of deps) {
                const depStatus = await getServiceStatus(dep);
                if (!depStatus.running) { depsOk = false; break; }
            }
            if (!depsOk) {
                console.log(`[Watchdog] Skipping ${svc.name} - dependencies not ready.`);
                continue;
            }

            console.log(`[Watchdog] Service ${svc.name} is ${status.state}, restarting...`);
            restartAttempts[svc.serviceId] = now;

            exec(`net start "${svc.serviceId}"`, (error, stdout, stderr) => {
                if (error) {
                    console.log(`[Watchdog] Failed to restart ${svc.name}: ${stderr || error.message}`);
                } else {
                    console.log(`[Watchdog] ${svc.name} restarted successfully.`);
                }
            });

            // Wait 5 seconds after starting an infrastructure service before continuing
            if (svc.type === 'infrastructure') {
                await new Promise(resolve => setTimeout(resolve, 5000));
            }
        } else if (status.state === 'RUNNING') {
            delete restartAttempts[svc.serviceId];
        }
    }
}

// Service dependency map (from WinSW <depend> tags)
function getDependencies(serviceId) {
    const deps = {
        'OneShellNATS': ['OneShellMongoDB'],
        'OneShellPosBackend': ['OneShellMongoDB', 'OneShellNATS'],
        'OneShellPosNodeBackend': ['OneShellMongoDB'],
        'OneShellPosPythonBackend': ['OneShellPosBackend'],
        'OneShellFrontend': ['OneShellPosBackend']
    };
    return deps[serviceId] || [];
}

// Run watchdog every 30 seconds
setInterval(watchdogCheck, 30000);
// Initial check after 60 seconds (give services time to start)
setTimeout(watchdogCheck, 60000);

// --- Watchdog control ---
app.get('/api/watchdog', (req, res) => {
    res.json({ success: true, enabled: watchdogEnabled, restartAttempts });
});

app.post('/api/watchdog/toggle', (req, res) => {
    watchdogEnabled = !watchdogEnabled;
    res.json({ success: true, enabled: watchdogEnabled });
});

// ================================================
// Version check & auto-update
// ================================================
const GITHUB_REPO = 'OneShellSolutions/OneshellInstallerExe';
let cachedUpdateInfo = null;
let lastUpdateCheck = 0;
const UPDATE_CACHE_TTL = 600000; // 10 minutes

function checkGitHubRelease() {
    return new Promise((resolve) => {
        const options = {
            hostname: 'api.github.com',
            path: `/repos/${GITHUB_REPO}/releases/latest`,
            headers: { 'User-Agent': 'OneShellPOS-Monitor' },
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
                    const localVersion = fs.existsSync(VERSION_FILE)
                        ? fs.readFileSync(VERSION_FILE, 'utf8').trim()
                        : '0.0.0';

                    const updateInfo = {
                        currentVersion: localVersion,
                        latestVersion: remoteVersion,
                        latestTag: remoteTag,
                        updateAvailable: remoteVersion !== localVersion && remoteVersion !== '',
                        releaseUrl: release.html_url || '',
                        publishedAt: release.published_at || '',
                        checkedAt: new Date().toISOString()
                    };

                    cachedUpdateInfo = updateInfo;
                    lastUpdateCheck = Date.now();
                    resolve(updateInfo);
                } catch (e) {
                    resolve({ error: 'Failed to parse GitHub response', currentVersion: getLocalVersion() });
                }
            });
        });
        req.on('error', (e) => {
            resolve({ error: e.message, currentVersion: getLocalVersion() });
        });
        req.end();
    });
}

function getLocalVersion() {
    try { return fs.readFileSync(VERSION_FILE, 'utf8').trim(); }
    catch (e) { return '0.0.0'; }
}

// --- Check for updates ---
app.get('/api/version/check', async (req, res) => {
    if (cachedUpdateInfo && (Date.now() - lastUpdateCheck) < UPDATE_CACHE_TTL) {
        return res.json({ success: true, ...cachedUpdateInfo, cached: true });
    }
    const info = await checkGitHubRelease();
    res.json({ success: true, ...info });
});

// --- Trigger auto-update (download + silent install) ---
let updating = false;
app.post('/api/version/auto-update', async (req, res) => {
    if (updating) {
        return res.json({ success: false, message: 'Update already in progress.' });
    }

    updating = true;
    try {
        const info = await checkGitHubRelease();
        if (!info.updateAvailable) {
            updating = false;
            return res.json({ success: false, message: 'Already up to date.', ...info });
        }

        res.json({ success: true, message: `Downloading v${info.latestVersion}...` });

        // Run the update-check.bat which handles download + silent install
        const batFile = path.join(INSTALL_DIR, 'updater', 'update-check.bat');
        if (fs.existsSync(batFile)) {
            exec(`"${batFile}"`, { cwd: path.join(INSTALL_DIR, 'updater'), timeout: 600000 }, () => {
                updating = false;
            });
        } else {
            updating = false;
        }
    } catch (e) {
        updating = false;
        res.json({ success: false, message: 'Update failed.' });
    }
});

// --- Health endpoint (for the monitor itself) ---
app.get('/health', async (req, res) => {
    const results = await Promise.all(
        SERVICES.filter(s => s.type !== 'system').map(async (svc) => {
            const status = await getServiceStatus(svc.serviceId);
            return { name: svc.name, running: status.running };
        })
    );

    const allRunning = results.every(r => r.running);
    const failedServices = results.filter(r => !r.running).map(r => r.name);

    res.json({
        status: allRunning ? 'success' : 'failure',
        message: allRunning ? 'All services are running' : 'Some services are not running',
        services: results,
        failedServices
    });
});

// --- Start server ---
app.listen(PORT, () => {
    console.log(`OneShell Monitor running on http://localhost:${PORT}`);
    if (process.platform === 'win32' && !process.env.ONESHELL_SERVICE_MODE) {
        exec(`start http://localhost:${PORT}`);
    }
});
