# Hermes Agent for iSH (iOS)

Run [Nous Research's Hermes Agent](https://github.com/NousResearch/hermes-agent) inside **iSH** — the Alpine Linux shell for iOS.

The stock installer fails on iSH. This repo is an installer plus the compatibility patches that make it work.

```sh
curl -fsSL https://raw.githubusercontent.com/<your-user>/hermes-ish/main/install.sh | bash
```

---

## Why the stock installer fails

| # | iSH behaviour | Effect | Fix |
|---|---|---|---|
| 1 | uv's bundled CPython links OpenSSL **statically** (3.5.7) | Every HTTPS handshake dies with `RECORD_LAYER_FAILURE` | Use Alpine edge's **dynamically linked** python3.14 + OpenSSL 3.5.8 |
| 2 | `fcntl.flock` reports contention as **EPERM**, not `EWOULDBLOCK` | `PermissionError: [Errno 1]` on every lock | Patch `pm/filesystem.py` to treat EPERM as "held" |
| 3 | `npm ci` is killed by memory limits — **after** deleting `node_modules` | Dependency tree wiped, TUI/web build fails forever | Rebuild from `package-lock.json` with `curl` |
| 4 | Node's recursive `rmSync` fails with **EPERM** (kernel returns EPERM, not EISDIR, for `unlink()` on a dir) | TUI build aborts | `rm` shim falling back to `/bin/rm -rf` |
| 5 | uv's `--compile-bytecode` subprocess can't start within its 60 s budget | Sync fails | Skip on iSH, precompile out-of-band |

Two more environment issues are handled by the installer:

- **OpenSSL 3.3.x lacks `EVP_MD_CTX_get_size_ex`**, which Python 3.14's `_hashlib` needs — without it `hashlib.scrypt` (used by the dashboard auth plugin) raises. Edge's OpenSSL 3.5.8 provides it.
- **SQLite 3.48 has a known WAL-reset corruption bug**; the installer upgrades to 3.53.4.

## Requirements

- iSH (Alpine 3.21 aarch64), a few GB free
- Network access to GitHub (a proxy is used by default for CN networks)
- Patience — iSH emulates the CPU, so installs and first launches take minutes

## Install

```sh
# from the repo (patches travel with it)
git clone https://github.com/<your-user>/hermes-ish
cd hermes-ish && ./install.sh

# or straight from the web
curl -fsSL https://raw.githubusercontent.com/<your-user>/hermes-ish/main/install.sh | bash
```

### Options

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--dir PATH` | `HERMES_INSTALL_DIR` | `~/.hermes/hermes-agent` | Install location |
| `--version REF` | `HERMES_VERSION` | `main` | Branch or tag to install |
| `--proxy URL` | `HERMES_PROXY` | `https://gh-proxy.org` | GitHub accelerator |
| — | `HERMES_PIP_MIRROR` | Tsinghua | PyPI mirror |
| — | `HERMES_NPM_MIRROR` | npmmirror | npm mirror |
| `--skip-node` | — | off | Skip the TUI/web UI toolchain |
| `--no-profile` | — | off | Don't write `/etc/profile.d/hermes.sh` |
| — | `HERMES_FORCE=1` | — | Run on non-iSH Alpine |

## After installing

```sh
# open a new terminal first, or: source /etc/profile.d/hermes.sh
hermes setup                      # interactive wizard
```

Point at any OpenAI-compatible endpoint instead:

```sh
hermes config set model.provider custom
hermes config set model.base_url http://192.168.1.9:3000/v1
echo 'LAN_API_KEY=sk-...' >> ~/.hermes/.env
hermes
```

Enable vision and image generation through the same gateway:

```yaml
# ~/.hermes/config.yaml
model:
  provider: "custom"
  base_url: "http://192.168.1.9:3000/v1"
  supports_vision: true
  context_length: 256000

image_gen:
  provider: "openai"
  openai:
    base_url: "http://192.168.1.9:3000/v1"
    key_env: "LAN_API_KEY"
    model: "agnes-image-2.5-flash"
```

## What works

Verified on an iPhone (iSH, Alpine 3.21, aarch64):

- ✅ Chat, tool calling, streaming
- ✅ `terminal`, `file`, `code_execution`, `memory`, `todo`, `skills`
- ✅ Web search/extract, browser automation
- ✅ Vision (image analysis), image generation
- ✅ TUI and web UI (both build)
- ✅ `session_search`, `delegation`, `cronjob`, `tts`, `clarify`

Not available (platform limits): `computer_use` (needs a desktop OS), Home Assistant / Spotify / Discord / Feishu (need external services or tokens).

## How the patches are organised

```
install.sh                     # orchestrator
patches/apply-patches.py       # idempotent source patches (safe to re-run)
assets/ish-lockfill.py         # rebuild node_modules from package-lock.json
assets/rm-shim.mjs             # rmSync -> /bin/rm -rf fallback
```

Every patch carries an `iSH (iOS) note:` comment and is idempotent. If an upstream update drops one, re-run the installer — it reapplies only what is missing.

## Troubleshooting

**`RECORD_LAYER_FAILURE` / TLS errors** — the edge Python or OpenSSL didn't land. Re-run the installer; check with:

```sh
/opt/py314/usr/bin/python3.14 -c "import ssl; print(ssl.OPENSSL_VERSION)"   # expect 3.5.8
```

**Stuck on "completing source-update dependencies"** — the tail is retried on the next real command. Run `hermes config show` (not `--version`, which skips the completion path) and give it several minutes.

**TUI build fails with "Missing prepared esbuild"** — node_modules was wiped. Restore it:

```sh
python3 ~/.hermes/hermes-agent/scripts/build/ish-lockfill.py
```

**Roll back the system libraries** — originals are in `/opt/ish-backup`:

```sh
cp -a /opt/ish-backup/libssl.so.3 /usr/lib/ && cp -a /opt/ish-backup/libcrypto.so.3 /usr/lib/
```

## Licence

The installer and patches: MIT. Hermes Agent itself is licensed by Nous Research — see its repository.
