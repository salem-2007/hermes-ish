#!/usr/bin/env python3
"""Apply iSH (iOS) compatibility patches to a Hermes Agent checkout.

Every patch is idempotent and marked with an "iSH (iOS) note" comment, so a
later upstream merge that drops one is detected on the next install run.

Usage: python3 apply-patches.py --source /root/.hermes/hermes-agent
"""
import argparse
import shutil
import sys
from pathlib import Path

PATCHES_APPLIED = []
PATCHES_SKIPPED = []
PATCHES_FAILED = []


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def patch(path: Path, marker: str, old: str, new: str, *, label: str) -> bool:
    """Replace *old* with *new* once. Idempotent via *marker*."""
    if not path.is_file():
        PATCHES_FAILED.append(f"{label}: file missing ({path})")
        return False
    text = read(path)
    if marker in text:
        PATCHES_SKIPPED.append(label)
        return True
    if old not in text:
        PATCHES_FAILED.append(f"{label}: anchor not found")
        return False
    write(path, text.replace(old, new, 1))
    PATCHES_APPLIED.append(label)
    return True


# ---------------------------------------------------------------------------
# 1. flock: iSH reports contention as EPERM, not EWOULDBLOCK/EAGAIN.
# ---------------------------------------------------------------------------
def patch_flock(root: Path) -> None:
    path = root / "pm/filesystem.py"
    if path.is_file():
        text = read(path)
        # Any iSH marker in the fcntl branch means the fix is present.
        if "reports lock contention as EPERM" in text or "iSH (iOS) note: lock contention" in text:
            PATCHES_SKIPPED.append("pm/filesystem.py (EPERM lock contention)")
            return
    patch(
        path,
        marker="iSH (iOS) note: lock contention",
        old="""            except BlockingIOError:
                pass
            if not wait or (deadline is not None and time.monotonic() >= deadline):
                return False
            time.sleep(_LOCK_POLL_SECONDS)""",
        new="""            except BlockingIOError:
                pass
            except OSError as exc:
                # iSH (iOS) note: lock contention is reported as EPERM rather
                # than EWOULDBLOCK/EAGAIN, and re-locking a held fd raises EPERM
                # too. Treat both as "someone holds the lock".
                if exc.errno == errno.EPERM:
                    pass
                else:
                    raise
            if not wait or (deadline is not None and time.monotonic() >= deadline):
                return False
            time.sleep(_LOCK_POLL_SECONDS)""",
        label="pm/filesystem.py (EPERM lock contention)",
    )


# ---------------------------------------------------------------------------
# 2. uv --compile-bytecode exceeds its 60s startup budget on iSH.
# ---------------------------------------------------------------------------
def patch_compile_bytecode(root: Path) -> None:
    patch(
        root / "pm/environment.py",
        marker="not os.path.exists(\"/proc/ish\")",
        old="""        command = ["sync", "--locked" if locked else "--frozen", "--all-packages",
                   "--python", str(self.python), "--compile-bytecode"]""",
        new="""        command = ["sync", "--locked" if locked else "--frozen", "--all-packages",
                   "--python", str(self.python)]
        # iSH (iOS) note: uv's bytecode-compile subprocess cannot start within
        # its 60s budget on the emulated runtime; bytecode is precompiled
        # out-of-band instead.
        if not os.path.exists("/proc/ish"):
            command.append("--compile-bytecode")""",
        label="pm/environment.py (skip uv --compile-bytecode)",
    )


