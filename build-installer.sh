#!/usr/bin/env bash
set -euo pipefail

# ============================================
# OneShell POS - Master Installer Builder
#
# This script:
#   1. Downloads all runtimes (JRE 24, Node 20, Python 3.11, MongoDB 8, NATS)
#   2. Clones & builds each app from GitHub repos
#   3. Packages the monitoring dashboard + tray icon via `pkg`
#   4. Assembles everything into an NSIS installer (Windows only)
#
# Prerequisites:
#   macOS:  brew install makensis node maven
#   Linux:  apt install nsis nodejs maven
#
# Usage:
#   ./build-installer.sh [VERSION]
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/target/bundle"
CACHE_DIR="$SCRIPT_DIR/target/cache"
REPOS_DIR="$SCRIPT_DIR/target/repos"

# Version
VERSION="${1:-$(cat "$SCRIPT_DIR/version.txt" 2>/dev/null || echo "1.0.0")}"

# GitHub org
GITHUB_ORG="OneShellSolutions"

# ============================================
# Dependency versions
# ============================================
WINSW_VERSION="3.0.0-alpha.11"
JRE_VERSION="24+36"
NODE_VERSION="20.18.1"
PYTHON_VERSION="3.11.9"
MONGODB_VERSION="8.0.4"
NATS_VERSION="2.10.22"
NGINX_VERSION="1.26.2"

# Download URLs
WINSW_URL="https://github.com/winsw/winsw/releases/download/v${WINSW_VERSION}/WinSW-x64.exe"
JRE_ARCHIVE="OpenJDK24U-jre_x64_windows_hotspot_$(echo $JRE_VERSION | tr '+' '_').zip"
JRE_URL="https://github.com/adoptium/temurin24-binaries/releases/download/jdk-${JRE_VERSION}/${JRE_ARCHIVE}"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-win-x64.zip"
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-embed-amd64.zip"
PYTHON_PIP_URL="https://bootstrap.pypa.io/get-pip.py"
MONGODB_URL="https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-${MONGODB_VERSION}.zip"
NATS_URL="https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/nats-server-v${NATS_VERSION}-windows-amd64.zip"
NGINX_URL="https://nginx.org/download/nginx-${NGINX_VERSION}.zip"

echo "============================================"
echo " OneShell POS Installer Builder v${VERSION}"
echo "============================================"
echo ""

# Helpers
download_cached() {
    local url="$1" filename="$2" desc="$3"
    if [ -f "${CACHE_DIR}/${filename}" ]; then
        echo "       Cached: ${desc}"
    else
        echo "       Downloading ${desc}..."
        curl -fsSL -o "${CACHE_DIR}/${filename}" "${url}"
    fi
}

clone_or_pull() {
    local repo="$1" dir="$2"
    if [ -d "$dir/.git" ]; then
        echo "       Pulling latest ${repo}..."
        git -C "$dir" fetch origin && git -C "$dir" reset --hard origin/master 2>/dev/null || git -C "$dir" reset --hard origin/main
    else
        echo "       Cloning ${repo}..."
        git clone --depth 1 "https://github.com/${GITHUB_ORG}/${repo}.git" "$dir"
    fi
}

# Create directories
mkdir -p "${CACHE_DIR}" "${REPOS_DIR}"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"/{jre,node,python,mongodb/bin,nats,nginx,monitor/public,tray,services,config,updater}
mkdir -p "${BUNDLE_DIR}"/apps/{posbackend,posNodeBackend,posFrontend,PosPythonBackend}

# ============================================
# Step 1: Download runtimes
# ============================================
echo "[1/10] Downloading runtimes..."
download_cached "${WINSW_URL}" "WinSW-x64.exe" "WinSW ${WINSW_VERSION}"
download_cached "${JRE_URL}" "${JRE_ARCHIVE}" "JRE 24"
download_cached "${NODE_URL}" "node-${NODE_VERSION}.zip" "Node.js ${NODE_VERSION}"
download_cached "${PYTHON_URL}" "python-${PYTHON_VERSION}.zip" "Python ${PYTHON_VERSION}"
download_cached "${PYTHON_PIP_URL}" "get-pip.py" "pip installer"
download_cached "${MONGODB_URL}" "mongodb-${MONGODB_VERSION}.zip" "MongoDB ${MONGODB_VERSION}"
download_cached "${NATS_URL}" "nats-${NATS_VERSION}.zip" "NATS ${NATS_VERSION}"
download_cached "${NGINX_URL}" "nginx-${NGINX_VERSION}.zip" "Nginx ${NGINX_VERSION}"
echo "       All runtimes ready."

