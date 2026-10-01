# 原生 iOS 安装 Hermes：可行性研究

**结论先说**：在 iOS 上**不经过 Linux 模拟层**直接运行 Hermes，目前不可行。
原因不是配置问题，而是四道硬性限制，每一道都无法绕过。

本文记录调研依据，并给出三条**实际可用**的替代路线（其中两条能拿到
「原生 iOS 客户端」的体验）。

---

## 一、四道硬性限制

### 1. 需要 Python 3.14，而原生 iOS 环境最高 3.11

`pyproject.toml` 声明 `requires-python = ">=3.11,<3.15"`，看起来 3.11 就够。
但**核心依赖几乎全部带 `python_version >= '3.14'` 门控**：

```
openai==2.24.0; python_version >= '3.14'
pydantic==2.13.4; python_version >= '3.14'
cryptography==50.0.1; python_version >= '3.14'
prompt_toolkit==3.0.52; python_version >= '3.14'
... 约 50 条，无一例外
```

在 3.11–3.13 上，这些条目**一个都不会安装**。也就是说声明的 3.11 下限
在实践中不成立 —— Hermes 实际需要 3.14。

原生 iOS 上的 Python 运行时（截至本文写作）：

| 环境 | Python 版本 | 包管理 |
|---|---|---|
| a-Shell | 3.11.x | pip + clang |
| Pyto | 3.11.x | pip（纯 Python 为主） |
| Pythonista 3 | 3.10 | 无 pip（StaSh） |
| Carnets | 3.11.x | Jupyter 生态 |

**没有一个提供 3.14。**

用 `native-ios/probe.sh` 可在你的设备上实测这一点。

### 2. 关键依赖需要 Rust，而 iOS 上没有 Rust 工具链

即使把版本门槛降下来，仍有多个依赖**必须编译**：

| 依赖 | 构建方式 | iOS 上能否构建 |
|---|---|---|
| `pydantic-core`（pydantic v2 的核） | Rust | ❌ 无 cargo |
| `cryptography` | Rust + OpenSSL | ❌ 无 cargo |
| `aiohttp` | C 扩展 | ⚠️ 理论可行，实际脆弱 |
| `psutil` | C 扩展 | ⚠️ 同上 |
| `ruamel.yaml.clib` | C 扩展 | ⚠️ 同上 |

`pydantic-core` 和 `cryptography` 是**不可选**的（Hermes 的核心依赖），
两者都要求 Rust。a-Shell 提供 clang，但**不提供 cargo**。

### 3. PyPI 没有 iOS 轮子（wheel）

pip 在 iOS 上找不到任何 `ios_*_arm64` 平台的预编译包 —— 因为 iOS 的 ABI
与 macOS 不同，PyPI 生态基本不发布 iOS wheel。

结果：**所有依赖都必须从源码构建**。结合第 2 点，这条路直接堵死。

### 4. 没有 Node.js，且 iOS 沙箱限制进程模型

- **Node.js**：Hermes 的 TUI 和 Web UI 依赖它，原生 iOS Python 环境不提供。
- **进程模型**：Pyto/Pythonista 无法 `fork`/`exec` 任意二进制；
  Hermes 的 `terminal` 工具、子进程 worker（`pm/worker.py`）依赖真实进程。
- **后台服务**：iOS 不允许常驻守护进程，`hermes gateway` 这类长驻服务无法工作。

---

## 二、三条实际可用的路线

### 路线 A：iSH（当前方案，已验证）

在 iSH 里跑 Alpine Linux。有完整的 POSIX、Python 3.14、Node、进程模型。

```sh
curl -fsSL https://raw.githubusercontent.com/salem-2007/hermes-ish/master/install.sh | bash
```

**代价**：iSH 是**指令级模拟**（x86 on ARM），CPU 慢 10–50 倍。
Hermes 启动要 1–2 分钟。

**收益**：功能完整 —— 工具调用、终端、文件、TUI、Web UI 全部可用。

### 路线 B：远程 Hermes + 原生 iOS 终端 ★

**Hermes 跑在 Linux 机器上，iOS 只做原生终端客户端。**

终端本身是原生的（不模拟），只有 agent 进程在远端。

```sh
# 在 Linux 主机上
hermes gateway start        # 或直接跑 hermes
```

iOS 端用原生 SSH 客户端连接：

| 客户端 | 说明 |
|---|---|
| **Blink Shell** | 原生 arm64，Mosh 支持，断线自动重连 |
| **a-Shell** | 免费，内置 `ssh` |
| **Termius** | 图形化，多设备同步 |

**优点**：
- iOS 侧零模拟开销，键盘响应、滚动都是原生的
- Hermes 用宿主机的真实 CPU，快 10–50 倍
- 手机只是瘦客户端，耗电低

**这是「原生 iOS 体验」的最佳答案** —— 你感受到的延迟来自网络，不是模拟器。

### 路线 C：远程 Hermes + 原生 iOS 界面

Hermes 自带 Web UI，可以在 iOS 上用 Safari 或快捷指令访问：

```sh
# Linux 主机
hermes dashboard            # 启动 Web UI
```

然后：
- iOS Safari 直接打开（可「添加到主屏幕」，像原生 App）
- 或用**快捷指令**封装成图标，一键打开

适合不想碰命令行的场景。

---

## 三、如果你仍想尝试原生安装

`native-ios/probe.sh` 是一个**只读探针**，可以在 a-Shell / Pyto 里运行，
逐项验证上述限制。它不会修改你的系统，只做检测并打印结论：

```sh
sh probe.sh
```

输出示例（在 a-Shell 上）：

```
[1] Python 版本 ................ 3.11.8   ✗ 需要 >= 3.14
[2] pip 可用性 ................. 可用
[3] C 编译器 (clang/cc) ........ 可用
[4] Rust 工具链 (cargo) ........ 缺失    ✗ pydantic-core 无法构建
[5] Node.js .................... 缺失    ✗ TUI/Web UI 不可用
[6] fork/exec 任意二进制 ....... 受限    ✗ terminal 工具不可用
[7] 尝试解析核心依赖 ........... 失败    ✗ 版本门控排除

结论：原生安装不可行，见 docs/NATIVE-IOS.md
建议：路线 B（远程 Hermes + Blink/a-Shell SSH）
```

把输出贴到 issue 里，如果你发现了我们没预料到的环境（比如某个新的
iOS Python 运行时提供了 3.14 + Rust），这个结论就值得重新评估。

---

## 四、为什么不做「移植」

理论上可以打补丁绕开上述限制，例如：

- 把 `python_version >= '3.14'` 门控放宽到 3.11 —— 但依赖本身仍需要 Rust 构建
- 用纯 Python 替代品换掉 pydantic/cryptography —— 等于重写 Hermes 的核心
- 静态编译所有依赖 —— 需要 iOS 上没有的交叉编译链和签名流程

这些都属于「重写一个不同的项目」，不是「让 Hermes 在 iOS 原生运行」。
投入产出比远低于路线 B。
