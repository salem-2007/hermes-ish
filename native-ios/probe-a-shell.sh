#!/bin/sh
# =============================================================================
#  probe-a-shell.sh — 在 a-Shell 上评估能否原生运行 Hermes
#
#  用法（在 a-Shell 里）：
#      sh probe-a-shell.sh
#  或先取下来：
#      curl -o probe.sh https://raw.githubusercontent.com/salem-2007/hermes-ish/native-ios/native-ios/probe-a-shell.sh
#      sh probe.sh
#
#  特点：针对 a-Shell 的实际环境设计
#    * a-Shell 是原生 Darwin/arm64（不是 Linux），uname 会显示 Darwin
#    * 自带 Python 3.11 + clang，但没有 Rust / Node
#    * 沙箱文件系统，$TMPDIR 可用
#    * 只做检测：不写配置、不装包、不改系统
# =============================================================================

PASS=0
FAIL=0

hr()   { printf '\n%s\n' "────────────────────────────────────────────────────────"; }
item() { printf '[%s] %-28s ' "$1" "$2"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '\033[1;33m!\033[0m %s\n' "$1"; }

printf '\033[1mHermes 原生运行探针 — a-Shell 版\033[0m\n'
printf 'uname : %s\n' "$(uname -srm 2>/dev/null)"
printf 'shell : %s\n' "${SHELL:-?}"

# ---------------------------------------------------------------------------
# 0. 确认确实在 a-Shell 里（避免在 iSH / 其他终端误跑）
# ---------------------------------------------------------------------------
hr
printf '\033[1m0. 环境识别\033[0m\n'
ASHELL_MARK=0
# a-Shell 自带这些命令 / 变量
command -v pickFolder >/dev/null 2>&1 && ASHELL_MARK=$((ASHELL_MARK+1))
command -v shortcuts  >/dev/null 2>&1 && ASHELL_MARK=$((ASHELL_MARK+1))
command -v pkg        >/dev/null 2>&1 && ASHELL_MARK=$((ASHELL_MARK+1))
case "$HOME" in *a-Shell*|*Documents*) ASHELL_MARK=$((ASHELL_MARK+1)) ;; esac
case "$(uname -s 2>/dev/null)" in Darwin) ASHELL_MARK=$((ASHELL_MARK+1)) ;; esac

item "0" "a-Shell 特征"
if [ "$ASHELL_MARK" -ge 2 ]; then
    ok "已确认（$ASHELL_MARK 项特征匹配）"
else
    warn "仅 $ASHELL_MARK 项匹配 —— 结果仅供参考"
fi
printf '     %s\n' "HOME=${HOME:-?}"

# ---------------------------------------------------------------------------
# 1. Python
# ---------------------------------------------------------------------------
hr
printf '\033[1m1. Python 解释器\033[0m\n'
PY=""
for c in python3 python3.14 python3.13 python3.12 python3.11 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    item "1" "Python"; bad "未找到"
    printf '     %s\n' "a-Shell 里可先执行：pkg install python3"
else
    VER=$("$PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)
    item "1" "Python 版本"
    case "$VER" in
        3.14*|3.15*) ok "$VER" ;;
        *)           bad "$VER（Hermes 需要 >= 3.14）" ;;
    esac
    printf '     %s\n' "a-Shell 自带的是 3.11.x；Hermes 的约 50 个核心依赖"
    printf '     %s\n' "全部带 python_version >= '3.14' 门控，低版本上一条都不装。"
    item "1b" "解释器路径"
    ok "$(command -v "$PY")"
fi

# ---------------------------------------------------------------------------
# 2. pip / 包管理
# ---------------------------------------------------------------------------
hr
printf '\033[1m2. 包管理\033[0m\n'
if [ -n "$PY" ] && "$PY" -m pip --version >/dev/null 2>&1; then
    item "2a" "pip"; ok "$("$PY" -m pip --version 2>/dev/null | cut -d' ' -f1-2)"
    TGT=$("$PY" -m pip config get global.target 2>/dev/null || true)
    item "2b" "安装目标"
    [ -n "$TGT" ] && ok "$TGT" || warn "默认（可能落在沙箱内，Files 里看不到）"
else
    item "2a" "pip"; bad "不可用"
fi

# ---------------------------------------------------------------------------
# 3. 构建工具链
# ---------------------------------------------------------------------------
hr
printf '\033[1m3. 构建工具链\033[0m\n'
CC=""
for c in clang cc gcc; do command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }; done
item "3a" "C 编译器"
[ -n "$CC" ] && ok "$CC（a-Shell 自带，C 扩展有机会编译）" || bad "缺失"

