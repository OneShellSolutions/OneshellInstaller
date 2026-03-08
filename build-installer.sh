#!/usr/bin/env bash
set -euo pipefail

# ============================================
# OneShell POS - Master Installer Builder
#
# This script:
#   1. Downloads all runtimes (JRE 24, Node 20, Python 3.11, MongoDB 8, NATS, Nginx)
#   2. Clones & builds each app repo at specified tags from GitHub
#   3. Packages the monitoring dashboard via `pkg`
#   4. Assembles everything into an NSIS installer (.exe)
#
# Prerequisites:
#   macOS:  brew install makensis node maven
#   Linux:  apt install nsis nodejs maven
#   Both:   npm i -g pkg
#
# Usage:
#   ./build-installer.sh [VERSION]
#
# All versions are read from versions.json (single source of truth)
# App tags can be overridden by environment variables (CI workflow inputs)
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/target/bundle"
CACHE_DIR="$SCRIPT_DIR/target/cache"
REPOS_DIR="$SCRIPT_DIR/target/repos"

# GitHub org
GITHUB_ORG="OneShellSolutions"

# ============================================
# Read all versions from versions.json
# ============================================
VERSIONS_FILE="$SCRIPT_DIR/versions.json"
if [ ! -f "$VERSIONS_FILE" ]; then
    echo "ERROR: versions.json not found at $VERSIONS_FILE"
    exit 1
fi

# Helper to read JSON values (uses python since it's always available)
json_val() {
    python3 -c "import json,sys; d=json.load(open('$VERSIONS_FILE')); print(d$(printf '%s' "$1"))" 2>/dev/null
}

# Version (from arg, or versions.json, or default)
VERSION="${1:-$(json_val "['installer']" || echo "1.0.0")}"

# Runtime versions from versions.json
WINSW_VERSION="$(json_val "['runtimes']['winsw']")"
JRE_VERSION="$(json_val "['runtimes']['jre']")"
NODE_VERSION="$(json_val "['runtimes']['node']")"
PYTHON_VERSION="$(json_val "['runtimes']['python']")"
MONGODB_VERSION="$(json_val "['runtimes']['mongodb']")"
NATS_VERSION="$(json_val "['runtimes']['nats']")"
NGINX_VERSION="$(json_val "['runtimes']['nginx']")"

# ============================================
# Application repos and their versions
#
# Resolution order for each repo:
#   1. Environment variables (set by CI workflow inputs)
#   2. versions.json (if non-empty)
#   3. Latest GitHub release tag (via API)
#   4. Fallback to "master"
# ============================================
APP_REPOS="oneshell-commons PosClientBackend PosNodeBackend PosFrontend PosPythonBackend"

# Helper: get latest release tag from GitHub for a repo
# Uses GITHUB_TOKEN if available (avoids API rate limits in CI)
get_latest_tag() {
    local repo="$1"
    local auth_header=""
    [ -n "${GITHUB_TOKEN:-}" ] && auth_header="-H Authorization: token ${GITHUB_TOKEN}"
    local tag
    # Try latest release first
    tag=$(curl -fsSL $auth_header "https://api.github.com/repos/${GITHUB_ORG}/${repo}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name".*"\(.*\)".*/\1/')
    if [ -z "$tag" ]; then
        # No releases - try latest tag
        tag=$(curl -fsSL $auth_header "https://api.github.com/repos/${GITHUB_ORG}/${repo}/tags?per_page=1" 2>/dev/null \
            | grep '"name"' | head -1 | sed 's/.*"name".*"\(.*\)".*/\1/')
    fi
    echo "${tag:-master}"
}

# Start with env vars (set by CI, or empty)
ONESHELL_COMMONS_TAG="${ONESHELL_COMMONS_TAG:-}"
POS_CLIENT_BACKEND_TAG="${POS_CLIENT_BACKEND_TAG:-}"
POS_NODE_BACKEND_TAG="${POS_NODE_BACKEND_TAG:-}"
POS_FRONTEND_TAG="${POS_FRONTEND_TAG:-}"
POS_PYTHON_BACKEND_TAG="${POS_PYTHON_BACKEND_TAG:-}"

# Resolve tags: env var > versions.json > GitHub API auto-detect
echo ""
echo "Resolving component versions..."
declare -A REPO_TAG_MAP
for repo in $APP_REPOS; do
    # Get env var value
    case "$repo" in
        oneshell-commons)   env_val="$ONESHELL_COMMONS_TAG" ;;
        PosClientBackend)   env_val="$POS_CLIENT_BACKEND_TAG" ;;
        PosNodeBackend)     env_val="$POS_NODE_BACKEND_TAG" ;;
        PosFrontend)        env_val="$POS_FRONTEND_TAG" ;;
        PosPythonBackend)   env_val="$POS_PYTHON_BACKEND_TAG" ;;
    esac

    # Get versions.json value
    json_tag="$(json_val "['applications']['$repo']")"

    if [ -n "$env_val" ]; then
        REPO_TAG_MAP[$repo]="$env_val"
        echo "  $repo = ${env_val} (env override)"
    elif [ -n "$json_tag" ]; then
        REPO_TAG_MAP[$repo]="$json_tag"
        echo "  $repo = ${json_tag} (versions.json)"
    else
        resolved=$(get_latest_tag "$repo")
        REPO_TAG_MAP[$repo]="$resolved"
        echo "  $repo = ${resolved} (auto: latest release)"
    fi
