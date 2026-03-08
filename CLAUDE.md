# OneshellInstaller - Claude Context

## Overview
Windows NSIS installer for OneShell POS. Bundles MongoDB, NATS, Java backend, Node backend, Python backend, Nginx frontend, and a Monitor dashboard as Windows services managed by WinSW.

## Install Path
`C:\Program Files (x86)\OneShellPOS` (32-bit NSIS)

## Architecture

### Service Dependency Chain
MongoDB → NATS → PosBackend → NodeBackend/PythonBackend/Frontend

### Windows Services (WinSW v3.0.0-alpha.11)
| Service ID | Component | Port | Executable |
|------------|-----------|------|-----------|
| OneShellMongoDB | MongoDB 8.0.4 | 27017 | `mongodb\bin\mongod.exe` |
| OneShellNATS | NATS 2.10.22 | 4222 | `nats\nats-server.exe` |
| OneShellPosBackend | Java 24 Spring Boot | 8090 | `jre\bin\java.exe -jar apps\posbackend\posbackend.jar` |
| OneShellPosNodeBackend | Node 20.18.1 | 3001 | `node\node.exe apps\posNodeBackend\dist\index.js` |
| OneShellPosPythonBackend | Python 3.11.9 | 5200 | `python\python.exe apps\PosPythonBackend\main.py` |
| OneShellFrontend | Nginx 1.26.2 | 80 | `nginx\nginx.exe -p INSTALLDIR -c config\nginx.conf` |
| OneShellMonitor | Node 20.18.1 | 3005 | `monitor\OneShellMonitor.exe` (pkg'd) |

### WinSW `%BASE%` Variable
- `%BASE%` = directory containing the WinSW .exe (the `services/` dir)
- `%BASE%\..` = install dir, but path is NOT normalized (literal `..` remains)
- All service XMLs use `%BASE%\..` to reference the install root

### Key Directories
```
C:\Program Files (x86)\OneShellPOS\
├── apps\posbackend\          # Java JAR
├── apps\posNodeBackend\      # Node.js (dist/index.js = babel output)
├── apps\posFrontend\         # React build output (index.html, static/)
├── apps\PosPythonBackend\    # Python Flask app
├── config\                   # nginx.conf, nats-server.conf, mime.types
├── data\mongodb\             # MongoDB data
├── data\nats\                # NATS JetStream store
├── jre\                      # Java 24 JRE
├── logs\                     # Per-service log dirs
├── mongodb\bin\              # mongod.exe
├── monitor\                  # Monitor dashboard EXE + public/
├── nats\                     # nats-server.exe
├── nginx\                    # nginx.exe
├── node\                     # node.exe, npm
├── python\                   # Python embeddable + wheels
├── services\                 # WinSW exes + XML configs
├── temp\                     # Nginx temp dirs
├── updater\                  # Auto-update bat script
├── version.txt               # Current version
└── vc_redist.x64.exe         # VC++ 2022 Redistributable
```

## Known Issues & Solutions

### MongoDB Exit Code -1073741515 (0xC0000135)
- **Cause**: Missing Visual C++ 2022 x64 Redistributable (STATUS_DLL_NOT_FOUND)
- **Fix**: `vc_redist.x64.exe` must be installed BEFORE MongoDB starts
- **Check**: `Test-Path "C:\Windows\System32\vcruntime140.dll"`
- **Manual fix**: Run `vc_redist.x64.exe /install /quiet /norestart`

### PosNodeBackend "Cannot find module dist/index.js"
- **Cause**: Babel transpile (`npm run build`) was not run during pipeline build
- **Fix**: Pipeline must run `npm run build` which does `npx babel ./src -d ./dist`
- **Check**: `Test-Path "C:\Program Files (x86)\OneShellPOS\apps\posNodeBackend\dist\index.js"`

### Python "No module named encodings"
- **Cause**: `python311._pth` file corrupted (controls sys.path in embeddable Python)
- **Fix**: Rewrite the entire file, don't append. Must contain:
  ```
  python311.zip
  .
  ../apps/PosPythonBackend
  import site
  ```
- **Check**: `Get-Content "C:\Program Files (x86)\OneShellPOS\python\python311._pth"`
- Python embeddable IGNORES `PYTHONPATH` env var unless `import site` is in ._pth

### Nginx "rewrite or internal redirection cycle"
- **Cause**: `root` path wrong in nginx.conf. Must be relative to nginx prefix (install dir)
- **Fix**: `root "apps/posFrontend";` (NOT `../apps/posFrontend`)
- Nginx prefix set via `-p` flag in service XML = install dir

### Nginx temp dirs
- Must exist at `INSTALLDIR\temp\{client_body_temp,proxy_temp,fastcgi_temp,uwsgi_temp,scgi_temp}`
- nginx.conf uses relative paths: `client_body_temp_path temp/client_body_temp;`

### NATS JetStream store_dir
- Must be relative: `store_dir: "data/nats"` (NOT absolute or `../data/nats`)

## Debugging Commands (PowerShell)

```powershell
# Check all services
Get-Service OneShell* | Format-Table Name, Status, StartType

# Check specific service
sc query OneShellMongoDB
sc qc OneShellMongoDB  # show config

# Start/stop
net start OneShellMongoDB
net stop OneShellMongoDB

# View error logs
Get-Content "C:\Program Files (x86)\OneShellPOS\logs\mongodb\OneShellMongoDBService.err.log" -Tail 30
Get-Content "C:\Program Files (x86)\OneShellPOS\logs\posNodeBackend\OneShellPosNodeBackendService.err.log" -Tail 30
Get-Content "C:\Program Files (x86)\OneShellPOS\logs\PosPythonBackend\OneShellPosPythonBackendService.err.log" -Tail 30

# View wrapper logs (WinSW lifecycle)
Get-Content "C:\Program Files (x86)\OneShellPOS\logs\mongodb\OneShellMongoDBService.wrapper.log" -Tail 20

# View diagnostic log (monitor watchdog)
Get-Content "C:\Program Files (x86)\OneShellPOS\logs\oneshell-diagnostic.log" -Tail 50

# Monitor API (when running)
Invoke-RestMethod http://localhost:3005/api/services
Invoke-RestMethod http://localhost:3005/api/diagnostic-log
Invoke-RestMethod http://localhost:3005/api/logs/summary

# Check if VC++ installed
Test-Path "C:\Windows\System32\vcruntime140.dll"
Test-Path "C:\Windows\System32\msvcp140.dll"

# Check python path config
& "C:\Program Files (x86)\OneShellPOS\python\python.exe" -c "import sys; print(sys.path)"

# Check nginx config syntax
& "C:\Program Files (x86)\OneShellPOS\nginx\nginx.exe" -p "C:\Program Files (x86)\OneShellPOS" -c "config\nginx.conf" -t
```

## Build & Pipeline

### Local Build
```bash
cd OneshellInstaller && bash build-installer.sh
```

### Tekton Pipeline
- Triggered by git tags on `OneshellInstaller` repo
- Pipeline: `SetupRelated/cluster_setup/tekton/pipelines/pipeline-oneshell-installer.yaml`
- Publishes installer EXE to `OneShellSolutions/OneshellInstallerExe` GitHub repo (public, for auto-updates)

### Key Build Steps
1. Download runtimes (JRE, Node, Python, MongoDB, NATS, Nginx, WinSW, VC++ Redist)
2. Build Java apps (oneshell-commons → PosClientBackend)
3. Build frontend apps (PosNodeBackend babel, PosFrontend react, PosPythonBackend + wheels)
4. Build Monitor EXE (pkg)
5. Assemble NSIS bundle + configs
6. Build .exe installer with makensis

### Version Bumping
1. Edit `versions.json` → `installer` field
2. Commit and push
3. `git tag vX.Y.Z && git push origin vX.Y.Z`

## Monitor Dashboard (index.js)
- Port 3005, Express.js
- Dev mode: auto-enabled on non-Windows (mocks service status for testing)
- Watchdog: checks services every 30s, auto-restarts stopped ones (respects dependency order)
- Max 10 consecutive restart failures per service before giving up
- 2-minute cooldown between restart attempts per service

## Auto-Updater (updater/update-check.bat)
- Runs via Windows Task Scheduler every 6 hours
- Checks `OneShellSolutions/OneshellInstallerExe` GitHub releases
- Downloads + runs silent install (`/S` flag)
- Throttle: skips if checked < 5 hours ago
- Fail limit: stops after 3 consecutive failures (resets after 24h)
