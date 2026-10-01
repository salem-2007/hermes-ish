#!/bin/sh
# =============================================================================
#  a-shell-setup.sh — 给 a-Shell 补上 clear，并加一些顺手的别名
#
#  背景：a-Shell 没有 clear 命令（其命令字典里根本没有它），所以清屏要用
#        ANSI 转义序列。a-Shell 每个新窗口都会执行 ~/Documents/.profile，
#        因此把别名写进去就能永久生效。
#
#  用法（在 a-Shell 里）：
#      sh a-shell-setup.sh
#
#  行为：
#    * 先备份已有的 ~/Documents/.profile
#    * 只追加缺失的行，重复执行安全
#    * 不覆盖你已有的配置
#
#  ASCII-only 输出：a-Shell 的 /bin/sh 处理多字节字符有缺陷。
# =============================================================================

DOCS="$HOME/Documents"
PROFILE="$DOCS/.profile"
STAMP="$(date +%Y%m%d_%H%M%S)"

printf 'a-Shell setup -- clear + quality of life aliases\n'
printf 'profile: %s\n\n' "$PROFILE"

# ---------------------------------------------------------------------------
# 0. sanity check
# ---------------------------------------------------------------------------
if [ ! -d "$DOCS" ]; then
    printf '[NO] %s not found -- is this really a-Shell?\n' "$DOCS"
    exit 1
fi
printf '[OK] Documents directory found\n'

# ---------------------------------------------------------------------------
# 1. back up
# ---------------------------------------------------------------------------
if [ -f "$PROFILE" ]; then
    cp "$PROFILE" "$PROFILE.bak.$STAMP" 2>/dev/null \
        && printf '[OK] backed up existing .profile -> .profile.bak.%s\n' "$STAMP"
else
    : > "$PROFILE"
    printf '[OK] created a new .profile\n'
fi

# ---------------------------------------------------------------------------
# 2. append missing lines
#    `grep -q` guards every line so re-running never duplicates.
# ---------------------------------------------------------------------------
add() {  # add <marker> <line>
    if grep -qF "$1" "$PROFILE" 2>/dev/null; then
        printf '[--] already present: %s\n' "$1"
    else
        printf '%s\n' "$2" >> "$PROFILE"
        printf '[OK] added: %s\n' "$1"
    fi
}

printf '\n-- aliases --\n'

# The important one: a-Shell has no clear.
add "alias clear="  "alias clear='printf \"\\033[2J\\033[H\"'"
add "alias cls="    "alias cls='printf \"\\033[2J\\033[H\"'"
# Also wipe the scrollback (xterm extension; harmless if unsupported).
add "alias clsb="   "alias clsb='printf \"\\033[2J\\033[3J\\033[H\"'"

# ls has no colour by default in a-Shell
add "alias ll="     "alias ll='ls -l'"
add "alias la="     "alias la='ls -a'"

printf '\n-- environment --\n'
# UTF-8, so tools stop mangling multi-byte text where they can honour it
add "export LANG=" "export LANG=en_US.UTF-8"
# ssh keys live under Documents (iOS makes ~ read-only); make that explicit
add "export SSH_HOME=" "export SSH_HOME=\"\$HOME/Documents/\""

# ---------------------------------------------------------------------------
# 3. verify
# ---------------------------------------------------------------------------
printf '\n-- verification --\n'
if grep -qF "alias clear=" "$PROFILE"; then
    printf '[OK] clear is defined\n'
else
    printf '[NO] clear was not written -- check permissions\n'
fi
printf '\nprofile now contains %s lines\n' "$(wc -l < "$PROFILE" | tr -d ' ')"

cat <<'EOM'

Next steps:
  1. Open a NEW a-Shell window (the profile runs per window),
     or load it now with:  . ~/Documents/.profile
  2. Try:  clear

What it does:
  clear  - wipe the visible screen
  cls    - same
  clsb   - also drop the scrollback buffer (if the terminal supports it)

Why clear was missing:
  a-Shell's command set comes from ios_system, and neither its main nor
  extra command dictionary defines clear. The standard workaround is the
  ANSI sequence ESC[2J (erase display) + ESC[H (cursor home) -- exactly
  what the alias above sends.

Note: your existing .profile was backed up, and this script only appends
lines that are not already there, so it is safe to run again.
EOM