done

# Set variables from resolved map
ONESHELL_COMMONS_TAG="${REPO_TAG_MAP[oneshell-commons]}"
POS_CLIENT_BACKEND_TAG="${REPO_TAG_MAP[PosClientBackend]}"
POS_NODE_BACKEND_TAG="${REPO_TAG_MAP[PosNodeBackend]}"
POS_FRONTEND_TAG="${REPO_TAG_MAP[PosFrontend]}"
POS_PYTHON_BACKEND_TAG="${REPO_TAG_MAP[PosPythonBackend]}"

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
VCREDIST_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"

echo "============================================"
echo " OneShell POS Installer Builder v${VERSION}"
echo "============================================"
echo ""
echo " Component tags:"
echo "   oneshell-commons:    ${ONESHELL_COMMONS_TAG}"
echo "   PosClientBackend:    ${POS_CLIENT_BACKEND_TAG}"
echo "   PosNodeBackend:      ${POS_NODE_BACKEND_TAG}"
echo "   PosFrontend:         ${POS_FRONTEND_TAG}"
echo "   PosPythonBackend:    ${POS_PYTHON_BACKEND_TAG}"
echo ""

# ============================================
# Helpers
# ============================================
download_cached() {
    local url="$1" filename="$2" desc="$3"
    if [ -f "${CACHE_DIR}/${filename}" ]; then
        echo "       Cached: ${desc}"
    else
        echo "       Downloading ${desc}..."
        curl -fsSL -o "${CACHE_DIR}/${filename}" "${url}"
    fi
}

# Clone repo at a specific tag/branch. If already cloned, fetch and checkout.
clone_at_tag() {
    local repo="$1" dir="$2" tag="$3"
    if [ -d "$dir/.git" ]; then
        echo "       Fetching ${repo} (${tag})..."
        git -C "$dir" fetch origin --tags --force
        git -C "$dir" checkout "$tag" 2>/dev/null || git -C "$dir" checkout "origin/$tag" 2>/dev/null || {
            echo "       Tag/branch '$tag' not found, using latest master/main..."
            git -C "$dir" checkout origin/master 2>/dev/null || git -C "$dir" checkout origin/main
        }
    else
        echo "       Cloning ${repo} (${tag})..."
        git clone "https://github.com/${GITHUB_ORG}/${repo}.git" "$dir"
        git -C "$dir" checkout "$tag" 2>/dev/null || git -C "$dir" checkout "origin/$tag" 2>/dev/null || true
    fi
}

