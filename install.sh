#!/bin/bash
# =============================================================================
# Hermes Agent — iSH (iOS) installer
#
# One-shot installer for running Nous Research's Hermes Agent inside iSH
# (Alpine Linux emulated on iOS). Works around five iSH-specific constraints
# that break the stock installer:
#
#   1. uv's bundled CPython is statically linked against OpenSSL 3.5.7, whose
#      TLS stack fails on iSH (RECORD_LAYER_FAILURE on every handshake).
#      -> we install Alpine edge's dynamically-linked python3.14 instead.
#   2. fcntl.flock reports lock contention as EPERM (not EWOULDBLOCK), and
#      re-locking a held fd also raises EPERM -> patch pm/filesystem.py.
#   3. `npm ci` is killed by iSH memory limits and wipes node_modules first
#      -> we rebuild the tree from package-lock.json with curl instead.
#   4. Node's recursive rmSync fails with EPERM (kernel returns EPERM, not
#      EISDIR, for unlink() on a directory) -> rm shim falling back to `rm -rf`.
#   5. uv's --compile-bytecode subprocess exceeds its 60s startup budget
#      -> skipped on iSH.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/salem-2007/hermes-ish/master/install.sh | bash
#   or: bash install.sh [--dir PATH] [--version TAG] [--skip-node] [--no-profile]
# =============================================================================
set -uo pipefail

# --- configuration -----------------------------------------------------------
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-$HERMES_HOME/hermes-agent}"
REPO_OWNER="${HERMES_REPO_OWNER:-NousResearch}"
REPO_NAME="${HERMES_REPO_NAME:-hermes-agent}"
ISH_REPO="${HERMES_ISH_REPO:-salem-2007/hermes-ish}"   # repo hosting the patches
VERSION="${HERMES_VERSION:-main}"          # branch or tag, e.g. main / v2026.9.24
PROXY="${HERMES_PROXY:-https://gh-proxy.org}"   # GitHub accelerator for CN networks
PIP_MIRROR="${HERMES_PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"
NPM_MIRROR="${HERMES_NPM_MIRROR:-https://registry.npmmirror.com}"
# Alpine edge mirrors are tried in order for the OpenSSL/SQLite/Python apks;
# individual mirrors lag or drop old -rN revisions, so a list beats one host.
SKIP_NODE=0
WRITE_PROFILE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo "$PWD")"
[ -f "$SCRIPT_DIR/install.sh" ] || SCRIPT_DIR=""   # piped via curl: no local files

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --proxy) PROXY="$2"; shift 2 ;;
        --skip-node) SKIP_NODE=1; shift ;;
        --no-profile) WRITE_PROFILE=0; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_NC=""
