// OneShell POS Monitor - Frontend Application
let servicesData = [];
let autoRefreshInterval = null;

// ================================================
// Page Navigation
// ================================================
function showPage(page) {
    document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
    document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));

    document.getElementById('page-' + page).classList.add('active');
    document.querySelector(`[data-page="${page}"]`).classList.add('active');

    if (page === 'system') loadSystemInfo();
    if (page === 'updates') { loadManifest(); loadUpdaterLogs(); }
    if (page === 'logs') initLogSelector();
    if (page === 'services') renderServiceList();
}

// ================================================
// Dashboard
// ================================================
async function loadDashboard() {
    try {
        const res = await fetch('/api/services');
        const data = await res.json();
        if (!data.success) return;

        servicesData = data.services;
        renderServiceCards(data.services);
        updateOverallStatus(data.services);
    } catch (e) {
        console.error('Failed to load dashboard:', e);
    }
}

function renderServiceCards(services) {
    const container = document.getElementById('service-cards');
    container.innerHTML = services.filter(s => s.type !== 'system').map(svc => `
        <div class="card" onclick="showPage('services'); selectService('${svc.id}')">
            <div class="card-header">
                <span class="card-title">${svc.name.replace('OneShell ', '')}</span>
                <span class="status-dot ${svc.running ? 'running' : 'stopped'}"></span>
            </div>
            <div class="card-type">${svc.type}</div>
            <div class="card-meta">
                <span>Port: ${svc.port}</span>
                <span>State: ${svc.serviceState || 'Unknown'}</span>
                ${svc.version ? `<span>v${svc.version}</span>` : ''}
            </div>
            <div class="card-actions" onclick="event.stopPropagation()">
                ${svc.running
                    ? `<button onclick="restartService('${svc.id}')">Restart</button>
                       <button class="btn-danger" onclick="stopService('${svc.id}')">Stop</button>`
                    : `<button onclick="startService('${svc.id}')">Start</button>`
                }
            </div>
        </div>
    `).join('');
}

function updateOverallStatus(services) {
    const el = document.getElementById('overall-status');
    const active = services.filter(s => s.type !== 'system');
    const running = active.filter(s => s.running).length;

    if (running === active.length) {
        el.className = 'badge badge-healthy';
        el.textContent = 'All Healthy';
    } else if (running === 0) {
        el.className = 'badge badge-unhealthy';
        el.textContent = 'All Stopped';
    } else {
        el.className = 'badge badge-warning';
        el.textContent = `${running}/${active.length} Running`;
    }

    // Version
    fetch('/api/manifest').then(r => r.json()).then(data => {
        if (data.success) {
            document.getElementById('installer-version').textContent = 'v' + data.manifest.installerVersion;
        }
    }).catch(() => {});
}

// ================================================
// Service Actions
// ================================================
async function startService(id) {
    await fetch(`/api/services/${id}/start`, { method: 'POST' });
    setTimeout(loadDashboard, 2000);
}

async function stopService(id) {
    await fetch(`/api/services/${id}/stop`, { method: 'POST' });
    setTimeout(loadDashboard, 2000);
}

async function restartService(id) {
    await fetch(`/api/services/${id}/restart`, { method: 'POST' });
    setTimeout(loadDashboard, 3000);
}

async function restartAll() {
    if (!confirm('Restart all OneShell POS services?')) return;
    document.getElementById('overall-status').className = 'badge badge-loading';
    document.getElementById('overall-status').textContent = 'Restarting...';
    await fetch('/api/services/restart-all', { method: 'POST' });
    setTimeout(loadDashboard, 8000);
}

// ================================================
// Services Detail Page
// ================================================
function renderServiceList() {
    const container = document.getElementById('service-detail-list');
    container.innerHTML = servicesData.map(svc => `
        <div class="service-list-item" id="svc-item-${svc.id}" onclick="selectService('${svc.id}')">
            <span class="status-dot ${svc.running ? 'running' : 'stopped'}"></span>
            ${svc.name.replace('OneShell ', '')}
        </div>
    `).join('');
}

async function selectService(id) {
    document.querySelectorAll('.service-list-item').forEach(i => i.classList.remove('active'));
    const item = document.getElementById('svc-item-' + id);
    if (item) item.classList.add('active');

    const panel = document.getElementById('service-detail-panel');
    panel.innerHTML = '<p class="placeholder-text">Loading...</p>';

    try {
        const res = await fetch(`/api/services/${id}`);
        const data = await res.json();
        if (!data.success) return;

        const svc = data.service;
        panel.innerHTML = `
            <div class="detail-header">
                <h2>
                    <span class="status-dot ${svc.running ? 'running' : 'stopped'}"></span>
                    ${svc.name}
                </h2>
                <div class="meta">${svc.type} service | Port ${svc.port}</div>
            </div>
            <div class="detail-grid">
                <div class="detail-field">
                    <label>Service State</label>
                    <div class="value">${svc.serviceState}</div>
                </div>
                <div class="detail-field">
                    <label>Health</label>
                    <div class="value">${svc.healthy === true ? 'Healthy' : svc.healthy === false ? 'Unhealthy' : 'N/A'}</div>
                </div>
                <div class="detail-field">
                    <label>Version</label>
                    <div class="value">${svc.version || 'N/A'}</div>
                </div>
                <div class="detail-field">
                    <label>Health Detail</label>
                    <div class="value">${svc.healthDetail || '-'}</div>
                </div>
            </div>
            <div class="card-actions" style="margin-bottom:16px">
                ${svc.running
                    ? `<button onclick="restartService('${svc.id}'); setTimeout(() => selectService('${svc.id}'), 3000)">Restart</button>
                       <button class="btn-danger" onclick="stopService('${svc.id}'); setTimeout(() => selectService('${svc.id}'), 2000)">Stop</button>`
                    : `<button onclick="startService('${svc.id}'); setTimeout(() => selectService('${svc.id}'), 2000)">Start</button>`
                }
            </div>
            <h3 style="margin-bottom:8px; font-size:13px; color:#636c76;">Recent Logs</h3>
            <pre class="log-view" style="max-height:300px">${escapeHtml(svc.logs || 'No logs available.')}</pre>
        `;
    } catch (e) {
        panel.innerHTML = `<p class="placeholder-text">Error loading service: ${e.message}</p>`;
    }
}

