# OneShell POS - Windows Native Installer

Single `.exe` installer that sets up the complete OneShell POS system on Windows **without Docker**. Bundles all runtimes, applications, and a monitoring dashboard.

## What's Included

| Component | Version | Purpose |
|-----------|---------|---------|
| Java JRE | 24 | PosClientBackend runtime |
| Node.js | 20 LTS | PosNodeBackend runtime |
| Python | 3.11 | PosPythonBackend runtime |
| MongoDB | 8.0 | Database |
| NATS | 2.10 | Message broker with JetStream |
| Nginx | 1.26 | Frontend web server + reverse proxy |
| Monitor | - | Status dashboard at `localhost:3005` |
| Tray App | - | System tray icon with status + quick actions |

## Windows Services Registered

All services auto-start on boot and auto-restart on crash (exponential backoff: 10s → 30s → 60s).

| Service Name | Depends On | Port |
|-------------|-----------|------|
| OneShellMongoDB | - | 27017 |
| OneShellNATS | MongoDB | 4222 |
| OneShellPosBackend | MongoDB, NATS | 8090 |
| OneShellPosNodeBackend | MongoDB | 3001 |
| OneShellPosPythonBackend | PosBackend | 5200 |
| OneShellFrontend | PosBackend | 80 |
| OneShellMonitor | - | 3005 |

## Installation (Customer)

1. Download `OneShellPOS-Setup-{VERSION}.exe` from [Releases](https://github.com/OneShellSolutions/OneshellInstaller/releases)
2. Run as Administrator
3. Follow the wizard — everything installs automatically
4. POS opens at `http://localhost`, Monitor at `http://localhost:3005`

Two desktop shortcuts are created: **OneShell POS** and **OneShell Monitor**.

### Silent Install (for scripting)

```cmd
OneShellPOS-Setup-1.0.0.exe /S
```

### Custom Install Directory

```cmd
OneShellPOS-Setup-1.0.0.exe /D=D:\OneShellPOS
```

## Uninstall

Use **Add/Remove Programs** → "OneShell POS" or run `Uninstall.exe` from the install directory.

MongoDB data (`data/` folder) is preserved during uninstall. Delete manually if needed.

## Monitor Dashboard

Access at **http://localhost:3005** — provides:

- **Dashboard** — All services with live status (green/red), start/stop/restart buttons
- **Services** — Per-service detail view with logs, version, health check status
- **System** — CPU, memory, hostname, uptime
- **Updates** — Component versions, manual update trigger, update logs
- **Logs** — Per-service log viewer

Auto-refreshes every 10 seconds.

## System Tray Icon

A tray icon runs in the notification area showing service status:

- **Green icon** — All services running
- **Yellow icon** — Some services down
- **Red icon** — Critical services (MongoDB/NATS) down

Right-click menu:
- **Open POS** — Opens `http://localhost` in browser
- **Open Monitor** — Opens `http://localhost:3005`
- **Start All / Stop All** — Manage all services
- **Exit** — Close tray icon (services keep running)

Starts automatically on Windows login.

## Auto-Updates

A Windows Scheduled Task (`OneShellPOS-AutoUpdate`) runs every hour and:

1. Checks GitHub Releases API for `OneShellSolutions/OneshellInstaller`
2. Compares latest release tag with local `version.txt`
3. If newer version exists: downloads the `.exe`, runs it silently (`/S`)
4. The installer handles stopping services → replacing files → restarting services
5. Logs to `{install_dir}\updater\update.log`

## Management Scripts

Located in the install directory (default `C:\Program Files\OneShellPOS\`):

| Script | Purpose |
|--------|---------|
| `Start-OneShell.bat` | Start all services in dependency order |
| `Stop-OneShell.bat` | Stop all services |
| `Status-OneShell.bat` | Show service status + open monitor |

You can also manage services via Windows Services (`services.msc`) or the Monitor dashboard.

## Logs

All logs are at `{install_dir}\logs\`:

```
logs/
├── mongodb/        # MongoDB stdout/stderr
├── nats/           # NATS server logs
├── posbackend/     # Java backend logs
├── posnodebackend/ # Node backend logs
├── pospythonbackend/ # Python backend logs
├── nginx/          # Nginx access/error logs
├── monitor/        # Monitor dashboard logs
```

Logs auto-rotate at 10MB with daily rollover (managed by WinSW).

---

## Building the Installer (Developer)

### Prerequisites

```bash
# macOS
brew install makensis node maven
npm i -g pkg

# Linux
sudo apt install nsis nodejs maven
npm i -g pkg
```

### Build

```bash
git clone https://github.com/OneShellSolutions/OneshellInstaller.git
cd OneshellInstaller
./build-installer.sh 1.0.0
```

This will:
1. Download all runtimes (cached in `target/cache/` for subsequent builds)
2. Clone and build each app repo from `OneShellSolutions/` GitHub org:
   - `PosClientBackend` → `mvnw clean package` → JAR
   - `PosNodeBackend` → copy Node.js app
   - `PosFrontend` → `npm run build` → static files
   - `PosPythonBackend` → copy Python app
3. Build the Monitor dashboard via `pkg` → Windows EXE
4. Assemble everything into NSIS bundle
5. Output: `target/OneShellPOS-Setup-1.0.0.exe`

### Release

```bash
# Tag and create GitHub release
git tag v1.0.0
git push origin v1.0.0
gh release create v1.0.0 target/OneShellPOS-Setup-1.0.0.exe \
  --title "OneShell POS v1.0.0" \
  --notes "Initial release"
```

Customers with existing installations auto-update within 1 hour.

### Build Caching

Runtimes are cached in `target/cache/`. Delete this folder to force re-download:

```bash
rm -rf target/cache
```

App repos are cached in `target/repos/`. On subsequent builds, `git pull` fetches only changes.

## Project Structure

```
OneshellInstaller/
├── build-installer.sh          # Master build script (clones repos, builds, packages)
├── installer.nsi               # NSIS installer script
├── index.js                    # Monitor dashboard server (Express.js)
├── tray.js                     # System tray icon app
├── package.json                # Node.js project config
├── version.txt                 # Current version
├── public/                     # Monitor web UI
│   ├── index.html
│   ├── app.js
│   └── style.css
├── services/                   # WinSW service XML configs
│   ├── OneShellMongoDBService.xml
│   ├── OneShellNATSService.xml
│   ├── OneShellPosBackendService.xml
│   ├── OneShellPosNodeBackendService.xml
│   ├── OneShellPosPythonBackendService.xml
│   ├── OneShellFrontendService.xml
│   └── OneShellMonitorService.xml
└── updater/
    └── update-check.bat        # Auto-updater (hourly scheduled task)
```

## Technology Choices

| Choice | Why |
|--------|-----|
| **NSIS** (not Inno Setup) | Same as TallyConnector, supports silent `/S` flag for auto-updates |
| **WinSW** (not nssm) | Proper service wrapper with XML config, log rotation, crash recovery, dependency ordering |
| **GitHub Releases** | Free hosting for installer EXE, versioned, API for auto-update checks |
| **Express.js + pkg** | Monitor dashboard packaged as single EXE, no Node.js dependency needed at runtime |
