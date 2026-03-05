const express = require('express');
const { exec, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

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
function readLogTail(serviceId, lines = 50) {
    const logDir = path.join(LOGS_DIR, serviceId.replace('OneShell', '').toLowerCase());
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
