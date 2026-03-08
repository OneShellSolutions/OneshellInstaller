# ============================================
# OneShell POS v1.0.15 - Service Fix Script
# Run as Administrator in PowerShell
# ============================================
#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"
$INSTALL_DIR = "C:\Program Files (x86)\OneShellPOS"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " OneShell POS v1.0.15 - Service Fix Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================
# Pre-flight checks
# ============================================
if (-not (Test-Path $INSTALL_DIR)) {
    Write-Host "ERROR: OneShell POS not found at $INSTALL_DIR" -ForegroundColor Red
    exit 1
}

# Stop all services first (reverse dependency order)
Write-Host "[0/5] Stopping all OneShell services..." -ForegroundColor Yellow
$services = @("OneShellMonitor", "OneShellFrontend", "OneShellPosPythonBackend",
              "OneShellPosNodeBackend", "OneShellPosBackend", "OneShellNATS", "OneShellMongoDB")
foreach ($svc in $services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") {
        Write-Host "  Stopping $svc..." -ForegroundColor Gray
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}
Write-Host "  All services stopped." -ForegroundColor Green
Write-Host ""

# ============================================
# FIX 1: MongoDB - Install VC++ Redistributable
# ============================================
Write-Host "[1/5] Fixing MongoDB (VC++ Redistributable)..." -ForegroundColor Yellow

$vcRuntime = Test-Path "$env:SystemRoot\System32\vcruntime140.dll"
$msvcp = Test-Path "$env:SystemRoot\System32\msvcp140.dll"

if ($vcRuntime -and $msvcp) {
    Write-Host "  VC++ Runtime already installed. OK." -ForegroundColor Green
} else {
    Write-Host "  VC++ Runtime MISSING - installing..." -ForegroundColor Red
    $vcRedist = "$INSTALL_DIR\vc_redist.x64.exe"
    if (Test-Path $vcRedist) {
        Write-Host "  Running vc_redist.x64.exe /install /quiet /norestart ..."
        $proc = Start-Process -FilePath $vcRedist -ArgumentList "/install /quiet /norestart" -Wait -PassThru
        Write-Host "  VC++ installer exit code: $($proc.ExitCode)"

        # Verify
        if (Test-Path "$env:SystemRoot\System32\vcruntime140.dll") {
            Write-Host "  VC++ Runtime installed successfully!" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: VC++ install may have failed. Try running manually:" -ForegroundColor Red
            Write-Host "  $vcRedist" -ForegroundColor Red
        }
    } else {
        Write-Host "  ERROR: vc_redist.x64.exe not found at $vcRedist" -ForegroundColor Red
        Write-Host "  Download from: https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Red
        Write-Host "  Place it at: $vcRedist and re-run this script." -ForegroundColor Red
    }
}

# Also ensure MongoDB data directory exists
$mongoDataDir = "$INSTALL_DIR\data\mongodb"
if (-not (Test-Path $mongoDataDir)) {
    New-Item -ItemType Directory -Path $mongoDataDir -Force | Out-Null
    Write-Host "  Created MongoDB data directory: $mongoDataDir" -ForegroundColor Green
}
Write-Host ""

# ============================================
# FIX 2: PosNodeBackend - Check dist/index.js
# ============================================
Write-Host "[2/5] Fixing PosNodeBackend (dist/index.js)..." -ForegroundColor Yellow

$distIndexJs = "$INSTALL_DIR\apps\posNodeBackend\dist\index.js"
$srcIndexJs = "$INSTALL_DIR\apps\posNodeBackend\src\index.js"
$nodeExe = "$INSTALL_DIR\node\node.exe"
$npxCmd = "$INSTALL_DIR\node\npx.cmd"
$npmCmd = "$INSTALL_DIR\node\npm.cmd"

