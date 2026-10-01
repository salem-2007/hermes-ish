#!/bin/sh
# =============================================================================
#  probe-a-shell.sh — Can Hermes run natively on a-Shell? (read-only check)
#
#  Usage (inside a-Shell):
#      sh probe-a-shell.sh
#
#  ASCII-only output on purpose: a-Shell's /bin/sh mishandles multi-byte
#  characters in shell arguments (the leading byte of a 3-byte sequence gets
#  dropped, so Chinese comes out as "¼Hermes éè¦"). English is readable
#  everywhere, so the script stays in English and the explanation lives in
#  docs/NATIVE-IOS.md.
#
#  Also avoids `cut` (not present in a-Shell) and never calls fork() on iOS
#  (it hangs the session).
#
#  Does not write config, install packages, or modify anything.
# =============================================================================

PASS=0
FAIL=0

hr()   { printf '\n%s\n' "--------------------------------------------------------"; }
item() { printf '[%s] %-26s ' "$1" "$2"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m[NO]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '\033[1;33m[??]\033[0m %s\n' "$1"; }

# first two words of a string, without `cut`
first2() {
    set -- $1
    printf '%s %s' "${1:-}" "${2:-}"
}

printf '\033[1mHermes native-run probe -- a-Shell edition\033[0m\n'
printf 'uname : %s\n' "$(uname -srm 2>/dev/null)"
printf 'shell : %s\n' "${SHELL:-?}"

# ---------------------------------------------------------------------------
# 0. Confirm we are actually in a-Shell
# ---------------------------------------------------------------------------
hr
printf '\033[1m0. Environment\033[0m\n'
MARK=0
command -v pickFolder >/dev/null 2>&1 && MARK=$((MARK+1))
command -v shortcuts  >/dev/null 2>&1 && MARK=$((MARK+1))
command -v pkg        >/dev/null 2>&1 && MARK=$((MARK+1))
case "$HOME" in *a-Shell*|*Documents*|*Containers*) MARK=$((MARK+1)) ;; esac
case "$(uname -s 2>/dev/null)" in Darwin) MARK=$((MARK+1)) ;; esac

item "0" "a-Shell markers"
if [ "$MARK" -ge 2 ]; then
    ok "confirmed ($MARK markers matched)"
else
    warn "only $MARK matched -- treat results as approximate"
fi

# ---------------------------------------------------------------------------
# 1. Python
# ---------------------------------------------------------------------------
hr
printf '\033[1m1. Python\033[0m\n'
PY=""
for c in python3 python3.14 python3.13 python3.12 python3.11 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    item "1" "interpreter"; bad "not found (try: pkg install python3)"
else
    VER=$("$PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)
    [ -n "$VER" ] || VER="unknown"
    item "1" "version"
    case "$VER" in
        3.14*|3.15*) ok "$VER" ;;
        *)           bad "$VER (Hermes needs >= 3.14)" ;;
    esac
    printf '     %s\n' "a-Shell ships 3.11.x. All ~50 core Hermes dependencies carry"
    printf '     %s\n' "a python_version >= '3.14' marker, so none install below that."
    item "1b" "interpreter path"
    ok "$(command -v "$PY")"
fi

# ---------------------------------------------------------------------------
# 2. pip
# ---------------------------------------------------------------------------
hr
printf '\033[1m2. Package manager\033[0m\n'
if [ -n "$PY" ] && "$PY" -m pip --version >/dev/null 2>&1; then
    PV=$("$PY" -m pip --version 2>/dev/null)
    item "2" "pip"; ok "$(first2 "$PV")"
else
    item "2" "pip"; bad "not available"
fi

# ---------------------------------------------------------------------------
# 3. Build toolchain
# ---------------------------------------------------------------------------
hr
printf '\033[1m3. Build toolchain\033[0m\n'
CC=""
for c in clang cc gcc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
item "3a" "C compiler"
if [ -n "$CC" ]; then ok "$CC (C extensions could build)"; else bad "missing"; fi

item "3b" "Rust (cargo)"
if command -v cargo >/dev/null 2>&1; then ok "present"
else bad "missing -- pydantic-core / cryptography cannot build (hard blocker)"; fi