# Configure git auth for private repos (CI passes GITHUB_TOKEN)
if [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

# Create directories
mkdir -p "${CACHE_DIR}" "${REPOS_DIR}"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"/{jre,node,python,mongodb/bin,nats,nginx,monitor/public,services,config,updater}
mkdir -p "${BUNDLE_DIR}"/apps/{posbackend,posNodeBackend,posFrontend,PosPythonBackend}

# ============================================
# Step 1: Download runtimes
# ============================================
echo "[1/10] Downloading runtimes..."
download_cached "${WINSW_URL}" "WinSW-x64.exe" "WinSW ${WINSW_VERSION}"
download_cached "${JRE_URL}" "${JRE_ARCHIVE}" "JRE ${JRE_VERSION}"
download_cached "${NODE_URL}" "node-${NODE_VERSION}.zip" "Node.js ${NODE_VERSION}"
download_cached "${PYTHON_URL}" "python-${PYTHON_VERSION}.zip" "Python ${PYTHON_VERSION}"
download_cached "${PYTHON_PIP_URL}" "get-pip.py" "pip installer"
download_cached "${MONGODB_URL}" "mongodb-${MONGODB_VERSION}.zip" "MongoDB ${MONGODB_VERSION}"
download_cached "${NATS_URL}" "nats-${NATS_VERSION}.zip" "NATS ${NATS_VERSION}"
download_cached "${NGINX_URL}" "nginx-${NGINX_VERSION}.zip" "Nginx ${NGINX_VERSION}"
download_cached "${VCREDIST_URL}" "vc_redist.x64.exe" "Visual C++ Redistributable"
if [ ! -f "${CACHE_DIR}/vc_redist.x64.exe" ]; then
    echo "       ERROR: Visual C++ Redistributable download failed. MongoDB 8.0 requires it."
    echo "       Manual download: https://aka.ms/vs/17/release/vc_redist.x64.exe"
    echo "       Place it at: ${CACHE_DIR}/vc_redist.x64.exe"
    exit 1
fi
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
# Fix python311._pth - rewrite to include all needed paths
PTH_FILE="${BUNDLE_DIR}/python/python311._pth"
if [ -f "$PTH_FILE" ]; then
    cat > "$PTH_FILE" << 'PTH_EOF'
python311.zip
.
Lib/site-packages
../apps/PosPythonBackend
import site
PTH_EOF
    echo "       Fixed python311._pth"
fi
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
if [ -n "$NGINX_DIR" ]; then
    cp -r "$NGINX_DIR"/* "${BUNDLE_DIR}/nginx/"
    echo "       Nginx files:"
    ls -la "${BUNDLE_DIR}/nginx/conf/" 2>/dev/null || echo "       (no conf/ dir)"
fi
# Copy mime.types to config dir (nginx resolves includes relative to prefix)
if [ -f "${BUNDLE_DIR}/nginx/conf/mime.types" ]; then
    cp "${BUNDLE_DIR}/nginx/conf/mime.types" "${BUNDLE_DIR}/config/mime.types"
    echo "       Copied mime.types to config dir."
elif NGINX_MIME=$(find "${BUNDLE_DIR}/nginx" -name "mime.types" 2>/dev/null | head -1) && [ -n "$NGINX_MIME" ]; then
    cp "$NGINX_MIME" "${BUNDLE_DIR}/config/mime.types"
    echo "       Copied mime.types from $NGINX_MIME to config dir."
else
    echo "       WARNING: mime.types not found in nginx distribution. Creating default."
    # Minimal mime.types so nginx can start
    cat > "${BUNDLE_DIR}/config/mime.types" << 'MIME_EOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    application/javascript                js;
    application/json                      json;
    image/png                             png;
    image/jpeg                            jpeg jpg;
    image/gif                             gif;
    image/svg+xml                         svg svgz;
    image/x-icon                          ico;
    application/font-woff                 woff;
    application/font-woff2                woff2;
    application/octet-stream              bin exe dll;
}
MIME_EOF
fi
rm -rf "${CACHE_DIR}/nginx-extract"

echo "       Runtimes extracted."

# ============================================
# Step 3: Clone & build oneshell-commons + PosClientBackend (Java)
# ============================================
echo "[3/10] Building PosClientBackend..."

# Build oneshell-commons first (shared library)
echo "       Cloning & building oneshell-commons..."
clone_at_tag "oneshell-commons" "${REPOS_DIR}/oneshell-commons" "${ONESHELL_COMMONS_TAG}"
(cd "${REPOS_DIR}/oneshell-commons" && ./mvnw clean install -DskipTests -q)
echo "       oneshell-commons installed to local Maven."

# Build PosClientBackend
clone_at_tag "PosClientBackend" "${REPOS_DIR}/PosClientBackend" "${POS_CLIENT_BACKEND_TAG}"
echo "       Building PosClientBackend JAR..."
(cd "${REPOS_DIR}/PosClientBackend" && ./mvnw clean package -DskipTests -q)
JAR=$(find "${REPOS_DIR}/PosClientBackend/target" -maxdepth 1 -name "*.jar" ! -name "*-sources*" ! -name "*-javadoc*" ! -name "*-plain*" ! -name "*.original" | head -1)
if [ -n "$JAR" ]; then
    cp "$JAR" "${BUNDLE_DIR}/apps/posbackend/posbackend.jar"
    echo "       PosClientBackend JAR ready."
else
    echo "       ERROR: PosClientBackend JAR not found. Build failed."
    exit 1
fi

# ============================================
# Step 4: Clone PosNodeBackend (Node.js) + install deps
# ============================================
echo "[4/10] Preparing PosNodeBackend..."
clone_at_tag "PosNodeBackend" "${REPOS_DIR}/PosNodeBackend" "${POS_NODE_BACKEND_TAG}"
echo "       Installing Node.js dependencies and building..."
# Install deps with Windows target platform so native modules (sharp) get correct binaries
echo "       Installing Node.js dependencies (targeting Windows x64)..."
(cd "${REPOS_DIR}/PosNodeBackend" && npm install --silent 2>/dev/null)
# Reinstall sharp specifically for Windows (cross-platform install)
echo "       Installing sharp for Windows x64..."
(cd "${REPOS_DIR}/PosNodeBackend" && npm install --os=win32 --cpu=x64 sharp 2>&1) || {
    echo "       WARNING: sharp cross-install failed, trying @img/sharp-win32-x64..."
    (cd "${REPOS_DIR}/PosNodeBackend" && npm install --no-save @img/sharp-win32-x64 2>/dev/null || true)
}
# Remove Linux-specific sharp binaries that won't work on Windows
rm -rf "${REPOS_DIR}/PosNodeBackend/node_modules/@img/sharp-linux"* 2>/dev/null || true
rm -rf "${REPOS_DIR}/PosNodeBackend/node_modules/@img/sharp-linuxmusl"* 2>/dev/null || true
# Build: transpile src/ -> dist/ via Babel
echo "       Transpiling PosNodeBackend..."
(cd "${REPOS_DIR}/PosNodeBackend" && npm run build)
# Verify build output exists
if [ ! -f "${REPOS_DIR}/PosNodeBackend/dist/index.js" ]; then
    echo "       ERROR: PosNodeBackend build failed - dist/index.js not found."
    exit 1
fi
# Copy app files WITH node_modules (pre-installed), exclude dev stuff
# IMPORTANT: Use /src (leading slash) to only exclude top-level src/ directory
# Without the slash, rsync excludes ALL 'src' dirs including node_modules/debug/src/
rsync -a --exclude='.git' --exclude='.env' --exclude='.github' --exclude='/src' \
    "${REPOS_DIR}/PosNodeBackend/" "${BUNDLE_DIR}/apps/posNodeBackend/"
# Verify dist/index.js made it into the bundle
if [ ! -f "${BUNDLE_DIR}/apps/posNodeBackend/dist/index.js" ]; then
    echo "       ERROR: dist/index.js not found in bundle after rsync!"
    echo "       Check that npm run build succeeded and rsync didn't skip dist/"
    exit 1
fi
echo "       PosNodeBackend ready (with node_modules and dist/)."

# ============================================
# Step 5: Clone & build PosFrontend (React)
# ============================================
echo "[5/10] Building PosFrontend..."
clone_at_tag "PosFrontend" "${REPOS_DIR}/PosFrontend" "${POS_FRONTEND_TAG}"
echo "       Installing frontend dependencies..."
(cd "${REPOS_DIR}/PosFrontend" && npm install --silent 2>/dev/null)
echo "       Building frontend..."
(cd "${REPOS_DIR}/PosFrontend" && npm run build)

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
    echo "       ERROR: PosFrontend build output not found."
    exit 1
fi

# ============================================
# Step 6: Clone PosPythonBackend + install deps into bundle
# ============================================
echo "[6/10] Preparing PosPythonBackend..."
clone_at_tag "PosPythonBackend" "${REPOS_DIR}/PosPythonBackend" "${POS_PYTHON_BACKEND_TAG}"
rsync -a --exclude='.git' --exclude='__pycache__' --exclude='.env' --exclude='venv' \
    "${REPOS_DIR}/PosPythonBackend/" "${BUNDLE_DIR}/apps/PosPythonBackend/"

# Pre-download Python wheels for offline install on customer machine
echo "       Downloading Python wheels for offline install..."
mkdir -p "${CACHE_DIR}/python-wheels" "${BUNDLE_DIR}/python/wheels"
if [ -f "${BUNDLE_DIR}/apps/PosPythonBackend/requirements.txt" ]; then
    # Download pip + setuptools wheels (needed for get-pip.py offline)
    echo "       Downloading pip/setuptools wheels..."
    pip download pip setuptools wheel \
        --dest "${CACHE_DIR}/python-wheels" \
        --platform win_amd64 --python-version 3.11 --only-binary=:all: 2>/dev/null || \
    pip download pip setuptools wheel \
        --dest "${CACHE_DIR}/python-wheels" 2>/dev/null || true

    # Download all dependency wheels for Windows
    echo "       Downloading app dependency wheels..."
    # First try: platform-specific Windows wheels only
    pip download -r "${BUNDLE_DIR}/apps/PosPythonBackend/requirements.txt" \
        --dest "${CACHE_DIR}/python-wheels" \
        --platform win_amd64 --python-version 3.11 --only-binary=:all: 2>/dev/null || \
    # Second try: allow platform-specific + pure Python wheels (no source dists)
    pip download -r "${BUNDLE_DIR}/apps/PosPythonBackend/requirements.txt" \
        --dest "${CACHE_DIR}/python-wheels" \
        --platform win_amd64 --python-version 3.11 --no-deps 2>/dev/null; \
    pip download -r "${BUNDLE_DIR}/apps/PosPythonBackend/requirements.txt" \
        --dest "${CACHE_DIR}/python-wheels" \
        --only-binary=:all: 2>/dev/null || \
    # Last resort: download anything available (may include source dists)
    pip download -r "${BUNDLE_DIR}/apps/PosPythonBackend/requirements.txt" \
        --dest "${CACHE_DIR}/python-wheels" 2>/dev/null || true

    cp "${CACHE_DIR}/python-wheels/"* "${BUNDLE_DIR}/python/wheels/" 2>/dev/null || true

    # ---- Verify critical wheels are present ----
    WHEEL_COUNT=$(ls -1 "${BUNDLE_DIR}/python/wheels/"*.whl 2>/dev/null | wc -l)
    PIP_WHEEL=$(ls -1 "${BUNDLE_DIR}/python/wheels/pip"*.whl 2>/dev/null | head -1)
    FLASK_WHEEL=$(ls -1 "${BUNDLE_DIR}/python/wheels/"[Ff]lask*.whl 2>/dev/null | head -1)
    echo "       Wheels bundled: ${WHEEL_COUNT} files"
    if [ -z "$PIP_WHEEL" ]; then
        echo "       WARNING: pip wheel not found in bundle! Offline pip bootstrap will fail."
        echo "       The installer will fall back to online get-pip.py (requires internet on target)."
    fi
    if [ -z "$FLASK_WHEEL" ]; then
        echo "       WARNING: Flask wheel not found in bundle! PosPythonBackend offline install may fail."
        echo "       The installer will fall back to online pip install (requires internet on target)."
    fi
    echo "       Python wheels ready for offline install."
else
    echo "       WARNING: requirements.txt not found! Skipping wheel download."
    echo "       PosPythonBackend will need online pip install on target machine."
fi

# Verify get-pip.py is in the bundle (critical for pip bootstrapping)
if [ ! -f "${BUNDLE_DIR}/python/get-pip.py" ]; then
    echo "       ERROR: get-pip.py not found in bundle! Downloading..."
    curl -fsSL -o "${BUNDLE_DIR}/python/get-pip.py" "https://bootstrap.pypa.io/get-pip.py"
    if [ ! -f "${BUNDLE_DIR}/python/get-pip.py" ]; then
        echo "       CRITICAL: Failed to download get-pip.py. pip cannot be bootstrapped on target!"
        exit 1
    fi
fi
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

# Step 8: (removed - tray app no longer bundled)

# ============================================
# Step 9: Assemble bundle
# ============================================
echo "[9/10] Assembling bundle..."

# Icon (from repo's public/ folder)
if [ -f "$SCRIPT_DIR/public/icon.ico" ]; then
    cp "$SCRIPT_DIR/public/icon.ico" "${BUNDLE_DIR}/icon.ico"
elif [ -f "$SCRIPT_DIR/public/logo.ico" ]; then
    cp "$SCRIPT_DIR/public/logo.ico" "${BUNDLE_DIR}/icon.ico"
else
    echo "       WARNING: No icon.ico found in public/. Add public/icon.ico to the repo."
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
  listen: "0.0.0.0:9080"
  no_tls: true
  compression: true
}

jetstream {
  store_dir: "data/nats"
}
NATS_EOF

# Nginx config
cat > "${BUNDLE_DIR}/config/nginx.conf" << 'NGINX_EOF'
worker_processes  1;
pid               nginx/logs/nginx.pid;
error_log         logs/nginx/error.log;

events { worker_connections  1024; }

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout  65;
    client_max_body_size 100m;
    access_log    logs/nginx/access.log;

    client_body_temp_path temp/client_body_temp;
    proxy_temp_path       temp/proxy_temp;
    fastcgi_temp_path     temp/fastcgi_temp;
    uwsgi_temp_path       temp/uwsgi_temp;
    scgi_temp_path        temp/scgi_temp;

    server {
        listen       80;
        server_name  localhost;
        root   "apps/posFrontend";
        index  index.html;

        # SPA routing: serve file if exists, otherwise fall back to index.html
        # Uses named location to prevent infinite redirect loop if index.html is missing
        location / {
            try_files $uri $uri/ @spa_fallback;
        }

        location @spa_fallback {
            rewrite ^ /index.html break;
        }

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

# Visual C++ Redistributable (required by MongoDB 8.0)
cp "${CACHE_DIR}/vc_redist.x64.exe" "${BUNDLE_DIR}/" 2>/dev/null || true

# Print utility (optional - only if present in repo)
[ -f "$SCRIPT_DIR/assets/oneshell-print-util-win.exe" ] && cp "$SCRIPT_DIR/assets/oneshell-print-util-win.exe" "${BUNDLE_DIR}/"

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

# Write manifest with all component info
cat > "${BUNDLE_DIR}/manifest.json" << MANIFEST_EOF
{
  "version": "${VERSION}",
  "buildDate": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "runtimes": {
    "jre": "${JRE_VERSION}",
    "node": "${NODE_VERSION}",
    "python": "${PYTHON_VERSION}",
    "mongodb": "${MONGODB_VERSION}",
    "nats": "${NATS_VERSION}",
    "nginx": "${NGINX_VERSION}"
  },
  "components": {
    "oneshell-commons": "${ONESHELL_COMMONS_TAG}",
    "PosClientBackend": "${POS_CLIENT_BACKEND_TAG}",
    "PosNodeBackend": "${POS_NODE_BACKEND_TAG}",
    "PosFrontend": "${POS_FRONTEND_TAG}",
    "PosPythonBackend": "${POS_PYTHON_BACKEND_TAG}"
  }
}
MANIFEST_EOF

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
    echo "  NSIS not found. Install: brew install makensis (macOS) or apt install nsis (Linux)"
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
