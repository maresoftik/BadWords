#!/bin/bash
# ============================================================
#  BadWords macOS Bootstrapper v2.0
#  Run with: curl -fsSL "https://raw.githubusercontent.com/veritus-git/BadWords/main/setupfiles/mac-setup.sh" | bash
#
#  Sole purpose: prepare Python + rich, then launch setup.py.
#  Downloads python-build-standalone and installs rich into
#  a temp directory. The portable Python is cached permanently;
#  everything else is fresh on every run.
# ============================================================

set -euo pipefail

INSTALLER_URL="https://raw.githubusercontent.com/veritus-git/BadWords/main/setupfiles/setup.py"
INSTALLER_URL_FB="https://gitlab.com/badwords/BadWords/-/raw/main/setupfiles/setup.py"
PBS_FALLBACK_TAG="20250317"
PBS_FALLBACK_VER="3.12.9"

# ── Local File Detection ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || echo "")"
LOCAL_SETUP="$SCRIPT_DIR/setup.py"
LOCAL_REPO=""
if [ -f "$LOCAL_SETUP" ]; then
    LOCAL_REPO="$(dirname "$SCRIPT_DIR")"
fi

# ── Directories ───────────────────────────────────────────────
# Cached: only the portable Python binary (survives reboots)
CACHE_DIR="$HOME/Library/Caches/BadWords-bootstrap"
PBS_DIR="$CACHE_DIR/python"

# Temp: everything else (fresh each run)
BW_TMP=$(mktemp -d)
trap 'rm -rf "$BW_TMP"' EXIT INT TERM

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "${CYAN}[>]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; echo ""; read -r -p "Press Enter to close..."; exit 1; }

# ── Helper: launch installer ──────────────────────────────────
_launch_installer() {
    local py="$1"
    local script="$2"
    local pkg_dir="$3"

    export PYTHONPATH="$pkg_dir"
    clear

    local args=(--platform macos --bootstrap-python "$py")
    if [ -n "$LOCAL_REPO" ]; then
        args+=(--local-repo "$LOCAL_REPO")
    fi
    exec "$py" "$script" "${args[@]}" < /dev/tty
}

# ── MAIN ──────────────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}BadWords macOS Bootstrapper${NC}"
echo -e "  ${CYAN}Preparing environment...${NC}"
echo ""

mkdir -p "$CACHE_DIR"

# -- 1. Ensure portable Python exists (cached) -----------------
PYTHON_BIN=""

# Check cached PBS Python
_find_cached_python() {
    local bin
    bin=$(find "$PBS_DIR/bin" -name "python3*" -maxdepth 1 -type f -perm +111 2>/dev/null | sort -V | tail -1 || true)
    if [ -z "$bin" ]; then
        bin=$(find "$PBS_DIR" -name "python3" -type f -perm +111 2>/dev/null | head -1 || true)
    fi
    echo "$bin"
}

if [ -d "$PBS_DIR" ]; then
    PYTHON_BIN=$(_find_cached_python)
    if [ -n "$PYTHON_BIN" ]; then
        if "$PYTHON_BIN" -c "import sys; exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
            if "$PYTHON_BIN" -m pip --version &>/dev/null; then
                ok "Using cached portable Python: $PYTHON_BIN"
            else
                PYTHON_BIN=""
            fi
        else
            PYTHON_BIN=""
        fi
    fi
fi

if [ -z "$PYTHON_BIN" ]; then
    step "Downloading portable Python (python-build-standalone)..."

    # Clean old cache
    rm -rf "$PBS_DIR"
    mkdir -p "$PBS_DIR"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)        PBS_ARCH="x86_64-apple-darwin" ;;
        arm64|aarch64) PBS_ARCH="aarch64-apple-darwin" ;;
        *) die "Unsupported CPU architecture: $ARCH" ;;
    esac

    # Try GitHub API for latest CPython 3.12
    _PBS_URL=""
    _API_RESP=$(curl -fsSL --max-time 15 \
        "https://api.github.com/repos/indygreg/python-build-standalone/releases/latest" 2>/dev/null || true)
    if [ -n "$_API_RESP" ]; then
        _PBS_URL=$(echo "$_API_RESP" \
            | grep -o '"browser_download_url": "[^"]*cpython-3\.12[^"]*'"${PBS_ARCH}"'-install_only\.tar\.gz"' \
            | head -1 \
            | sed 's/.*"browser_download_url": "\(.*\)"/\1/' || true)
    fi
    if [ -z "$_PBS_URL" ]; then
        warn "GitHub API unavailable. Using fallback URL."
        _PBS_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PBS_FALLBACK_TAG}/cpython-${PBS_FALLBACK_VER}+${PBS_FALLBACK_TAG}-${PBS_ARCH}-install_only.tar.gz"
    fi

    step "Downloading..."
    _ARCHIVE="$BW_TMP/pbs.tar.gz"
    curl -fsSL "$_PBS_URL" -o "$_ARCHIVE" || die "Download failed. Check your internet connection."

    step "Extracting..."
    # PBS install_only archives have a top-level python/ directory.
    # --strip-components=1 gives us python/bin → bin/, python/lib → lib/ etc.
    tar -xf "$_ARCHIVE" -C "$PBS_DIR" --strip-components=1 2>/dev/null \
        || tar -xf "$_ARCHIVE" -C "$PBS_DIR"

    PYTHON_BIN=$(_find_cached_python)
    [ -n "$PYTHON_BIN" ] || die "Could not find Python binary after extraction."

    # Ensure pip is available
    if ! "$PYTHON_BIN" -m pip --version &>/dev/null; then
        step "Bootstrapping pip..."
        _GETPIP="$BW_TMP/get-pip.py"
        curl -fsSL "https://bootstrap.pypa.io/get-pip.py" -o "$_GETPIP" || die "Failed to download get-pip.py."
        "$PYTHON_BIN" "$_GETPIP" --quiet 2>/dev/null || warn "pip bootstrap returned non-zero."
    fi

    ok "Portable Python ready: $PYTHON_BIN"
fi

# -- 2. Install rich to temp ----------------------------------
step "Installing dependencies (rich)..."
PKG_DIR="$BW_TMP/packages"
mkdir -p "$PKG_DIR"
"$PYTHON_BIN" -m pip install rich --target "$PKG_DIR" --quiet 2>/dev/null \
    || die "Failed to install 'rich'. Check your internet connection."
ok "Dependencies ready."

# -- 3. Download setup.py to temp -----------------------------
step "Downloading BadWords installer..."
SETUP_PY="$BW_TMP/setup.py"
downloaded=false

if [ -f "$LOCAL_SETUP" ]; then
    ok "Found local setup.py."
    cp "$LOCAL_SETUP" "$SETUP_PY"
    downloaded=true
elif curl -fsSL --max-time 30 "$INSTALLER_URL" -o "$SETUP_PY" 2>/dev/null; then
    downloaded=true
else
    warn "GitHub unavailable. Trying GitLab fallback..."
    if curl -fsSL --max-time 30 "$INSTALLER_URL_FB" -o "$SETUP_PY" 2>/dev/null; then
        downloaded=true
    fi
fi
[ "$downloaded" = true ] || die "Failed to download setup.py from both GitHub and GitLab."
ok "Installer ready."

# -- 4. Launch installer ---------------------------------------
echo ""
echo -e "  ${CYAN}Launching BadWords Installer...${NC}"
sleep 0.3
_launch_installer "$PYTHON_BIN" "$SETUP_PY" "$PKG_DIR"
exit 0