// ================================================
// System Page
// ================================================
async function loadSystemInfo() {
    try {
        const res = await fetch('/api/system');
        const data = await res.json();
        if (!data.success) return;

        const sys = data.system;
        const memPct = parseFloat(sys.memoryPercent);
        const memColor = memPct > 90 ? 'fill-red' : memPct > 70 ? 'fill-yellow' : 'fill-green';

        document.getElementById('system-info').innerHTML = `
            <div class="system-card">
                <h3>Hostname</h3>
                <div class="value">${sys.hostname}</div>
                <div class="sub">${sys.platform}</div>
            </div>
            <div class="system-card">
                <h3>Uptime</h3>
                <div class="value">${sys.uptime}</div>
            </div>
            <div class="system-card">
                <h3>CPU</h3>
                <div class="value">${sys.cpuCores} cores</div>
                <div class="sub">${sys.cpuModel}</div>
                <div class="sub">Load: ${sys.cpuLoad}</div>
            </div>
            <div class="system-card">
                <h3>Memory</h3>
                <div class="value">${sys.usedMemory} / ${sys.totalMemory}</div>
                <div class="sub">${sys.memoryPercent}% used</div>
                <div class="progress-bar"><div class="fill ${memColor}" style="width:${sys.memoryPercent}%"></div></div>
            </div>
        `;
    } catch (e) {
        document.getElementById('system-info').innerHTML = `<p class="placeholder-text">Error: ${e.message}</p>`;
    }
}

// ================================================
// Updates Page
// ================================================
async function loadManifest() {
    try {
        const res = await fetch('/api/manifest');
        const data = await res.json();
        if (!data.success) return;

        const components = data.manifest.components;
        let rows = Object.entries(components).map(([key, val]) => `
            <tr>
                <td>${val.name}</td>
                <td>${key}</td>
                <td>${val.version || 'N/A'}</td>
            </tr>
        `).join('');

        document.getElementById('component-versions').innerHTML = `
            <table class="versions-table">
                <thead><tr><th>Component</th><th>ID</th><th>Version</th></tr></thead>
                <tbody>${rows}</tbody>
            </table>
        `;
    } catch (e) {
        document.getElementById('component-versions').innerHTML = `<p>Error: ${e.message}</p>`;
    }
}

async function loadUpdaterLogs() {
    try {
        const res = await fetch('/api/updater/logs');
        const data = await res.json();
        document.getElementById('update-log').textContent = data.logs || 'No logs.';
    } catch (e) {
        document.getElementById('update-log').textContent = 'Error loading logs.';
    }
}

async function checkUpdates() {
    const el = document.getElementById('update-status');
    if (el) el.textContent = 'Checking for updates...';
    try {
        const res = await fetch('/api/updater/check', { method: 'POST' });
        const data = await res.json();
        if (el) el.textContent = data.message;
        setTimeout(loadUpdaterLogs, 3000);
    } catch (e) {
        if (el) el.textContent = 'Error: ' + e.message;
    }
}

// ================================================
// Logs Page
// ================================================
function initLogSelector() {
    const select = document.getElementById('log-service-select');
    if (select.options.length <= 1) {
        servicesData.forEach(svc => {
            const opt = document.createElement('option');
            opt.value = svc.id;
            opt.textContent = svc.name;
            select.appendChild(opt);
        });
    }
}

async function loadServiceLogs() {
    const select = document.getElementById('log-service-select');
    const id = select.value;
    if (!id) return;

    const logView = document.getElementById('service-log-view');
    logView.textContent = 'Loading...';

    try {
        const res = await fetch(`/api/logs/${id}?lines=200`);
        const data = await res.json();
        logView.textContent = data.logs || 'No logs.';
        logView.scrollTop = logView.scrollHeight;
    } catch (e) {
        logView.textContent = 'Error: ' + e.message;
    }
}

// ================================================
// Utilities
// ================================================
function escapeHtml(str) {
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ================================================
// Auto-refresh
// ================================================
function startAutoRefresh() {
    loadDashboard();
    autoRefreshInterval = setInterval(loadDashboard, 10000); // every 10s
}

// Initialize
startAutoRefresh();