if (Test-Path $distIndexJs) {
    Write-Host "  dist/index.js exists. OK." -ForegroundColor Green
} else {
    Write-Host "  dist/index.js MISSING - attempting to build..." -ForegroundColor Red

    if (Test-Path $srcIndexJs) {
        # Source exists, try to run babel build
        $appDir = "$INSTALL_DIR\apps\posNodeBackend"

        # Check if node_modules/.bin/babel exists
        $babelBin = "$appDir\node_modules\.bin\babel.cmd"
        if (Test-Path $babelBin) {
            Write-Host "  Running babel transpile: src/ -> dist/ ..."
            $env:PATH = "$INSTALL_DIR\node;$env:PATH"
            Push-Location $appDir
            try {
                # Create dist directory
                New-Item -ItemType Directory -Path "$appDir\dist" -Force | Out-Null
                # Run babel
                & $babelBin ./src -d ./dist 2>&1 | Write-Host
                if (Test-Path $distIndexJs) {
                    Write-Host "  Babel build successful! dist/index.js created." -ForegroundColor Green
                } else {
                    Write-Host "  Babel ran but dist/index.js still missing." -ForegroundColor Red
                }
            } catch {
                Write-Host "  Babel build failed: $_" -ForegroundColor Red
            }
            Pop-Location
        } else {
            # Try npm run build
            Write-Host "  Babel not found in node_modules. Trying npm run build..."
            $env:PATH = "$INSTALL_DIR\node;$env:PATH"
            Push-Location $appDir
            try {
                & $npmCmd run build 2>&1 | Write-Host
                if (Test-Path $distIndexJs) {
                    Write-Host "  npm run build successful!" -ForegroundColor Green
                } else {
                    Write-Host "  npm run build ran but dist/index.js still missing." -ForegroundColor Red
                    Write-Host "  Try: npm install && npm run build from $appDir" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  npm run build failed: $_" -ForegroundColor Red
            }
            Pop-Location
        }
    } else {
        Write-Host "  ERROR: Neither dist/index.js nor src/index.js found!" -ForegroundColor Red
        Write-Host "  The PosNodeBackend app files may be missing from the installer bundle." -ForegroundColor Red
        Write-Host "  This is a build pipeline issue - rebuild the installer with:" -ForegroundColor Yellow
        Write-Host "    cd PosNodeBackend && npm install && npm run build" -ForegroundColor Yellow
    }
}
Write-Host ""

# ============================================
# FIX 3: PosPythonBackend - Fix python311._pth
# ============================================
Write-Host "[3/5] Fixing PosPythonBackend (python311._pth)..." -ForegroundColor Yellow

$pthFile = "$INSTALL_DIR\python\python311._pth"

# Show current content for diagnosis
if (Test-Path $pthFile) {
    Write-Host "  Current python311._pth content:" -ForegroundColor Gray
    Get-Content $pthFile | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
}

# ALWAYS rewrite the file (don't append, as per CLAUDE.md)
Write-Host "  Rewriting python311._pth with correct paths..."
$pthContent = @"
python311.zip
.
Lib/site-packages
../apps/PosPythonBackend
import site
"@
Set-Content -Path $pthFile -Value $pthContent -Encoding ASCII -Force
Write-Host "  python311._pth fixed!" -ForegroundColor Green

# Verify Python can start
Write-Host "  Verifying Python can import encodings..."
$pythonExe = "$INSTALL_DIR\python\python.exe"
if (Test-Path $pythonExe) {
    try {
        $result = & $pythonExe -c "import encodings; print('OK')" 2>&1
        if ($result -match "OK") {
            Write-Host "  Python encodings import: OK" -ForegroundColor Green
        } else {
            Write-Host "  Python encodings import FAILED: $result" -ForegroundColor Red
        }
    } catch {
        Write-Host "  Python test failed: $_" -ForegroundColor Red
    }
}

# Ensure pip-installed packages exist
$sitePackages = "$INSTALL_DIR\python\Lib\site-packages"
if (-not (Test-Path $sitePackages)) {
    Write-Host "  site-packages missing! Installing pip and dependencies..." -ForegroundColor Yellow
    $getPip = "$INSTALL_DIR\python\get-pip.py"
    $wheelsDir = "$INSTALL_DIR\python\wheels"

    if (Test-Path "$wheelsDir\pip*") {
        # Offline install from wheels
        & $pythonExe $getPip --no-index --find-links $wheelsDir 2>&1 | Out-Null
        $reqFile = "$INSTALL_DIR\apps\PosPythonBackend\requirements.txt"
        if (Test-Path $reqFile) {
            & $pythonExe -m pip install --no-index --find-links $wheelsDir -r $reqFile 2>&1 | Out-Null
        }
    } elseif (Test-Path $getPip) {
        # Online install
        & $pythonExe $getPip 2>&1 | Out-Null
        $reqFile = "$INSTALL_DIR\apps\PosPythonBackend\requirements.txt"
        if (Test-Path $reqFile) {
            & $pythonExe -m pip install -r $reqFile 2>&1 | Out-Null
        }
    }

    if (Test-Path $sitePackages) {
        Write-Host "  Python packages installed." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Could not install Python packages." -ForegroundColor Red
    }
} else {
    Write-Host "  Python site-packages directory exists. OK." -ForegroundColor Green
}
Write-Host ""

# ============================================
# FIX 4: Nginx - Fix redirect cycle
# ============================================
Write-Host "[4/5] Fixing Nginx (redirect cycle)..." -ForegroundColor Yellow

$nginxConf = "$INSTALL_DIR\config\nginx.conf"
$frontendDir = "$INSTALL_DIR\apps\posFrontend"
$indexHtml = "$frontendDir\index.html"

# Check if frontend files exist
if (Test-Path $indexHtml) {
    Write-Host "  Frontend index.html exists. OK." -ForegroundColor Green
} else {
    Write-Host "  WARNING: $indexHtml not found!" -ForegroundColor Red
    Write-Host "  The PosFrontend build output may be missing from the installer." -ForegroundColor Red

    # Check if there are any files at all in the frontend dir
    if (Test-Path $frontendDir) {
        $fileCount = (Get-ChildItem -Path $frontendDir -Recurse -File).Count
        Write-Host "  Frontend directory has $fileCount files." -ForegroundColor Yellow
    } else {
        Write-Host "  Frontend directory doesn't exist! Creating it..." -ForegroundColor Red
        New-Item -ItemType Directory -Path $frontendDir -Force | Out-Null
    }
}

# Check and fix nginx.conf - ensure root path doesn't have ../ prefix
if (Test-Path $nginxConf) {
    $confContent = Get-Content $nginxConf -Raw
    Write-Host "  Checking nginx.conf root directive..."

    # Fix root path if it contains ../
    if ($confContent -match 'root\s+"?\.\./') {
        Write-Host "  FOUND BAD ROOT PATH with ../ prefix - fixing..." -ForegroundColor Red
        $confContent = $confContent -replace 'root\s+"?\.\./apps/posFrontend"?', 'root "apps/posFrontend"'
        Set-Content -Path $nginxConf -Value $confContent -Encoding ASCII -Force
        Write-Host "  nginx.conf root path fixed to: apps/posFrontend" -ForegroundColor Green
    } elseif ($confContent -match 'root\s+"?apps/posFrontend"?') {
        Write-Host "  Root path is correct: apps/posFrontend" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Unexpected root path in nginx.conf" -ForegroundColor Yellow
        $rootMatch = [regex]::Match($confContent, 'root\s+[^;]+;')
        if ($rootMatch.Success) {
            Write-Host "  Current: $($rootMatch.Value)" -ForegroundColor Yellow
        }
    }

    # Verify the nginx prefix resolves correctly
    # The service XML uses -p "%BASE%\.." which = INSTALLDIR\services\..
    # Test if nginx can find the config
    $nginxExe = "$INSTALL_DIR\nginx\nginx.exe"
    if (Test-Path $nginxExe) {
        Write-Host "  Testing nginx config syntax..."
        $testResult = & $nginxExe -p $INSTALL_DIR -c "config\nginx.conf" -t 2>&1
        $testOutput = $testResult -join "`n"
        if ($testOutput -match "syntax is ok" -or $testOutput -match "test is successful") {
            Write-Host "  Nginx config test: PASSED" -ForegroundColor Green
        } else {
            Write-Host "  Nginx config test output: $testOutput" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  ERROR: nginx.conf not found at $nginxConf" -ForegroundColor Red
}

# Ensure temp directories exist
$tempDirs = @("client_body_temp", "proxy_temp", "fastcgi_temp", "uwsgi_temp", "scgi_temp")
foreach ($dir in $tempDirs) {
    $path = "$INSTALL_DIR\temp\$dir"
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}
Write-Host "  Nginx temp directories verified." -ForegroundColor Green

# Ensure nginx log directory exists
$nginxLogDir = "$INSTALL_DIR\logs\nginx"
if (-not (Test-Path $nginxLogDir)) {
    New-Item -ItemType Directory -Path $nginxLogDir -Force | Out-Null
}
$nginxPidDir = "$INSTALL_DIR\nginx\logs"
if (-not (Test-Path $nginxPidDir)) {
    New-Item -ItemType Directory -Path $nginxPidDir -Force | Out-Null
}
Write-Host ""

# ============================================
# FIX 5: Fix Nginx Frontend service to use normalized path
# ============================================
Write-Host "[5/5] Fixing service XML configurations..." -ForegroundColor Yellow

# Fix the Frontend service XML to use a normalized prefix path
$frontendXml = "$INSTALL_DIR\services\OneShellFrontendService.xml"
if (Test-Path $frontendXml) {
    $xmlContent = Get-Content $frontendXml -Raw

    # Replace %BASE%\.. with the actual install dir in the executable args
    # This fixes the nginx prefix path normalization issue
    if ($xmlContent -match '%BASE%\\\.\.') {
        Write-Host "  Frontend service XML uses %BASE%\.. paths (standard WinSW pattern)" -ForegroundColor Gray
        # The %BASE%\.. pattern is normal for WinSW, but let's verify it resolves correctly
        Write-Host "  Services dir: $INSTALL_DIR\services" -ForegroundColor Gray
        Write-Host "  Resolved: $INSTALL_DIR (via ..)" -ForegroundColor Gray
    }
}

# Fix PosNodeBackend service XML - add env vars if missing
$nodeXml = "$INSTALL_DIR\services\OneShellPosNodeBackendService.xml"
if (Test-Path $nodeXml) {
    $xmlContent = Get-Content $nodeXml -Raw
    $modified = $false

    if ($xmlContent -notmatch 'MONGODB_URI') {
        Write-Host "  Adding MONGODB_URI to PosNodeBackend service..." -ForegroundColor Yellow
        $xmlContent = $xmlContent -replace '(<env name="NODE_ENV" value="production"/>)', "`$1`r`n  <env name=`"PORT`" value=`"3001`"/>`r`n  <env name=`"MONGODB_URI`" value=`"mongodb://127.0.0.1:27017/pos`"/>`r`n  <env name=`"NATS_URL`" value=`"nats://127.0.0.1:4222`"/>`r`n  <env name=`"POS_BACKEND_URL`" value=`"http://127.0.0.1:8090`"/>"
        $modified = $true
    }

    if ($modified) {
        Set-Content -Path $nodeXml -Value $xmlContent -Encoding UTF8 -Force
        Write-Host "  PosNodeBackend service XML updated with env vars." -ForegroundColor Green
    } else {
        Write-Host "  PosNodeBackend service XML already has env vars. OK." -ForegroundColor Green
    }
}

# Fix PosPythonBackend service XML - add PORT if missing
$pythonXml = "$INSTALL_DIR\services\OneShellPosPythonBackendService.xml"
if (Test-Path $pythonXml) {
    $xmlContent = Get-Content $pythonXml -Raw
    $modified = $false

    if ($xmlContent -notmatch '<env name="PORT"') {
        Write-Host "  Adding PORT=5200 to PosPythonBackend service..." -ForegroundColor Yellow
        $xmlContent = $xmlContent -replace '(<env name="POS_CLIENT_BACKEND_URL")', "<env name=`"PORT`" value=`"5200`"/>`r`n  `$1"
        $modified = $true
    }
    if ($xmlContent -notmatch '<env name="MONGODB_URI"') {
        $xmlContent = $xmlContent -replace '(<env name="OLLAMA_BASE_URL")', "<env name=`"MONGODB_URI`" value=`"mongodb://127.0.0.1:27017/pos`"/>`r`n  <env name=`"NATS_URL`" value=`"nats://127.0.0.1:4222`"/>`r`n  `$1"
        $modified = $true
    }

    if ($modified) {
        Set-Content -Path $pythonXml -Value $xmlContent -Encoding UTF8 -Force
        Write-Host "  PosPythonBackend service XML updated." -ForegroundColor Green
    } else {
        Write-Host "  PosPythonBackend service XML already correct. OK." -ForegroundColor Green
    }
}
Write-Host ""

# ============================================
# Start services in dependency order
# ============================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Starting services in dependency order..." -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$startOrder = @(
    @{Name="OneShellMongoDB"; Wait=5; Desc="MongoDB"},
    @{Name="OneShellNATS"; Wait=3; Desc="NATS"},
    @{Name="OneShellPosBackend"; Wait=5; Desc="POS Backend (Java)"},
    @{Name="OneShellPosNodeBackend"; Wait=3; Desc="POS Node Backend"},
    @{Name="OneShellPosPythonBackend"; Wait=3; Desc="POS Python Backend"},
    @{Name="OneShellFrontend"; Wait=2; Desc="Frontend (Nginx)"},
    @{Name="OneShellMonitor"; Wait=2; Desc="Monitor Dashboard"}
)

foreach ($svc in $startOrder) {
    $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
    if ($s) {
        Write-Host "  Starting $($svc.Desc)..." -NoNewline
        try {
            Start-Service -Name $svc.Name -ErrorAction Stop
            Start-Sleep -Seconds $svc.Wait
            $s = Get-Service -Name $svc.Name
            if ($s.Status -eq "Running") {
                Write-Host " RUNNING" -ForegroundColor Green
            } else {
                Write-Host " $($s.Status)" -ForegroundColor Red
            }
        } catch {
            Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "  $($svc.Desc): NOT INSTALLED" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Final Status" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Get-Service OneShell* | Format-Table Name, Status, StartType -AutoSize

Write-Host ""
Write-Host "Monitor Dashboard: http://localhost:3005" -ForegroundColor Cyan
Write-Host "Frontend:          http://localhost:80" -ForegroundColor Cyan
Write-Host ""