# ---------------------------------------------------------------------------
# 3. node-deps: use the lockfile restore instead of npm ci on iSH.
# ---------------------------------------------------------------------------
def patch_node_deps(root: Path) -> None:
    path = root / "scripts/build/node-deps.mjs"
    if not path.is_file():
        PATCHES_FAILED.append("scripts/build/node-deps.mjs: missing")
        return
    text = read(path)

    # 3a. import existsSync/execFileSync + join when absent
    if "ish-lockfill" not in text:
        if "import { existsSync" not in text:
            text = text.replace(
                "import { mkdtempSync",
                "import { existsSync, mkdtempSync",
                1,
            )
        if "execFileSync" not in text.split("\n")[0:20].__str__():
            text = text.replace(
                "from 'node:child_process'",
                "from 'node:child_process'",
                1,
            )
        marker_old = """  console.log(`node-deps: installing workspace dependencies with npm ci (${selected.join(', ')})...`)
  runNpmCi(node, npm, args, { source, env })"""
        marker_new = """  console.log(`node-deps: installing workspace dependencies with npm ci (${selected.join(', ')})...`)
  // iSH (iOS) note: npm ci removes node_modules first and is then killed by the
  // emulated runtime's memory limits, leaving no tree at all. Restore the locked
  // tree from package-lock.json with curl instead.
  const isIsh = existsSync('/proc/ish')
  if (env.HERMES_SKIP_NPM_CI === '1' || isIsh) {
    const reason = isIsh ? 'iSH detected' : 'HERMES_SKIP_NPM_CI=1'
    console.log(`node-deps: ${reason} — restoring node_modules from package-lock.json`)
    try {
      execFileSync('/usr/bin/python3', [join(source, 'scripts/build/ish-lockfill.py'), '--source', source],
        { stdio: 'inherit', env })
    } catch (error) {
      console.log(`node-deps: ish-lockfill failed (${error.message}); keeping existing tree`)
    }
  } else {
    runNpmCi(node, npm, args, { source, env })
  }"""
        if marker_old in text:
            text = text.replace(marker_old, marker_new, 1)
        else:
            PATCHES_FAILED.append("node-deps.mjs: npm ci anchor not found")

        # 3b. guard the hidden-lock receipt write (npm never wrote it)
        rec_old = """  if (reuse) {
    const completed = `${key}\\n${createHash('sha256').update(readFileSync(hiddenLock)).digest('hex')}\\n`"""
        rec_new = """  if (reuse) {
    if ((env.HERMES_SKIP_NPM_CI === '1' || existsSync('/proc/ish')) && !existsSync(hiddenLock)) {
      // iSH note: no npm ci ran, so npm's hidden lock does not exist.
      writeFileSync(hiddenLock, readFileSync(join(source, 'package-lock.json')))
    }
    const completed = `${key}\\n${createHash('sha256').update(readFileSync(hiddenLock)).digest('hex')}\\n`"""
        if rec_old in text:
            text = text.replace(rec_old, rec_new, 1)
        else:
            PATCHES_FAILED.append("node-deps.mjs: receipt anchor not found")

        write(path, text)
        PATCHES_APPLIED.append("scripts/build/node-deps.mjs (iSH lockfile restore)")
    else:
        PATCHES_SKIPPED.append("scripts/build/node-deps.mjs")


# ---------------------------------------------------------------------------
# 4. Node rmSync: EPERM on directories -> fall back to `rm -rf`.
# ---------------------------------------------------------------------------
def install_rm_shim(root: Path) -> None:
    src = Path(__file__).resolve().parent.parent / "assets" / "rm-shim.mjs"
    dst = root / "scripts/build/rm-shim.mjs"
    if dst.is_file() and "iSH (iOS) note" in read(dst):
        PATCHES_SKIPPED.append("scripts/build/rm-shim.mjs")
        return
    if src.is_file():
        shutil.copyfile(src, dst)
        PATCHES_APPLIED.append("scripts/build/rm-shim.mjs (installed)")
    else:
        # Inline fallback when the asset is unavailable.
        write(dst, """// iSH (iOS) note: Node's recursive rmSync fails with EPERM because the kernel
// returns EPERM (not EISDIR) for unlink() on a directory, so Node never falls
// back to rmdir. Shell `rm -rf` handles both.
import { rmSync as _nodeRmSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

export function rmSync(target, opts = {}) {
  try {
    return _nodeRmSync(target, opts)
  } catch (error) {
    if (error && error.code === 'EPERM') {
      try {
        execFileSync('/bin/rm', ['-rf', '--', String(target)])
        return
      } catch { /* fall through to the original error */ }
    }
    throw error
  }
}
""")
        PATCHES_APPLIED.append("scripts/build/rm-shim.mjs (inline)")


