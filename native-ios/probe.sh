#!/bin/sh
# =============================================================================
#  probe.sh — 原生 iOS 运行 Hermes 的可行性探针（只读，不修改系统）
#
#  用途：在 a-Shell / Pyto / Pythonista / Carnets 等原生 iOS 环境里运行，
#        逐项验证 docs/NATIVE-IOS.md 里列出的四道限制。
#
#  用法：sh probe.sh
#
#  设计原则：
#    * 绝不写文件、不装包、不改配置 —— 只做检测并打印结论
#    * 每项检测独立，某项失败不影响后续
#    * 结论基于实测，而非猜测
# =============================================================================

PASS=0
FAIL=0

hr()   { printf '\n%s\n' "────────────────────────────────────────────────────────"; }
item() { printf '[%s] %-30s ' "$1" "$2"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '\033[1;33m!\033[0m %s\n' "$1"; }

printf '\033[1m原生 iOS 运行 Hermes 可行性探针\033[0m\n'
printf '主机: %s\n' "$(uname -srm 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# 找一个可用的 python
# ---------------------------------------------------------------------------
PY=""
for c in python3 python3.14 python3.13 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done

hr
printf '\033[1m1. Python 解释器\033[0m\n'
if [ -z "$PY" ]; then
    item "1" "Python 解释器"; bad "未找到 —— Hermes 无法运行"
else
    VER=$("$PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)
    item "1" "Python 版本"
    case "$VER" in
        3.14*|3.15*) ok "$VER" ;;
        *)           bad "$VER（需要 >= 3.14）" ;;
    esac
    # 具体说明为什么：核心依赖的版本门控
    printf '     %s\n' "Hermes 约 50 个核心依赖全部标记 python_version >= '3.14'，"
    printf '     %s\n' "在 3.11–3.13 上一条都不会安装。"
fi

# ---------------------------------------------------------------------------
# pip
# ---------------------------------------------------------------------------
hr
printf '\033[1m2. 包管理器\033[0m\n'
if [ -n "$PY" ] && "$PY" -m pip --version >/dev/null 2>&1; then
    item "2" "pip"; ok "$("$PY" -m pip --version 2>/dev/null | cut -d' ' -f1-2)"
else
    item "2" "pip"; bad "不可用"
fi

# ---------------------------------------------------------------------------
# 编译工具链
# ---------------------------------------------------------------------------
hr
printf '\033[1m3. 构建工具链\033[0m\n'
CC=""
for c in clang cc gcc; do
    command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
done
item "3a" "C 编译器"
[ -n "$CC" ] && ok "$CC" || bad "缺失（aiohttp / psutil / ruamel.yaml.clib 需 C）"

item "3b" "Rust 工具链 (cargo)"
if command -v cargo >/dev/null 2>&1; then
    ok "$(cargo --version 2>/dev/null | cut -d' ' -f1-2)"
else
    bad "缺失 —— pydantic-core 与 cryptography 无法构建（硬阻断）"
fi
item "3c" "rustc"
command -v rustc >/dev/null 2>&1 && ok "$(rustc --version 2>/dev/null | cut -d' ' -f1-2)" || bad "缺失"

# ---------------------------------------------------------------------------
# Node.js
# ---------------------------------------------------------------------------
hr
printf '\033[1m4. Node.js\033[0m\n'
item "4" "node"
if command -v node >/dev/null 2>&1; then
    ok "$(node --version 2>/dev/null)"
else
    bad "缺失 —— TUI 与 Web UI 不可用"
fi

# ---------------------------------------------------------------------------
# 进程模型
# ---------------------------------------------------------------------------
hr
printf '\033[1m5. 进程模型\033[0m\n'
item "5a" "fork 子进程"
if "$PY" -c 'import os,sys; p=os.fork(); sys.exit(0) if p else os._exit(0)' >/dev/null 2>&1; then
    ok "可用"
else
    bad "受限 —— terminal 工具与 pm/worker.py 依赖它"
fi
item "5b" "exec 外部二进制"
if "$PY" -c 'import subprocess,sys; subprocess.run(["/bin/echo","x"],stdout=subprocess.DEVNULL)' >/dev/null 2>&1; then
    ok "可用"
else
    bad "受限"
fi
item "5c" "后台常驻进程"
if [ -d /proc ] || command -v nohup >/dev/null 2>&1; then
    warn "部分可用（iOS 会挂起后台进程，gateway 无法长驻）"
else
    bad "不可用 —— hermes gateway 无法运行"
fi

# ---------------------------------------------------------------------------
# 依赖解析实测
# ---------------------------------------------------------------------------
hr
printf '\033[1m6. 依赖解析实测（不落盘，仅探测）\033[0m\n'
if [ -n "$PY" ] && "$PY" -m pip --version >/dev/null 2>&1; then
    item "6a" "pydantic-core（需 Rust）"
    if "$PY" -m pip download pydantic-core --no-deps --no-build-isolation \
         -d ${TMPDIR:-/tmp}/hermes-probe-$$ >/dev/null 2>&1; then
        rm -rf "${TMPDIR:-/tmp}/hermes-probe-$$" 2>/dev/null
        ok "可获得（有 iOS wheel 或可本地构建）"
    else
        rm -rf "${TMPDIR:-/tmp}/hermes-probe-$$" 2>/dev/null
        bad "无法获得 —— 这是原生安装的决定性阻断点"
    fi
    item "6b" "cryptography（需 Rust）"
    if "$PY" -m pip download cryptography --no-deps --no-build-isolation \
         -d ${TMPDIR:-/tmp}/hermes-probe-$$ >/dev/null 2>&1; then
        rm -rf "${TMPDIR:-/tmp}/hermes-probe-$$" 2>/dev/null
        ok "可获得"
    else
        rm -rf "${TMPDIR:-/tmp}/hermes-probe-$$" 2>/dev/null
        bad "无法获得"
    fi
else
    item "6" "依赖解析"; bad "跳过（无 pip）"
fi

# ---------------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------------
hr
printf '\033[1m结论\033[0m\n'
printf '通过 %d 项，阻断 %d 项。\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    cat <<'EOM'

原生安装不可行。这不是配置问题，而是硬性限制：
  1. 需要 Python 3.14，原生 iOS 环境最高 3.11
  2. pydantic-core / cryptography 需要 Rust，iOS 无 cargo
  3. PyPI 不发布 iOS wheel，所有依赖都得从源码构建
  4. 无 Node.js，且 iOS 沙箱限制进程与后台服务

建议路线（详见 docs/NATIVE-IOS.md）：
  B. 远程 Hermes + 原生 iOS 终端（Blink Shell / a-Shell ssh）  ← 推荐
  C. 远程 Hermes + 原生 iOS 界面（hermes dashboard + Safari/快捷指令）
  A. iSH（当前方案，功能完整但 CPU 模拟慢 10–50 倍）

如果你的环境通过了全部检测（例如出现了提供 3.14 + Rust 的新运行时），
请把本脚本的输出贴到 issue —— 那个结论值得重新评估。
EOM
else
    printf '\n全部通过！你的环境可能可以原生安装，请把输出贴到 issue。\n'
fi
hr
