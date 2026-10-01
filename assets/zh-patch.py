#!/usr/bin/env python3
"""Chinese localisation for Hermes CLI panels that bypass the i18n layer.

Hermes ships a full zh catalog (locales/zh.yaml, 3866 keys) and routes most
static strings through ``t()``. A subset of panels never adopted it: the
``hermes config show`` sections, its field labels, and status words are inline
literals in hermes_cli/config.py, so they stay English under
``display.language: zh``.

Rather than editing upstream source (which the next update would overwrite),
this module wraps the few print-side functions those panels use and rewrites
their output on the way to the terminal. Translations are applied longest-first
so multi-word labels win over their substrings, and an untranslated string is
left untouched -- unknown output degrades to English instead of being mangled.

Enabled by hermes_cli/zh_patch.py, which imports it before the CLI runs.
"""
from __future__ import annotations

import os
import re
import sys

# Exact strings, longest first at apply time.
EXACT: dict[str, str] = {
    # --- window titles / banners ---
    "Hermes Configuration": "Hermes 配置",
    "Hermes Configuration ": "Hermes 配置",
    # --- config show: section headers ---
    "Auxiliary Models (overrides)": "辅助模型（覆盖）",
    "Context Compression": "上下文压缩",
    "Messaging Platforms": "消息平台",
    "Skill Settings": "技能设置",
    "API Keys": "API 密钥",
    "Paths": "路径",
    "Terminal": "终端",
    "Timezone": "时区",
    "Display": "显示",
    "Bell": "提示音",
    "Notification": "通知",
    "Memory Query": "记忆查询",
    "Vision": "视觉",
    "Model": "模型",
    # --- config show: field labels ---
    "Max turns": "最大轮数",
    "Personality": "人格",
    "Reasoning": "推理过程",
    "Working dir": "工作目录",
    "Backend": "后端",
    "Timeout": "超时",
    "Threshold": "阈值",
    "Token cap": "Token 上限",
    "Target ratio": "目标比例",
    "Protect first": "保留开头",
    "Protect last": "保留结尾",
    "Provider": "提供方",
    "Secrets": "密钥文件",
    "Config:": "配置：",
    "Install": "安装路径",
    "Timezone:": "时区：",
    "Anthropic": "Anthropic",
    "Messaging": "消息平台",
    "Base URL": "接口地址",
    "API Key": "API 密钥",
    "Context": "上下文",
    "Tools": "工具",
    "Skills": "技能",
    "Sessions": "会话",
    "Memory": "记忆",
    "Memory Query": "记忆查询",
    "Vision": "视觉",
    "Reasoning Effort": "推理强度",
    "Max Context": "上下文上限",
    "Off": "关",
    "On": "开",
    "Unknown": "未知",
    "Error": "错误",
    "Warning": "警告",
    # --- status / state words ---
    "configured": "已配置",
    "not configured": "未配置",
    "not set": "未设置",
    "(server-local)": "(服务器本地)",
    "(auto)": "(自动)",
    "Disabled": "已禁用",
    "Enabled": "已启用",
    "Default": "默认",
    "System": "系统",
    "Local": "本地",
    "Custom": "自定义",
    # --- setup wizard / misc ---
    "Missing required environment variables": "缺少必需的环境变量",
    "Let's configure them now": "现在来配置它们",
    "Get your key at": "在此获取密钥：",
    "Set later with": "稍后设置：",
    "Created": "已创建",
    "Saved": "已保存",
    "Config version:": "配置版本：",
}

# Words replaced only when they stand alone. Without the boundary guard,
# "Config:" matches the "on" inside "config.yaml" and rewrites the filename --
# these are substituted after the phrase table and never inside a path.
STANDALONE: dict[str, str] = {
    "on": "开",
    "off": "关",
    "none": "无",
    "yes": "是",
    "no": "否",
    "enabled": "已启用",
    "disabled": "已禁用",
}
_WORD_BOUNDARY = {k: re.compile(r"(?<![\w./-])" + re.escape(k) + r"(?![\w./-])", re.I)
                 for k in STANDALONE}

# Patterns with a captured payload: (regex, template). The template keeps
# whatever the original captured, so dynamic parts (paths, versions, counts)
# survive untouched.
PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # "Config:       /root/.hermes/config.yaml"
    (re.compile(r"Config:(\s+)(\S+)"), r"配置：\1\2"),
    (re.compile(r"Secrets:(\s+)(\S+)"), r"密钥：\1\2"),
    (re.compile(r"Install:(\s+)(\S+)"), r"安装：\1\2"),
    (re.compile(r"Timezone:(\s+)(\S+)"), r"时区：\1\2"),
    # "✓ Saved {name}"
    (re.compile(r"✓ Saved (\S+)"), r"✓ 已保存 \1"),
    # "Config version: 49 → 49"
    (re.compile(r"Config version:(\s*)(\d+)(\s*)→(\s*)(\d+)"), r"配置版本：\1\2\3→\4\5"),
]