item "3b" "Rust (cargo)"
command -v cargo >/dev/null 2>&1 && ok "$(cargo --version 2>/dev/null)" \
    || bad "缺失 —— pydantic-core / cryptography 无法构建（硬阻断）"
item "3c" "rustc"
command -v rustc >/dev/null 2>&1 && ok "$(rustc --version 2>/dev/null)" || bad "缺失"

# ---------------------------------------------------------------------------
# 4. Node.js
# ---------------------------------------------------------------------------
hr
printf '\033[1m4. Node.js\033[0m\n'
item "4" "node"
command -v node >/dev/null 2>&1 && ok "$(node --version 2>/dev/null)" \
    || bad "缺失 —— TUI 与 Web UI 不可用"

# ---------------------------------------------------------------------------
# 5. 进程模型（iOS 沙箱的关键限制）
# ---------------------------------------------------------------------------
hr
printf '\033[1m5. 进程模型\033[0m\n'
if [ -n "$PY" ]; then
    item "5a" "fork 子进程"
    if "$PY" -c 'import os; os.fork()' >/dev/null 2>&1; then
        ok "可用"
    else
        bad "不可用（iOS 禁止 fork）—— pm/worker.py 依赖它"
    fi
    item "5b" "exec 外部命令"
    if "$PY" -c 'import subprocess; subprocess.run(["true"])' >/dev/null 2>&1; then
        ok "可用"
    else
        bad "受限 —— terminal 工具不可用"
    fi
else
    item "5" "进程模型"; bad "跳过（无 Python）"
fi
item "5c" "后台常驻进程"
if command -v nohup >/dev/null 2>&1; then
    warn "有 nohup，但 iOS 会挂起后台任务 —— gateway 无法长驻"
else
    bad "不可用 —— hermes gateway 无法运行"
fi

# ---------------------------------------------------------------------------
# 6. 依赖可得性实测（最关键的一步）
# ---------------------------------------------------------------------------
hr
printf '\033[1m6. 依赖可得性实测\033[0m\n'
if [ -n "$PY" ] && "$PY" -m pip --version >/dev/null 2>&1; then
    D="${TMPDIR:-/tmp}/hermes-probe-$$"
    for pkg in pydantic-core cryptography aiohttp psutil; do
        item "6" "$pkg"
        if "$PY" -m pip download "$pkg" --no-deps -d "$D" >/dev/null 2>&1; then
            ok "可获得"
        else
            bad "无法获得（无 iOS wheel 且无法本地构建）"
        fi
    done
    rm -rf "$D" 2>/dev/null
    printf '     %s\n' "注：这里用 --no-deps 只探测单个包；Hermes 还需要它们互相配合。"
else
    item "6" "依赖探测"; bad "跳过（无 pip）"
fi

# ---------------------------------------------------------------------------
# 7. 可用性检查：能做什么
# ---------------------------------------------------------------------------
hr
printf '\033[1m7. 可用的替代能力\033[0m\n'
for c in ssh curl wget lg2 git; do
    item "7" "$c"
    command -v "$c" >/dev/null 2>&1 && ok "$(command -v "$c")" || warn "缺失"
done
printf '     %s\n' "a-Shell 的 ssh 可用于路线 B（远程 Hermes + 原生终端）。"

# ---------------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------------
hr
printf '\033[1m结论\033[0m\n'
printf '通过 %d 项，阻断 %d 项。\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    cat <<'EOM'

在 a-Shell 上原生运行 Hermes：不可行。

a-Shell 是原生 arm64（比 iSH 快得多），但缺三样东西：
  1. Python 只有 3.11，而 Hermes 依赖全部要求 >= 3.14
  2. 没有 Rust —— pydantic-core / cryptography 无法构建
  3. 没有 Node.js，且 iOS 禁止 fork（terminal 工具、pm/worker.py 失效）

a-Shell 的正确用法是「原生客户端」而不是「运行宿主」：

  路线 B（推荐）
    在 Linux 主机上跑 Hermes，a-Shell 里直接 ssh 过去：
        ssh user@your-linux-host
    终端是原生的，agent 跑在真实 CPU 上，延迟只来自网络。

  路线 C
    主机上 hermes dashboard，iOS Safari 打开后「添加到主屏幕」。

  路线 A（iSH）
    功能完整，但 iSH 是指令级模拟，比 a-Shell 慢一个数量级。
EOM
else
    printf '\n全部通过 —— 请把输出贴到 issue，这个结论值得重新评估。\n'
fi
hr