item "3c" "rustc"
command -v rustc >/dev/null 2>&1 && ok "present" || bad "missing"

# ---------------------------------------------------------------------------
# 4. Node.js
# ---------------------------------------------------------------------------
hr
printf '\033[1m4. Node.js\033[0m\n'
item "4" "node"
if command -v node >/dev/null 2>&1; then ok "$(node --version 2>/dev/null)"
else bad "missing -- TUI and web UI unavailable"; fi

# ---------------------------------------------------------------------------
# 5. Process model
#    fork() is NOT called on iOS: it hangs the shell session.
# ---------------------------------------------------------------------------
hr
printf '\033[1m5. Process model\033[0m\n'
OS=$(uname -s 2>/dev/null)
item "5a" "fork()"
case "$OS" in
    Darwin) bad "iOS sandbox forbids fork (not called -- would hang the session)" ;;
    *)      if [ -n "$PY" ] && "$PY" -c 'import os,sys; p=os.fork(); sys.exit(0) if p else os._exit(0)' >/dev/null 2>&1; then
                ok "works"
            else
                bad "unavailable"
            fi ;;
esac
item "5b" "exec external command"
if [ -n "$PY" ] && "$PY" -c 'import subprocess,sys;subprocess.run([sys.executable,"-c","pass"])' >/dev/null 2>&1; then
    ok "works"
else
    warn "limited or unavailable"
fi
item "5c" "background daemon"
warn "iOS suspends background tasks -- hermes gateway cannot stay resident"

# ---------------------------------------------------------------------------
# 6. Can the blocking dependencies be obtained?
# ---------------------------------------------------------------------------
hr
printf '\033[1m6. Dependency availability\033[0m\n'
if [ -n "$PY" ] && "$PY" -m pip --version >/dev/null 2>&1; then
    D="${TMPDIR:-/tmp}/hermes-probe-$$"
    for pkg in pydantic-core cryptography aiohttp psutil; do
        item "6" "$pkg"
        if "$PY" -m pip download "$pkg" --no-deps -d "$D" >/dev/null 2>&1; then
            ok "obtainable"
        else
            bad "cannot obtain (no iOS wheel, cannot build locally)"
        fi
    done
    rm -rf "$D" 2>/dev/null
else
    item "6" "dependencies"; bad "skipped (no pip)"
fi

# ---------------------------------------------------------------------------
# 7. What DOES work here
# ---------------------------------------------------------------------------
hr
printf '\033[1m7. What works in a-Shell\033[0m\n'
for c in ssh scp sftp curl wget git; do
    item "7" "$c"
    if command -v "$c" >/dev/null 2>&1; then ok "$(command -v "$c")"; else warn "missing"; fi
done

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
hr
printf '\033[1mVerdict\033[0m\n'
printf 'passed %d, blocked %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    cat <<'EOM'

Running Hermes natively in a-Shell: NOT POSSIBLE.

a-Shell is native arm64 (far faster than iSH) but lacks three things:
  1. Python is 3.11; every Hermes dependency requires >= 3.14
  2. No Rust -- pydantic-core and cryptography cannot be built
  3. No Node.js, and iOS forbids fork (terminal tool, pm/worker.py break)

Use a-Shell as a NATIVE CLIENT instead of a host:

  Route B (recommended)
    Run Hermes on a Linux host, then from a-Shell:
        ssh user@your-linux-host
    Native terminal, agent on real CPU, latency only from the network.

  Route C
    Run `hermes dashboard` on the host, open it in Safari, then
    "Add to Home Screen" for an app-like icon.

  Route A (iSH)
    Full functionality, but iSH emulates instructions and is an order
    of magnitude slower than a-Shell.

SSH notes for a-Shell:
  ssh/scp/sftp are built in -- nothing to install.
  Keys live under $HOME/Documents/.ssh/ (a-Shell sets SSH_HOME there),
  not in ~/.ssh, because iOS makes ~ read-only.
EOM
else
    printf '\nAll checks passed -- please paste this output in an issue.\n'
fi
hr