# Lines printed by PM before the CLI boots (install out-of-sync warning).
EARLY_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"install out of sync \(([^)]*)\)"),
     r"安装状态不同步（\1）"),
    (re.compile(r"this unknown-managed install must rebuild the artifact to fix"),
     "请运行 hermes pm repair 修复"),
]

# Longest-first so "Target ratio" is tried before "ratio"-like substrings.
_ORDERED = sorted(EXACT, key=len, reverse=True)

# CJK ranges, for the display-width check in _pad().
_CJK = re.compile("[\u2E80-\u9FFF\u3000-\u303F\uFF00-\uFFEF]")


# The framed title box is drawn to an exact column count; substituting a
# shorter Chinese label leaves the right border dangling. Redraw the whole box.
_BOX = re.compile(r"^(\s*)([┌│└])(─+|\s*)(.+?)\s*([┐│┘])\s*$")


def _redraw_box(line: str) -> str:
    """Rebuild a bordered title line so the frame closes on the same column."""
    m = _BOX.match(line)
    if not m:
        return line
    indent, edge1, _, text, edge2 = m.groups()
    width = sum(2 if ord(c) > 0x2E7F else 1 for c in text)
    inner = 57 - width
    if inner < 2:
        return line
    if edge1 == "┌":
        return f"{indent}┌{'─' * inner}┐"
    if edge1 == "└":
        return f"{indent}└{'─' * inner}┘"
    left = inner // 2
    return f"{indent}│{' ' * left}{text}{' ' * (inner - left)}│"


def _pad(line: str) -> str:
    """Re-pad a translated ``label:  value`` line.

    CJK glyphs render two columns wide, so keeping the original ASCII column
    offsets would leave the values ragged. Recompute the run of spaces after
    the colon from the label's *display* width instead of its char count.
    """
    m = re.match(r"^(\s*[^\s:]+:)(\s+)(\S.*)$", line)
    if not m:
        return line
    label, _, rest = m.groups()
    width = sum(2 if ord(c) > 0x2E7F else 1 for c in label)
    return f"{label}{' ' * max(1, 16 - width)}{rest}"


def translate(text: str) -> str:
    """Return *text* with any known CLI literals replaced by Chinese."""
    if not text or not re.search(r"[A-Za-z]{2,}", text):
        return text
    out = text
    for pattern, repl in EARLY_PATTERNS:
        out = pattern.sub(repl, out)
    for pattern, repl in PATTERNS:
        out = pattern.sub(repl, out)
    for en in _ORDERED:
        if en in out:
            out = out.replace(en, EXACT[en])
    for word, pat in _WORD_BOUNDARY.items():
        if word in out.lower():
            out = pat.sub(STANDALONE[word], out)
    if _CJK.search(out):
        out = _pad(out)
        out = _redraw_box(out)
    return out


def _patched_print(func):
    """Wrap *func* so each formatted chunk goes through translate()."""
    def wrapper(*args, **kwargs):
        args = tuple(translate(a) if isinstance(a, str) else a for a in args)
        kwargs = {k: (translate(v) if isinstance(v, str) else v) for k, v in kwargs.items()}
        return func(*args, **kwargs)
    try:
        wrapper.__wrapped__ = func  # type: ignore[attr-defined]
        import functools
        functools.update_wrapper(wrapper, func)
    except Exception:
        pass
    return wrapper


_INSTALLED = False


def install() -> bool:
    """Patch builtins.print and hermes_cli.config._section. Idempotent."""
    global _INSTALLED
    if _INSTALLED or os.environ.get("HERMES_ZH_PATCH") == "0":
        return False
    try:
        import builtins
        builtins.print = _patched_print(builtins.print)
    except Exception:
        return False

    # hermes_cli.config._section writes the panel headers; route it too so the
    # header is translated even when it bypasses print().
    try:
        from hermes_cli import config as _cfg
        if getattr(_cfg, "_zh_patched", False):
            _INSTALLED = True
            return True
        _orig_section = _cfg._section

        def _section(title, *a, **kw):
            return _orig_section(translate(title), *a, **kw)

        _cfg._section = _section
        _cfg._zh_patched = True
    except Exception:
        pass

    _INSTALLED = True
    return True


__all__ = ["install", "translate", "EXACT", "PATTERNS"]


if __name__ == "__main__":
    for line in sys.stdin:
        sys.stdout.write(translate(line.rstrip("\n")) + "\n")