fi
log()   { printf '%s→%s %s\n' "$C_CYAN" "$C_NC" "$1"; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_NC" "$1"; }
warn()  { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_NC" "$1"; }
fail()  { printf '%s✗%s %s\n' "$C_RED" "$C_NC" "$1" >&2; exit 1; }

# --- progress bar & stage tracker --------------------------------------------
TOTAL_STAGES=10
CURRENT_STAGE=0
STAGE_NAMES=("系统依赖" "下载源码" "系统库升级" "Python 3.14" "uv 安装" "应用补丁" "Python 依赖" "Node 工具链" "注册命令" "首次启动")

progress_bar() {
    local current=$1 total=$2 width=30 label="$3"
    if [ ! -t 1 ] || [ "$total" -eq 0 ]; then return; fi
    local pct=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    local bar="" pad=""
    local i=0
    while [ $i -lt $filled ]; do bar="${bar}█"; i=$((i+1)); done
    i=0
    while [ $i -lt $empty ]; do pad="${pad}░"; i=$((i+1)); done
    printf "\r%s[%s%s] %3d%%  %s%s" "$C_CYAN" "$C_GREEN$bar$C_CYAN" "$pad" "$pct" "$label" "$C_NC"
    if [ "$current" -ge "$total" ]; then printf "\n"; fi
}

step() {
    CURRENT_STAGE=$((CURRENT_STAGE + 1))
    if [ -t 1 ]; then
        printf "\n"
        progress_bar $((CURRENT_STAGE - 1)) "$TOTAL_STAGES" "准备中..."
        printf "\n%s== [%d/%d] %s ==%s\n" "$C_BOLD" "$CURRENT_STAGE" "$TOTAL_STAGES" "$1" "$C_NC"
    else
        printf '\n== [%d/%d] %s ==\n' "$CURRENT_STAGE" "$TOTAL_STAGES" "$1"
    fi
}

step_done() {
    progress_bar "$CURRENT_STAGE" "$TOTAL_STAGES" "${STAGE_NAMES[$((CURRENT_STAGE-1))]:-完成}"
}

# --- spinner for long-running background tasks --------------------------------
SPINNER_PID=""
run_with_spinner() {
    # Usage: run_with_spinner "label" command [args...]
    # Runs the command in background, shows a spinner with elapsed time.
    local label="$1"; shift
    if [ ! -t 1 ]; then
        "$@"; return $?
    fi
    local pid_file="/tmp/spinner_pid.$$"
    "$@" &
    local bg_pid=$!
    local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0 elapsed=0
    while kill -0 "$bg_pid" 2>/dev/null; do
        local c="${chars:$((i % ${#chars})):1}"
        printf "\r  %s%s%s %s (%ds)" "$C_CYAN" "$c" "$C_NC" "$label" "$elapsed"
        sleep 1
        i=$((i + 1))
        elapsed=$((elapsed + 1))
    done
    wait "$bg_pid" 2>/dev/null
    local rc=$?
    printf "\r"  # clear spinner line
    return $rc
}

require_ish() {
    if [ ! -e /proc/ish ] && [ "${HERMES_FORCE:-0}" != "1" ]; then
        warn "This installer targets iSH (iOS). /proc/ish not found."
        warn "Set HERMES_FORCE=1 to run anyway (Alpine/musl hosts only)."
        exit 1
    fi
}

# --- 1. prerequisites --------------------------------------------------------
step "System prerequisites"
apk update >/dev/null 2>&1 || warn "apk update failed (offline?)"
for pkg in bash curl tar xz gzip git python3 libstdc++ openssl ca-certificates; do
    if ! apk info -e "$pkg" >/dev/null 2>&1; then
        log "installing $pkg"
        apk add "$pkg" >/dev/null 2>&1 || warn "could not install $pkg"
    fi
done
ok "prerequisites ready"
step_done

# --- 2. fetch the source tree ------------------------------------------------
step "Downloading Hermes Agent ($VERSION)"
mkdir -p "$HERMES_HOME/logs"
TARBALL="$HERMES_HOME/hermes-src.tar.gz"
# "v" prefix or a dotted numeric version -> release tag; otherwise a branch.
case "$VERSION" in
    v*)      REF_KIND="tags" ;;
    [0-9]*.[0-9]*) REF_KIND="tags" ;;
    *)       REF_KIND="heads" ;;
esac
SRC_URL="$PROXY/https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/$REF_KIND/$VERSION.tar.gz"

fetch_tarball() {
    local i=0
    while [ $i -lt 20 ]; do
        i=$((i+1))
        log "download attempt $i"
        if curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors \
                --connect-timeout 20 -C - -o "$TARBALL" "$SRC_URL"; then
            gzip -t "$TARBALL" 2>/dev/null && return 0
        fi
        sleep 3
    done
    return 1
}

if [ -f "$INSTALL_DIR/pyproject.toml" ]; then
    ok "existing checkout found at $INSTALL_DIR (skipping download)"
step_done
else
    fetch_tarball || fail "download failed — check your network or set HERMES_PROXY"
    mkdir -p "$HERMES_HOME"
    rm -rf "$INSTALL_DIR" "$HERMES_HOME"/hermes-agent-*
    tar xzf "$TARBALL" -C "$HERMES_HOME" || fail "extract failed"
    EXTRACTED="$(find "$HERMES_HOME" -maxdepth 1 -type d -name 'hermes-agent-*' | head -1)"
    [ -n "$EXTRACTED" ] || fail "extracted directory not found"
    mv "$EXTRACTED" "$INSTALL_DIR"
    ok "source at $INSTALL_DIR"