def patch_rm_consumers(root: Path) -> None:
    # frontend-common.mjs imports rmSync from node:fs -> reroute to the shim.
    fc = root / "scripts/build/frontend-common.mjs"
    if fc.is_file():
        text = read(fc)
        if "rm-shim" in text:
            PATCHES_SKIPPED.append("scripts/build/frontend-common.mjs")
        else:
            import re

            m = re.search(r"import \{([^}]*)\} from 'node:fs'", text)
            if m and "rmSync" in m.group(1):
                names = [n.strip() for n in m.group(1).split(",") if n.strip() and n.strip() != "rmSync"]
                new_import = "import { " + ", ".join(names) + " } from 'node:fs'\nimport { rmSync } from './rm-shim.mjs'"
                text = text[: m.start()] + new_import + text[m.end():]
                write(fc, text)
                PATCHES_APPLIED.append("scripts/build/frontend-common.mjs (rm shim)")
            else:
                PATCHES_SKIPPED.append("scripts/build/frontend-common.mjs (no rmSync import)")

    # tui.mjs: replace its own inline definition with the shared shim.
    tui = root / "scripts/build/tui.mjs"
    if tui.is_file():
        text = read(tui)
        if "rm-shim" in text:
            PATCHES_SKIPPED.append("scripts/build/tui.mjs")
        else:
            marker = "// iSH (iOS) note: Node's recursive rmSync fails with EPERM"
            if marker in text:
                PATCHES_SKIPPED.append("scripts/build/tui.mjs (inline shim present)")
            else:
                # Route the named import through the shim by shadowing it.
                old = "import { cpSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'"
                new = ("import { cpSync, readFileSync, writeFileSync, mkdtempSync } from 'node:fs'\n"
                       "import { rmSync } from './rm-shim.mjs'")
                if old in text:
                    write(tui, text.replace(old, new, 1))
                    PATCHES_APPLIED.append("scripts/build/tui.mjs (rm shim)")
                else:
                    PATCHES_FAILED.append("scripts/build/tui.mjs: import anchor not found")


# ---------------------------------------------------------------------------
# 5. pm/worker.py: exit quietly when the parent pipe is gone.
# ---------------------------------------------------------------------------
def patch_worker(root: Path) -> None:
    patch(
        root / "pm/worker.py",
        marker="iSH (iOS) note: when the parent exits",
        old="""    def send(data):
        wire.write(json.dumps({"id": request["id"], **data}) + "\\n")""",
        new="""    def send(data):
        # iSH (iOS) note: when the parent exits or times out first (CLI cancel,
        # emulated-runtime slowness), the pipe is already closed and a raw write
        # raises BrokenPipeError with a traceback. Exiting quietly is correct:
        # nobody is left to read this result.
        try:
            wire.write(json.dumps({"id": request["id"], **data}) + "\\n")
        except (BrokenPipeError, OSError):
            # os._exit skips finalization, whose flush of the same dead pipe
            # would raise "Exception ignored while finalizing" noise.
            os._exit(0)""",
        label="pm/worker.py (BrokenPipeError guard)",
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", required=True, type=Path)
    args = ap.parse_args()
    root = args.source.resolve()
    if not (root / "pyproject.toml").is_file():
        print(f"✗ {root} is not a Hermes checkout", file=sys.stderr)
        return 1

    # Install the lockfill helper the patched node-deps calls.
    lockfill_src = Path(__file__).resolve().parent.parent / "assets" / "ish-lockfill.py"
    lockfill_dst = root / "scripts/build/ish-lockfill.py"
    if not lockfill_dst.is_file() or "iSH" not in read(lockfill_dst)[:200]:
        if lockfill_src.is_file():
            shutil.copyfile(lockfill_src, lockfill_dst)
        else:
            print("⚠ assets/ish-lockfill.py unavailable; node deps cannot self-heal", file=sys.stderr)
    lockfill_dst.chmod(0o755)

    patch_flock(root)
    patch_compile_bytecode(root)
    patch_node_deps(root)
    install_rm_shim(root)
    patch_rm_consumers(root)
    patch_worker(root)

    print(f"applied : {len(PATCHES_APPLIED)}")
    for name in PATCHES_APPLIED:
        print(f"  + {name}")
    if PATCHES_SKIPPED:
        print(f"skipped : {len(PATCHES_SKIPPED)} (already patched)")
        for name in PATCHES_SKIPPED:
            print(f"  = {name}")
    if PATCHES_FAILED:
        print(f"FAILED  : {len(PATCHES_FAILED)}", file=sys.stderr)
        for name in PATCHES_FAILED:
            print(f"  ! {name}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
