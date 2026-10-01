# native-ios — 原生 iOS 安装探索

这个目录是**调研产物**，不是安装器。

## 结论

在 iOS 上不经过 Linux 模拟层直接运行 Hermes，**目前不可行**。
完整依据见 [`../docs/NATIVE-IOS.md`](../docs/NATIVE-IOS.md)。

四道硬性限制（每一道都足以单独阻断）：

| # | 限制 | 影响 |
|---|---|---|
| 1 | 需要 Python **3.14**，原生 iOS 环境最高 3.11 | 约 50 个核心依赖全部带 `>=3.14` 门控 |
| 2 | `pydantic-core` / `cryptography` 需要 **Rust** | iOS 无 cargo，无法构建 |
| 3 | PyPI **不发布 iOS wheel** | 所有依赖都得从源码构建 |
| 4 | 无 **Node.js**，沙箱限制进程/后台服务 | TUI、Web UI、terminal 工具、gateway 不可用 |

## 在设备上实测

```sh
sh probe.sh
```

只读探针，逐项验证上述限制，不会修改任何东西。把输出贴到 issue 里。

## 推荐路线

**路线 B：远程 Hermes + 原生 iOS 终端** ← 最佳「原生体验」

```sh
# Linux 主机
hermes gateway start

# iOS：用原生 SSH 客户端连接
#   Blink Shell（原生 arm64 + Mosh）
#   a-Shell（免费，内置 ssh）
#   Termius
```

终端是原生的，agent 跑在真实 CPU 上 —— 延迟来自网络，不是模拟器。

**路线 C：远程 Hermes + 原生 iOS 界面**

```sh
# Linux 主机
hermes dashboard
```

iOS Safari 打开后「添加到主屏幕」，或用快捷指令封装成图标。

**路线 A：iSH**（本仓库主分支，功能完整但 CPU 模拟慢 10–50 倍）