# ============================================
# Step 2: Extract runtimes into bundle
# ============================================
echo "[2/10] Extracting runtimes..."

# JRE
rm -rf "${CACHE_DIR}/jre-extract"
unzip -qo "${CACHE_DIR}/${JRE_ARCHIVE}" -d "${CACHE_DIR}/jre-extract"
cp -r "${CACHE_DIR}"/jre-extract/jdk-*/* "${BUNDLE_DIR}/jre/"
rm -rf "${CACHE_DIR}/jre-extract"

# Node.js
rm -rf "${CACHE_DIR}/node-extract"
unzip -qo "${CACHE_DIR}/node-${NODE_VERSION}.zip" -d "${CACHE_DIR}/node-extract"
cp -r "${CACHE_DIR}"/node-extract/node-*/* "${BUNDLE_DIR}/node/"
rm -rf "${CACHE_DIR}/node-extract"

# Python (embeddable)
rm -rf "${CACHE_DIR}/python-extract"
mkdir -p "${CACHE_DIR}/python-extract"
unzip -qo "${CACHE_DIR}/python-${PYTHON_VERSION}.zip" -d "${CACHE_DIR}/python-extract"
cp -r "${CACHE_DIR}/python-extract/"* "${BUNDLE_DIR}/python/"
cp "${CACHE_DIR}/get-pip.py" "${BUNDLE_DIR}/python/"
# Enable pip: uncomment "import site" in ._pth file
PTH=$(ls "${BUNDLE_DIR}/python/"python*._pth 2>/dev/null | head -1)
[ -n "$PTH" ] && sed -i.bak 's/#import site/import site/' "$PTH" && rm -f "${PTH}.bak"
rm -rf "${CACHE_DIR}/python-extract"

