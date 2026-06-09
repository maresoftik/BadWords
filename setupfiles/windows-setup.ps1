# ============================================================
#  BadWords Windows Bootstrapper v3.0
#  Run with: irm "https://raw.githubusercontent.com/veritus-git/BadWords/main/setupfiles/windows-setup.ps1" | iex
#
#  Sole purpose: prepare Python + rich, then launch setup.py.
#  Downloads a portable embedded Python and installs rich into
#  a temp directory. The portable Python is cached permanently;
#  everything else is fresh on every run.
# ============================================================

$ErrorActionPreference = "Continue"

$INSTALLER_URL    = "https://raw.githubusercontent.com/veritus-git/BadWords/main/setupfiles/setup.py"
$INSTALLER_URL_FB = "https://gitlab.com/badwords/BadWords/-/raw/main/setupfiles/setup.py"
$EMBED_URL        = "https://www.python.org/ftp/python/3.12.9/python-3.12.9-embed-amd64.zip"
$GETPIP_URL       = "https://bootstrap.pypa.io/get-pip.py"

# -- Local File Detection --------------------------------------
$ScriptDir = ""
if ($MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$LocalSetup = if ($ScriptDir) { Join-Path $ScriptDir "setup.py" } else { "" }
$LocalRepo  = if ($ScriptDir) { Split-Path -Parent $ScriptDir } else { "" }

# -- Directories -----------------------------------------------
# Cached: only the portable Python binary (survives reboots)
$CacheDir   = Join-Path $env:LOCALAPPDATA "BadWords-bootstrap"
$EmbedPyDir = Join-Path $CacheDir "python"
$EmbedPyExe = Join-Path $EmbedPyDir "python.exe"

# Temp: everything else (fresh each run, cleaned on reboot)
$BW_TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("bw_bs_" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))

# -- Colors ----------------------------------------------------
function step($m) { Write-Host "[>] $m" -ForegroundColor Cyan }
function ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function warn($m) { Write-Host "[!]  $m" -ForegroundColor Yellow }
function die($m)  { Write-Host "[X]  $m" -ForegroundColor Red; Read-Host "Press Enter to close"; exit 1 }

# -- Helper: launch CMD and exit PS1 immediately ---------------
function Launch-Installer($PyExe, $InstallPy, $PkgDir) {
    $PyArg = "`"$InstallPy`" --platform windows --bootstrap-python `"$PyExe`""
    if ($LocalRepo -and (Test-Path $LocalSetup)) {
        $PyArg += " --local-repo `"$LocalRepo`""
    }
    $CmdLine = "set PYTHONPATH=$PkgDir&& `"$PyExe`" $PyArg"
    $CmdArgs = "/c title BadWords Setup && mode con cols=88 lines=30 && $CmdLine"

    $wt = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
    if (Test-Path $wt) {
        # Windows 11 Terminal: force exact size on launch
        Start-Process -FilePath $wt `
            -ArgumentList "--size", "88,30", "cmd.exe", $CmdArgs `
            -WindowStyle Normal
    } else {
        # Classic CMD fallback
        Start-Process -FilePath "cmd.exe" `
            -ArgumentList $CmdArgs `
            -WindowStyle Normal
    }
    exit 0
}

# ── MAIN ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "  BadWords Windows Bootstrapper" -ForegroundColor White
Write-Host "  Preparing environment..." -ForegroundColor DarkGray
Write-Host ""

New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
New-Item -ItemType Directory -Path $BW_TMP -Force | Out-Null

try {

# -- 1. Ensure portable Python exists (cached) -----------------
$NeedDownload = $true
if (Test-Path $EmbedPyExe) {
    try {
        & $EmbedPyExe -c "import sys; exit(0 if sys.version_info >= (3,10) else 1)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            # Verify pip is available
            & $EmbedPyExe -m pip --version 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                ok "Using cached portable Python: $EmbedPyExe"
                $NeedDownload = $false
            }
        }
    } catch {}
}

if ($NeedDownload) {
    step "Downloading portable Python 3.12..."
    # Clean old cache if it exists
    if (Test-Path $EmbedPyDir) {
        Remove-Item $EmbedPyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $EmbedPyDir -Force | Out-Null

    $EmbedZip = Join-Path $BW_TMP "python-embed.zip"
    try { Invoke-WebRequest -Uri $EMBED_URL -OutFile $EmbedZip -UseBasicParsing }
    catch { die "Failed to download embedded Python. Check your internet connection." }

    step "Extracting..."
    Expand-Archive -Path $EmbedZip -DestinationPath $EmbedPyDir -Force

    # Patch ._pth to enable pip/site-packages
    $pthFile = Get-ChildItem $EmbedPyDir -Filter "python*._pth" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pthFile) {
        $c = Get-Content $pthFile.FullName -Raw
        $c = $c -replace "#import site", "import site"
        Set-Content -Path $pthFile.FullName -Value $c -Encoding ASCII
        ok "_pth patched."
    }

    step "Bootstrapping pip..."
    $GetPipScript = Join-Path $BW_TMP "get-pip.py"
    try { Invoke-WebRequest -Uri $GETPIP_URL -OutFile $GetPipScript -UseBasicParsing }
    catch { die "Failed to download get-pip.py." }
    & $EmbedPyExe $GetPipScript --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { warn "pip bootstrap returned non-zero. Continuing..." }

    ok "Portable Python ready."
}

# -- 2. Install rich to temp ----------------------------------
step "Installing dependencies..."
$PkgDir = Join-Path $BW_TMP "packages"
New-Item -ItemType Directory -Path $PkgDir -Force | Out-Null
& $EmbedPyExe -m pip install rich --target $PkgDir --quiet 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    die "Failed to install 'rich'. Check your internet connection."
}
ok "Dependencies ready."

# -- 3. Download setup.py to temp -----------------------------
step "Downloading BadWords installer..."
$SetupPy = Join-Path $BW_TMP "setup.py"
$downloaded = $false

if ($LocalSetup -and (Test-Path $LocalSetup)) {
    ok "Found local setup.py."
    Copy-Item -Path $LocalSetup -Destination $SetupPy -Force
    $downloaded = $true
}

if (-not $downloaded) {
    try {
        Invoke-WebRequest -Uri $INSTALLER_URL -OutFile $SetupPy -UseBasicParsing -ErrorAction Stop
        if (Test-Path $SetupPy) { $downloaded = $true }
    } catch { warn "GitHub unavailable. Trying GitLab fallback..." }
}

if (-not $downloaded) {
    try {
        Invoke-WebRequest -Uri $INSTALLER_URL_FB -OutFile $SetupPy -UseBasicParsing -ErrorAction Stop
        if (Test-Path $SetupPy) { $downloaded = $true }
    } catch {}
}

if (-not $downloaded) { die "Failed to download setup.py from both GitHub and GitLab." }
ok "Installer ready."

# -- 4. Launch installer in CMD --------------------------------
Write-Host ""
Write-Host "  Launching BadWords Installer..." -ForegroundColor Cyan
Write-Host ""

Launch-Installer $EmbedPyExe $SetupPy $PkgDir

} catch {
    die "An unexpected error occurred: $_"
}