step_done
fi

# --- 3. system libraries (OpenSSL 3.5.8 / SQLite 3.53.4) ---------------------
# Alpine 3.21 ships OpenSSL 3.3.x, whose libcrypto lacks EVP_MD_CTX_get_size_ex
# (needed by Python 3.14's _hashlib -> scrypt) and whose libssl is too old for
# some endpoints. Edge's 3.5.8 has both, and its TLS works on iSH.
#
# Edge rolls releases often, so a pinned -rN can 404 on a given mirror the day
# after it ships (observed: 3.5.8-r1 missing from tencent/tuna, present on
# ustc/official). We therefore try mirrors in order AND fall back to reading
# each mirror's APKINDEX to discover the current version.
step "System libraries (OpenSSL / SQLite from Alpine edge)"

APK_MIRRORS="${HERMES_APK_MIRRORS:-\
https://mirrors.ustc.edu.cn/alpine/edge/main/aarch64 \
https://dl-cdn.alpinelinux.org/alpine/edge/main/aarch64 \
https://mirrors.cloud.tencent.com/alpine/edge/main/aarch64 \
https://mirrors.tuna.tsinghua.edu.cn/alpine/edge/main/aarch64}"

# apk_index_version <pkg>: read a mirror's APKINDEX and print the current version.
apk_index_version() {  # $1=mirror $2=pkg
    local mirror="$1" pkg="$2" idx="/tmp/apkidx.$$"
    curl -fsSL -m 60 -o "$idx.tgz" "$mirror/APKINDEX.tar.gz" 2>/dev/null || return 1
    tar xzf "$idx.tgz" -C /tmp "APKINDEX" 2>/dev/null || return 1
    awk -v p="$pkg" '
        $0 == "P:" p {found=1; next}
        found && /^V:/ {print substr($0,3); exit}
        found && /^P:/ {found=0}
    ' /tmp/APKINDEX 2>/dev/null
    rm -f "$idx.tgz" /tmp/APKINDEX
}

# apk_fetch <pkg> <dest> [pinned-ver...]: try each mirror with each version,
# then discover the current version from the mirror index as a last resort.
apk_fetch() {
    local pkg="$1" dest="$2"; shift 2
    [ -d "$dest" ] && [ "$(ls -A "$dest" 2>/dev/null)" ] && return 0
    local ver mirror f ok=1
    for ver in "$@"; do
        for mirror in $APK_MIRRORS; do
            f="/tmp/$pkg-$ver.apk"
            if [ ! -f "$f" ]; then
                curl -fsSL --retry 2 --retry-all-errors -m 90 -o "$f" "$mirror/$pkg-$ver.apk" 2>/dev/null || continue
            fi
            if tar xzf "$f" -C "$dest" 2>/dev/null; then ok=0; break 2; fi
        done
    done
    if [ $ok -ne 0 ]; then
        # Pinned versions gone everywhere: ask the mirrors what's current.
        for mirror in $APK_MIRRORS; do
            ver="$(apk_index_version "$mirror" "$pkg")" || continue
            [ -n "$ver" ] || continue
            f="/tmp/$pkg-$ver.apk"
            curl -fsSL --retry 2 --retry-all-errors -m 90 -o "$f" "$mirror/$pkg-$ver.apk" 2>/dev/null || continue
            if tar xzf "$f" -C "$dest" 2>/dev/null; then ok=0; log "$pkg: using $ver from $(echo "$mirror" | cut -d/ -f3)"; break; fi
        done
    fi
    [ $ok -eq 0 ]
}

mkdir -p /opt/openssl35 /opt/sqlite-libs /opt/py314