# MongoDB
rm -rf "${CACHE_DIR}/mongodb-extract"
unzip -qo "${CACHE_DIR}/mongodb-${MONGODB_VERSION}.zip" -d "${CACHE_DIR}/mongodb-extract"
MONGO_BIN=$(find "${CACHE_DIR}/mongodb-extract" -name "mongod.exe" -exec dirname {} \; | head -1)
[ -n "$MONGO_BIN" ] && cp "$MONGO_BIN"/*.exe "${BUNDLE_DIR}/mongodb/bin/" 2>/dev/null || true
rm -rf "${CACHE_DIR}/mongodb-extract"

# NATS
rm -rf "${CACHE_DIR}/nats-extract"
unzip -qo "${CACHE_DIR}/nats-${NATS_VERSION}.zip" -d "${CACHE_DIR}/nats-extract"
NATS_EXE=$(find "${CACHE_DIR}/nats-extract" -name "nats-server.exe" | head -1)
[ -n "$NATS_EXE" ] && cp "$NATS_EXE" "${BUNDLE_DIR}/nats/"
rm -rf "${CACHE_DIR}/nats-extract"

# Nginx
rm -rf "${CACHE_DIR}/nginx-extract"
unzip -qo "${CACHE_DIR}/nginx-${NGINX_VERSION}.zip" -d "${CACHE_DIR}/nginx-extract"
NGINX_DIR=$(find "${CACHE_DIR}/nginx-extract" -name "nginx.exe" -exec dirname {} \; | head -1)
[ -n "$NGINX_DIR" ] && cp -r "$NGINX_DIR"/* "${BUNDLE_DIR}/nginx/"
rm -rf "${CACHE_DIR}/nginx-extract"

echo "       Runtimes extracted."

# ============================================
# Step 3: Clone & build PosClientBackend (Java)
# ============================================
echo "[3/10] Building PosClientBackend..."
clone_or_pull "PosClientBackend" "${REPOS_DIR}/PosClientBackend"

# Build oneshell-commons first if needed
if [ -d "/Users/manip/Documents/codeRepo/oneshell-commons" ]; then
    echo "       Building oneshell-commons..."
    (cd /Users/manip/Documents/codeRepo/oneshell-commons && ./mvnw clean install -DskipTests -q 2>/dev/null || true)
fi

echo "       Building PosClientBackend JAR..."
(cd "${REPOS_DIR}/PosClientBackend" && ./mvnw clean package -DskipTests -q 2>/dev/null)
JAR=$(find "${REPOS_DIR}/PosClientBackend/target" -name "*.jar" ! -name "*-sources*" ! -name "*-javadoc*" | head -1)
if [ -n "$JAR" ]; then
    cp "$JAR" "${BUNDLE_DIR}/apps/posbackend/posbackend.jar"
    echo "       PosClientBackend JAR ready."
else
    echo "       WARNING: PosClientBackend JAR not found. Build may have failed."
fi

# ============================================
# Step 4: Clone PosNodeBackend (Node.js)
# ============================================
echo "[4/10] Preparing PosNodeBackend..."
clone_or_pull "PosNodeBackend" "${REPOS_DIR}/PosNodeBackend"
# Copy app files (exclude .git, node_modules)
rsync -a --exclude='.git' --exclude='node_modules' --exclude='.env' \
    "${REPOS_DIR}/PosNodeBackend/" "${BUNDLE_DIR}/apps/posNodeBackend/"
echo "       PosNodeBackend ready."

# ============================================
# Step 5: Clone & build PosFrontend (React)
# ============================================
echo "[5/10] Building PosFrontend..."
clone_or_pull "PosFrontend" "${REPOS_DIR}/PosFrontend"
echo "       Installing frontend dependencies..."
(cd "${REPOS_DIR}/PosFrontend" && npm install --silent 2>/dev/null)
echo "       Building frontend..."
(cd "${REPOS_DIR}/PosFrontend" && npm run build 2>/dev/null || npm run build-electron 2>/dev/null || true)

# Find build output
BUILD_DIR=""
for dir in build dist out; do
    if [ -d "${REPOS_DIR}/PosFrontend/$dir" ]; then
        BUILD_DIR="${REPOS_DIR}/PosFrontend/$dir"
        break
    fi
done
if [ -n "$BUILD_DIR" ]; then
    cp -r "$BUILD_DIR"/* "${BUNDLE_DIR}/apps/posFrontend/"
    echo "       PosFrontend build ready."
else
    echo "       WARNING: PosFrontend build output not found."
fi

# ============================================
# Step 6: Clone PosPythonBackend
# ============================================
echo "[6/10] Preparing PosPythonBackend..."
clone_or_pull "PosPythonBackend" "${REPOS_DIR}/PosPythonBackend"
rsync -a --exclude='.git' --exclude='__pycache__' --exclude='.env' --exclude='venv' \
    "${REPOS_DIR}/PosPythonBackend/" "${BUNDLE_DIR}/apps/PosPythonBackend/"
echo "       PosPythonBackend ready."

# ============================================
# Step 7: Build Monitor Dashboard (pkg → EXE)
# ============================================
echo "[7/10] Building Monitor Dashboard..."
(cd "$SCRIPT_DIR" && npm install --silent 2>/dev/null)
if command -v pkg &>/dev/null || npx pkg --version &>/dev/null 2>&1; then
    (cd "$SCRIPT_DIR" && npx pkg -t node18-win-x64 -o "${BUNDLE_DIR}/monitor/OneShellMonitor.exe" . 2>/dev/null)
    echo "       Monitor EXE built."
else
    echo "       WARNING: pkg not available. Install with: npm i -g pkg"
    echo "       Falling back to copying source files."
    cp "$SCRIPT_DIR/index.js" "${BUNDLE_DIR}/monitor/"
    cp "$SCRIPT_DIR/package.json" "${BUNDLE_DIR}/monitor/"
fi
cp -r "$SCRIPT_DIR/public/"* "${BUNDLE_DIR}/monitor/public/"

# ============================================
# Step 8: Build Tray App (pkg → EXE)
# ============================================
echo "[8/10] Building Tray App..."
if command -v pkg &>/dev/null || npx pkg --version &>/dev/null 2>&1; then
    (cd "$SCRIPT_DIR" && npx pkg -t node18-win-x64 -o "${BUNDLE_DIR}/tray/OneShellTray.exe" tray.js 2>/dev/null)
    echo "       Tray EXE built."
else
    echo "       WARNING: pkg not available. Copying source file."
    cp "$SCRIPT_DIR/tray.js" "${BUNDLE_DIR}/tray/"
fi

# ============================================
# Step 9: Assemble bundle
# ============================================
echo "[9/10] Assembling bundle..."

# Icon
ICON_SRC=""
for src in "$SCRIPT_DIR/public/logo.ico" "/Users/manip/Documents/codeRepo/pos-deployment/logo.ico"; do
    if [ -f "$src" ]; then ICON_SRC="$src"; break; fi
done
if [ -n "$ICON_SRC" ]; then
    cp "$ICON_SRC" "${BUNDLE_DIR}/icon.ico"
else
    echo "       WARNING: No icon.ico found."
fi

# WinSW service wrappers
for svc in OneShellMongoDBService OneShellNATSService OneShellPosBackendService OneShellPosNodeBackendService OneShellPosPythonBackendService OneShellFrontendService OneShellMonitorService; do
    cp "${CACHE_DIR}/WinSW-x64.exe" "${BUNDLE_DIR}/services/${svc}.exe"
    cp "${SCRIPT_DIR}/services/${svc}.xml" "${BUNDLE_DIR}/services/${svc}.xml"
done

# NATS config
cat > "${BUNDLE_DIR}/config/nats-server.conf" << 'NATS_EOF'
max_payload: 100MB
max_pending: 150MB

websocket {
  listen: "0.0.0.0:8080"
  no_tls: true
  compression: true
}

jetstream {
  store_dir: "C:/Program Files/OneShellPOS/data/nats"
}
NATS_EOF

# Nginx config
cat > "${BUNDLE_DIR}/config/nginx.conf" << 'NGINX_EOF'
worker_processes  1;
events { worker_connections  1024; }

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout  65;
    client_max_body_size 100m;

    server {
        listen       80;
        server_name  localhost;
        root   "../apps/posFrontend";
        index  index.html;

        location / { try_files $uri $uri/ /index.html; }

        location /pos/ {
            proxy_pass http://127.0.0.1:8090;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
        }

        location /api/ {
            proxy_pass http://127.0.0.1:3001;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
        }

        location /api/assistant/ {
            proxy_pass http://127.0.0.1:5200;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
        }
    }
}
NGINX_EOF

# Updater
cp "$SCRIPT_DIR/updater/update-check.bat" "${BUNDLE_DIR}/updater/"

# Print utility
PRINT_UTIL="/Users/manip/Documents/codeRepo/pos-deployment/oneshell-print-util-win.exe"
[ -f "$PRINT_UTIL" ] && cp "$PRINT_UTIL" "${BUNDLE_DIR}/"

# Management scripts
cat > "${BUNDLE_DIR}/Start-OneShell.bat" << 'BAT'
@echo off
echo Starting OneShell POS Services...
net start "OneShellMongoDB"
timeout /t 5 /nobreak > nul
net start "OneShellNATS"
timeout /t 2 /nobreak > nul
net start "OneShellPosBackend"
timeout /t 3 /nobreak > nul
net start "OneShellPosNodeBackend"
net start "OneShellPosPythonBackend"
net start "OneShellFrontend"
net start "OneShellMonitor"
echo All services started. Opening monitor...
start http://localhost:3005
pause
BAT

cat > "${BUNDLE_DIR}/Stop-OneShell.bat" << 'BAT'
@echo off
echo Stopping OneShell POS Services...
net stop "OneShellMonitor"
net stop "OneShellFrontend"
net stop "OneShellPosPythonBackend"
net stop "OneShellPosNodeBackend"
net stop "OneShellPosBackend"
net stop "OneShellNATS"
net stop "OneShellMongoDB"
echo All services stopped.
pause
BAT

cat > "${BUNDLE_DIR}/Status-OneShell.bat" << 'BAT'
@echo off
echo.
echo === OneShell POS Service Status ===
echo.
for %%s in (OneShellMongoDB OneShellNATS OneShellPosBackend OneShellPosNodeBackend OneShellPosPythonBackend OneShellFrontend OneShellMonitor) do (
    sc query "%%s" 2>nul | findstr "STATE"
    echo   %%s
)
echo.
start http://localhost:3005
pause
BAT

# Write version files into each app dir
for app in posbackend posNodeBackend posFrontend PosPythonBackend; do
    echo "${VERSION}" > "${BUNDLE_DIR}/apps/${app}/version.txt"
done

echo "       Bundle assembled."

# ============================================
# Step 10: Build NSIS installer
# ============================================
echo "[10/10] Building NSIS installer..."
if command -v makensis &>/dev/null; then
    MAKENSIS=makensis
elif [ -f "/usr/local/bin/makensis" ]; then
    MAKENSIS=/usr/local/bin/makensis
else
    echo ""
    echo "  NSIS not found. Install: brew install makensis"
    echo "  Bundle is ready at: ${BUNDLE_DIR}"
    echo "  Run manually:"
    echo "    makensis -DVERSION=${VERSION} -DBUNDLE_DIR=${BUNDLE_DIR} installer.nsi"
    exit 0
fi

${MAKENSIS} -DVERSION="${VERSION}" -DBUNDLE_DIR="${BUNDLE_DIR}" "${SCRIPT_DIR}/installer.nsi"

echo ""
echo "============================================"
echo " BUILD SUCCESSFUL!"
echo " Output: target/OneShellPOS-Setup-${VERSION}.exe"
echo "============================================"
echo ""
echo " To release:"
echo "   1. git tag v${VERSION}"
echo "   2. gh release create v${VERSION} target/OneShellPOS-Setup-${VERSION}.exe"
echo "   3. Customers auto-update within 1 hour"
echo ""
