#!/usr/bin/env python3
"""Restore node_modules from package-lock.json without npm ci (iSH / iOS).

npm ci removes node_modules before installing and cannot finish under the
emulated runtime's memory and network limits, which left the checkout with a
wiped dependency tree. This script fetches each locked tarball through a mirror
with curl and unpacks it with the stdlib, so the tree can always be rebuilt.

Usage: python3 scripts/build/ish-lockfill.py [--source PATH]
"""
import json
import os
import shutil
import subprocess
import sys
import tarfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

MIRROR = os.environ.get("HERMES_NPM_MIRROR", "https://registry.npmmirror.com")
# Each package is one curl process; on iSH every round-trip costs several
# seconds, so 1350 serial fetches take hours. Fetch a window of them at a time
# (default 8). Unpack stays serial — the emulated filesystem does not like
# concurrent extractall.
JOBS = max(1, int(os.environ.get("HERMES_LOCKFILL_JOBS", "8")))


def mirror_url(url: str) -> str:
    return url.replace("https://registry.npmjs.org", MIRROR)


def download(url: str, dest: Path, tries: int = 4) -> bool:
    if dest.is_file() and dest.stat().st_size > 0:
        return True
    tmp = dest.with_suffix(dest.suffix + ".part")
    for _ in range(tries):
        proc = subprocess.run(
            ["curl", "-fsSL", "--connect-timeout", "20", "--retry", "3",
             "--retry-all-errors", "-o", str(tmp), url],
            capture_output=True)
        if proc.returncode == 0 and tmp.is_file() and tmp.stat().st_size > 0:
            tmp.rename(dest)
            return True
        if tmp.exists():
            tmp.unlink()
    return False


def unpack(tgz: Path, target: Path) -> bool:
    if target.exists():
        shutil.rmtree(target, ignore_errors=True)
    target.mkdir(parents=True, exist_ok=True)
    try:
        with tarfile.open(tgz, "r:gz") as tf:
            members = []
            for m in tf.getmembers():
                parts = m.name.split("/", 1)
                if len(parts) < 2 or not parts[1]:
                    continue
                m.name = parts[1]
                members.append(m)
            try:
                tf.extractall(target, members=members, filter="fully_trusted")
            except TypeError:
                tf.extractall(target, members=members)
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"  unpack failed: {exc}", flush=True)
        shutil.rmtree(target, ignore_errors=True)
        return False


def main() -> int:
    root = Path("/root/.hermes/hermes-agent")
    argv = sys.argv[1:]
    for i, arg in enumerate(argv):
        if arg == "--source" and i + 1 < len(argv):
            root = Path(argv[i + 1])
    lock = root / "package-lock.json"
    if not lock.is_file():
        print(f"no package-lock.json under {root}", flush=True)
        return 1
    cache = root.parent / "cache" / "npm-tarballs"
    cache.mkdir(parents=True, exist_ok=True)

    packages = json.loads(lock.read_text()).get("packages", {})
    entries = [(path, meta.get("version"), meta.get("resolved"))
               for path, meta in packages.items()
               if path.startswith("node_modules/") and meta.get("resolved")]
    print(f"lockfile entries: {len(entries)}", flush=True)

    ok = skip = fail = 0
    todo = []
    for path, version, resolved in entries:
        target = root / path
        pkg_json = target / "package.json"
        if pkg_json.is_file():
            try:
                have = json.loads(pkg_json.read_text()).get("version")
            except Exception:  # noqa: BLE001
                have = None
            if have == version:
                skip += 1
                continue
        name = path.split("node_modules/", 1)[1]
        todo.append((path, version, resolved, name,
                     cache / f"{name.replace('/', '-')}-{version}.tgz"))

    print(f"to fetch: {len(todo)} (jobs={JOBS})", flush=True)

    def fetch(item):
        path, version, resolved, name, tgz = item
        if download(mirror_url(resolved), tgz):
            return item
        print(f"MISS {name}@{version}", flush=True)
        return None

    # Warm the tarball cache concurrently; network-bound, so this is where the
    # wall-clock actually goes. pool.map yields results in submission order.
    fetched = []
    done = 0
    if todo:
        with ThreadPoolExecutor(max_workers=JOBS) as pool:
            for result in pool.map(fetch, todo):
                done += 1
                if result is not None:
                    fetched.append(result)
                else:
                    fail += 1
                if done % 50 == 0:
                    print(f"  fetch progress: {done}/{len(todo)}", flush=True)

    for path, version, resolved, name, tgz in fetched:
        if unpack(tgz, root / path):
            ok += 1
            if (ok % 100) == 0:
                print(f"  progress: {ok} fetched, {skip} skipped, {fail} failed", flush=True)
        else:
            print(f"UNPACK MISS {name}@{version}", flush=True)
            fail += 1

    for path, meta in packages.items():
        if not path.startswith("node_modules/") or not meta.get("link"):
            continue
        target = root / path
        link_target = (root / meta["resolved"]).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink() or target.exists():
            try:
                target.unlink()
            except (IsADirectoryError, OSError):
                shutil.rmtree(target, ignore_errors=True)
        try:
            os.symlink(link_target, target)
        except OSError as exc:
            print(f"link failed {path}: {exc}", flush=True)

    print(f"DONE fetched={ok} skipped={skip} failed={fail}", flush=True)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