# Verify that a fetched OpenSSL actually has the symbols we need.
# Edge's python3.14 _hashlib requires EVP_MD_CTX_get_size_ex (>= 3.5.x);
# if a stale/incomplete /opt/openssl35 passes the directory-exists check,
# the install_lib cmp would skip it and leave us with a broken libssl.
verify_openssl() {
    local lib="$1"
    [ -f "$lib" ] || return 1
    # Check for the critical symbol that distinguishes 3.5+ from 3.3
    nm -D "$lib" 2>/dev/null | grep -q EVP_MD_CTX_get_size_ex && return 0
    # Fallback: strings scan (nm may not be installed)
    strings "$lib" 2>/dev/null | grep -q EVP_MD_CTX_get_size_ex && return 0
    return 1
}

# Force re-fetch if the actual library files are missing or wrong version.
# The old check only tested the directory; apk_fetch extracts into usr/lib/
# so we must verify the final file path.
if ! verify_openssl /opt/openssl35/usr/lib/libcrypto.so.3; then
    # Before re-fetching, check if the SYSTEM libssl already has what we need.
    # Some iSH installs already have 3.5.x from a prior run or manual upgrade.
    if verify_openssl /usr/lib/libcrypto.so.3; then
        log "system OpenSSL already has required symbols — skipping edge fetch"
        mkdir -p /opt/openssl35/usr/lib
        cp -a /usr/lib/libssl.so.3 /opt/openssl35/usr/lib/ 2>/dev/null || true
        cp -a /usr/lib/libcrypto.so.3 /opt/openssl35/usr/lib/ 2>/dev/null || true
    else
        log "OpenSSL libraries missing or stale in /opt/openssl35 — re-fetching"
        rm -rf /opt/openssl35/*
    fi
fi

apk_fetch libcrypto3 /opt/openssl35 3.5.8-r1 3.5.8-r0 \
    || warn "libcrypto3 fetch failed — TLS may not work"
apk_fetch libssl3 /opt/openssl35 3.5.8-r1 3.5.8-r0 \
    || warn "libssl3 fetch failed — TLS may not work"
apk_fetch sqlite-libs /opt/sqlite-libs 3.53.4-r0 \
    || warn "sqlite-libs fetch failed"

install_lib() {  # install_lib <src> <dstname>
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    [ -f "$dst" ] && cmp -s "$src" "$dst" && return 0
    cp -a "$dst" "$dst.bak-$(date +%s)" 2>/dev/null || true
    cp -a "$src" "$dst" && log "installed $(basename "$dst")"
}

# Keep backups of the stock libraries so the change is reversible.
mkdir -p /opt/ish-backup
for lib in libssl.so.3 libcrypto.so.3 libsqlite3.so.0; do
    [ -f "/usr/lib/$lib" ] && [ ! -f "/opt/ish-backup/$lib" ] && cp -a "/usr/lib/$lib" /opt/ish-backup/ 2>/dev/null || true
done

install_lib /opt/openssl35/usr/lib/libssl.so.3 /usr/lib/libssl.so.3
install_lib /opt/openssl35/usr/lib/libcrypto.so.3 /usr/lib/libcrypto.so.3
if [ -f /opt/sqlite-libs/usr/lib/libsqlite3.so.3.53.4 ]; then
    install_lib /opt/sqlite-libs/usr/lib/libsqlite3.so.3.53.4 /usr/lib/libsqlite3.so.3.53.4
    ln -sf libsqlite3.so.3.53.4 /usr/lib/libsqlite3.so.0
fi
ok "system libraries updated (originals in /opt/ish-backup)"
step_done

# --- 4. Alpine edge Python 3.14 (dynamic OpenSSL) ----------------------------
# uv's python-build-standalone links OpenSSL statically; that build cannot do
# TLS on iSH. Edge's python3 links the system libssl dynamically and works.
step "Python 3.14 (Alpine edge, dynamic OpenSSL)"
if [ ! -x /opt/py314/usr/bin/python3.14 ]; then
    apk_fetch python3 /opt/py314 3.14.7-r0 || fail "python3.14 apk fetch failed"
fi
[ -x /opt/py314/usr/bin/python3.14 ] || fail "python3.14 not extracted"

# Its libpython must be on the loader path.
if [ ! -f /usr/lib/libpython3.14.so.1.0 ]; then
    cp -a /opt/py314/usr/lib/libpython3.14.so.1.0 /usr/lib/ 2>/dev/null || true
    cp -a /opt/py314/usr/lib/libpython3.so /usr/lib/ 2>/dev/null || true
fi
PY=/opt/py314/usr/bin/python3.14
# Edge python needs both libpython on the loader path AND a matching OpenSSL.
# If the system libssl is too old (3.3.x) but /opt/openssl35 has 3.5.x, we
# need LD_LIBRARY_PATH to pick it up. The _ssl.so extension also needs
# libpython3.14.so which may not be on the default loader path yet.
# Try bare first, then with progressive overrides.
if ! "$PY" -c "import ssl" 2>/dev/null; then
        # Build a combined LD_LIBRARY_PATH covering all edge libs (only existing dirs)
    _extra=""
    [ -f /opt/openssl35/usr/lib/libssl.so.3 ] && _extra="/opt/openssl35/usr/lib"
    [ -d /opt/py314/usr/lib ] && { [ -n "$_extra" ] && _extra="$_extra:/opt/py314/usr/lib" || _extra="/opt/py314/usr/lib"; }
    if [ -n "$_extra" ]; then
        export LD_LIBRARY_PATH="$_extra:${LD_LIBRARY_PATH:-}"
        log "retrying ssl import with LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    fi
fi
"$PY" -c "import ssl" 2>/dev/null || fail "edge python cannot import ssl (check /opt/openssl35 and /usr/lib/libssl.so.3)"
"$PY" -c "import sqlite3" 2>/dev/null || warn "edge python sqlite3 import failed"
ok "python $("$PY" -c 'import sys; print(sys.version.split()[0])') with $("$PY" -c 'import ssl; print(ssl.OPENSSL_VERSION)')"
step_done

# --- 5. uv -------------------------------------------------------------------
step "uv (package manager)"
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
        || fail "uv install failed"
fi
command -v uv >/dev/null 2>&1 || [ -x "$HOME/.local/bin/uv" ] || fail "uv not on PATH"
UV="$HOME/.local/bin/uv"
[ -x "$UV" ] || UV="$(command -v uv)"
ok "uv $("$UV" --version 2>/dev/null | head -1)"

# --- 6. apply iSH patches ----------------------------------------------------
step "Applying iSH patches"
PATCH_SCRIPT="$SCRIPT_DIR/patches/apply-patches.py"
ASSET_LOCKFILL="$SCRIPT_DIR/assets/ish-lockfill.py"
ASSET_RMSHIM="$SCRIPT_DIR/assets/rm-shim.mjs"
if [ ! -f "$PATCH_SCRIPT" ]; then
    # Standalone mode (piped straight from the web): fetch the patcher + assets.
    warn "patches/ not found next to install.sh — fetching from $ISH_REPO"
    mkdir -p /tmp/hermes-ish/patches /tmp/hermes-ish/assets
    for branch in master main; do
        base="$PROXY/https://raw.githubusercontent.com/$ISH_REPO/$branch"
        curl -fsSL --retry 2 --retry-all-errors "$base/patches/apply-patches.py" -o /tmp/hermes-ish/patches/apply-patches.py 2>/dev/null && break
    done
    base="$PROXY/https://raw.githubusercontent.com/$ISH_REPO/${branch:-master}"
    curl -fsSL --retry 3 --retry-all-errors "$base/assets/ish-lockfill.py" -o /tmp/hermes-ish/assets/ish-lockfill.py 2>/dev/null || true
    curl -fsSL --retry 3 --retry-all-errors "$base/assets/rm-shim.mjs" -o /tmp/hermes-ish/assets/rm-shim.mjs 2>/dev/null || true
    PATCH_SCRIPT=/tmp/hermes-ish/patches/apply-patches.py
    ASSET_LOCKFILL=/tmp/hermes-ish/assets/ish-lockfill.py
    ASSET_RMSHIM=/tmp/hermes-ish/assets/rm-shim.mjs
fi
[ -f "$PATCH_SCRIPT" ] || fail "patch script unavailable"
"$PY" "$PATCH_SCRIPT" --source "$INSTALL_DIR" || fail "patch application failed"
step_done

# --- 7. virtualenv + Python dependencies -------------------------------------
# uv on iSH can exit 0 with packages missing (the emulated runtime trips its
# extraction paths): observed a full install "succeeding" with 19 of ~230
# packages on disk. Every run is therefore verified against a sentinel import
# and retried, which converges (the second pass repairs the partial tree).
step "Python environment"
cd "$INSTALL_DIR"
export UV_DEFAULT_INDEX="$PIP_MIRROR"
export UV_HTTP_TIMEOUT=120
export UV_LINK_MODE=copy
export UV_CONCURRENT_DOWNLOADS=4
rm -rf .venv
"$UV" venv --python "$PY" .venv >/dev/null 2>&1 || fail "venv creation failed"

deps_ok() {  # sentinel: the heavy imports Hermes cannot start without
    .venv/bin/python - << 'PYEOF' >/dev/null 2>&1
import openai, aiohttp, pydantic, rich, httpx, prompt_toolkit  # noqa
PYEOF
}

deps_install() {
    "$UV" pip install -e ".[all]" > "$HERMES_HOME/logs/pip-install.log" 2>&1
}

deps_install || deps_install  # one retry absorbs transient mirror stalls
if ! deps_ok; then
    warn "dependency tree incomplete after first pass — repairing"
    # uv refuses to patch a tree with half-written dist-info; a second explicit
    # pass over the same interpreter converges in practice. One more retry:
    deps_install || true
    if ! deps_ok; then
        # Nuclear option: rebuild the venv from scratch and install once more.
        rm -rf .venv
        "$UV" venv --python "$PY" .venv >/dev/null 2>&1 || fail "venv recreation failed"
        deps_install || fail "python dependencies failed — see $HERMES_HOME/logs/pip-install.log"
        deps_ok || fail "python dependencies still incomplete — see $HERMES_HOME/logs/pip-install.log"
    fi
fi
ok "python dependencies installed ($(ls .venv/lib/python3.14/site-packages 2>/dev/null | wc -l) packages)"
step_done

# --- 8. Node dependencies (TUI + web UI) -------------------------------------
if [ "$SKIP_NODE" = "0" ]; then
    step "Node.js toolchain"
    NODE_DIR="$HERMES_HOME/tools/node-26.7.0-linux-arm64-musl"
    if [ ! -x "$NODE_DIR/bin/node" ]; then
        log "fetching Node.js (musl aarch64)"
        mkdir -p "$HERMES_HOME/tools"
        curl -fsSL --retry 4 --retry-all-errors \
            -o /tmp/node.tar.xz \
            "https://cdn.npmmirror.com/binaries/node-unofficial-builds/v26.7.0/node-v26.7.0-linux-arm64-musl.tar.xz" \
            || curl -fsSL --retry 4 --retry-all-errors -o /tmp/node.tar.xz \
            "https://unofficial-builds.nodejs.org/download/release/v26.7.0/node-v26.7.0-linux-arm64-musl.tar.xz" \
            || fail "node download failed"
        mkdir -p "$NODE_DIR"
        tar xJf /tmp/node.tar.xz -C "$NODE_DIR" --strip-components=1 || fail "node extract failed"
    fi
    export PATH="$NODE_DIR/bin:$PATH"
    ok "node $(node --version 2>/dev/null)"
step_done

    step "Node dependencies (lockfile restore)"
    # Full `npm ci` cannot finish on iSH; rebuild from package-lock.json.
    LOCKFILL="$ASSET_LOCKFILL"
    [ -f "$LOCKFILL" ] || LOCKFILL="$INSTALL_DIR/scripts/build/ish-lockfill.py"
    [ -f "$LOCKFILL" ] || fail "ish-lockfill.py not found"
    "$PY" "$LOCKFILL" --source "$INSTALL_DIR" 2>&1 | tail -5 \
        || warn "node dependency restore reported failures (build may still work)"
    ok "node_modules restored"
step_done
else
    warn "skipping Node toolchain (--skip-node)"
fi

# --- 9. launcher + profile ---------------------------------------------------
step "Registering the hermes command"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/hermes" << WRAPPER
#!/bin/sh
# Hermes Agent launcher (iSH / iOS)
export HERMES_HOME="\${HERMES_HOME:-\$HOME/.hermes}"
export PATH="\$HOME/.local/bin:\${PATH}"
export UV_DEFAULT_INDEX="\${UV_DEFAULT_INDEX:-$PIP_MIRROR}"
export npm_config_registry="\${npm_config_registry:-$NPM_MIRROR}"
cd "$INSTALL_DIR" || exit 1
exec "$INSTALL_DIR/.venv/bin/python" "$INSTALL_DIR/hermes" "\$@"
WRAPPER
chmod +x "$HOME/.local/bin/hermes"

if [ "$WRITE_PROFILE" = "1" ]; then
    cat > /etc/profile.d/hermes.sh << PROF
# Hermes Agent runtime environment (iSH)
export PATH="\$HOME/.local/bin:\${PATH}"
export UV_DEFAULT_INDEX="\${UV_DEFAULT_INDEX:-$PIP_MIRROR}"
export npm_config_registry="\${npm_config_registry:-$NPM_MIRROR}"
[ -d /opt/openssl35/usr/lib ] && export LD_LIBRARY_PATH="/opt/openssl35/usr/lib:/opt/py314/usr/lib:\${LD_LIBRARY_PATH:-}"
PROF
    chmod +x /etc/profile.d/hermes.sh
fi
ok "hermes command installed"
step_done

# --- 10. first launch (source completion) ------------------------------------
step "Finishing installation (first launch)"
export PATH="$HOME/.local/bin:$PATH"
if command -v node >/dev/null 2>&1 || [ -x "$HERMES_HOME/tools/node-26.7.0-linux-arm64-musl/bin/node" ]; then
    export PATH="$HERMES_HOME/tools/node-26.7.0-linux-arm64-musl/bin:$PATH"
fi

# Set Chinese as the display language (bundled zh.yaml covers 99.8% of keys).
hermes config set display.language zh > /dev/null 2>&1 && log "display language set to zh"

# A real command (not --version) triggers dependency completion.
timeout 1800 hermes config show > "$HERMES_HOME/logs/first-launch.log" 2>&1
if grep -q "Model\|模型" "$HERMES_HOME/logs/first-launch.log" 2>/dev/null; then
    ok "first launch complete"
step_done
else
    warn "first launch needs a rerun — run: hermes config show"
step_done
fi

# --- done --------------------------------------------------------------------
cat << DONE

${C_GREEN}${C_BOLD}Hermes Agent 安装完成 (iSH)${C_NC}

  命令       hermes
  安装路径   $INSTALL_DIR
  日志目录   $HERMES_HOME/logs/
  界面语言   简体中文 (zh)

下一步：
  1. 打开新终端（或执行 source /etc/profile.d/hermes.sh）
  2. 配置 AI 模型提供商：
       hermes setup                    # 交互式向导
     或直接指向 OpenAI 兼容端点：
       hermes config set model.provider custom
       hermes config set model.base_url http://YOUR_HOST:3000/v1
       echo 'LAN_API_KEY=sk-...' >> $HERMES_HOME/.env
  3. 开始对话：
       hermes

说明：
  * iSH 为模拟 CPU，首次启动可能需要数分钟。
  * 原始系统库已备份到 /opt/ish-backup。
  * 切换回英文：hermes config set display.language en
DONE
