<div align="center">

# NXProMap

**SSH Proxy & Port Mapping Helper for Linux — Multi-Port, Tunnel Lifecycle & Structured Dashboard**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-Linux-blue.svg)](https://github.com/LiHang-CV/NXProMap)

</div>

---

<p align="center">
  <a href="#english">English</a> &nbsp;|&nbsp;
  <a href="#中文">中文</a> &nbsp;|&nbsp;
  <a href="#changelog">Changelog</a>
</p>

---

<a id="english"></a>

## English

### What is NXProMap?

`NXProMap` is a Bash helper script designed for researchers and developers who work on **remote Linux servers via SSH**. It manages SOCKS5 proxy tunnels and local port forwarding with a single command, and displays a structured, color-coded dashboard of your environment at a glance.

It is the successor to [nx_proxy.sh](https://github.com/LiHang-CV/lh-proxy-helper), with a focus on robustness and automation.

### Features

- **Multi-Port Proxy** (`nxpon`) — scans a list of candidate ports (`NX_PROXY_PORTS`) and activates the first reachable SOCKS5 tunnel
- **Tunnel Lifecycle** (`nxpoff` / `nxmoff`) — detects and optionally kills lingering SSH tunnel processes by PID when you turn off the proxy or port map
- **Port Mapping** (`nxmon`) — generates the SSH `-L` command for TensorBoard / WebUI and tries to push it to your local clipboard via **OSC 52**
- **Structured Dashboard** (`nxinfo`) — aligned table blocks for System, GPU (nvidia-smi), Proxy/Map, and Tools status
- **Temp Proxy Exec** (`nxrun`) — run a single command under proxy, then auto-restore the environment

### Requirements

- Bash ≥ 4.0
- `curl`, `ss` (from `iproute2`)
- `ssh` (OpenSSH)
- *(Optional)* `nvidia-smi` for GPU info

### Installation

1. **Clone the repository**

   ```bash
   git clone https://github.com/LiHang-CV/NXProMap.git
   ```

2. **Copy the script to your remote server** (e.g., into `~/.config/` or any directory you prefer)

   ```bash
   scp NXProMap/nxpromap.sh user@your-server:~/.config/nxpromap.sh
   ```

3. **Fill in your SSH credentials** — edit the top of `nxpromap.sh`:

   ```bash
   NX_SSH_USER="your_username"
   NX_SSH_HOST="your.server.ip"
   NX_SSH_PORT="22"
   ```

4. **Source the script in your `~/.bashrc`** on the remote server:

   ```bash
   source ~/.config/nxpromap.sh
   ```

5. **Reload your shell**

   ```bash
   source ~/.bashrc
   ```

### Usage

| Command | Args | Description |
|---------|------|-------------|
| `nxpon` | `[mode]` | Start proxy — scans ports, activates first working tunnel |
| `nxpoff` | — | Stop proxy, kill tunnel processes, clean history |
| `nxmon` | `<remote_port> [local_port]` | Set port mapping, print & copy SSH `-L` command |
| `nxmoff` | — | Clear mapping record, kill tunnel |
| `nxrun` | `[mode] <cmd>` | Run command under temp proxy, auto-off after |
| `nxinfo` | — | Full-table environment dashboard |
| `nxhelp` | — | Show command reference |

**Proxy modes:** `socks5h` (default, remote DNS) · `socks5` · `http`

### OSC 52 Clipboard Note

`nxmon` and `nxpon` (when no tunnel found) will attempt to push SSH commands to your **local machine's clipboard** via the OSC 52 escape sequence. This works in most modern terminals (iTerm2, WezTerm, tmux ≥ 3.2). If it doesn't work in your terminal, the command is always printed on-screen as well.

---

<a id="中文"></a>

## 中文

### 这是什么？

`NXProMap` 是一个专为**通过 SSH 连接远程 Linux 服务器**的研究员和开发者设计的 Bash 辅助脚本。它可以一条命令管理 SOCKS5 代理隧道和本地端口转发，并以结构化、带颜色的表格展示你的完整运行环境。

它是 [nx_proxy.sh](https://github.com/LiHang-CV/lh-proxy-helper) 的升级版，重点增强了健壮性与自动化程度。

### 功能特性

- **多端口代理**（`nxpon`）— 按 `NX_PROXY_PORTS` 列表顺序扫描，自动激活第一个可用的 SOCKS5 隧道
- **隧道生命周期**（`nxpoff` / `nxmoff`）— 关闭代理或映射时，自动检测并可选终止残留 SSH 隧道进程
- **端口映射**（`nxmon`）— 生成 SSH `-L` 命令（适用于 TensorBoard/WebUI），并通过 **OSC 52** 尝试写入本地剪贴板
- **结构化状态面板**（`nxinfo`）— 对齐表格展示系统、GPU（nvidia-smi）、代理/映射、工具状态
- **临时代理执行**（`nxrun`）— 在代理下执行单条命令，完成后自动恢复环境

### 环境要求

- Bash ≥ 4.0
- `curl`、`ss`（来自 `iproute2`）
- `ssh`（OpenSSH）
- *（可选）* `nvidia-smi`，用于 GPU 信息展示

### 安装步骤

1. **克隆仓库**

   ```bash
   git clone https://github.com/LiHang-CV/NXProMap.git
   ```

2. **将脚本上传至远程服务器**（例如放在 `~/.config/`）

   ```bash
   scp NXProMap/nxpromap.sh user@your-server:~/.config/nxpromap.sh
   ```

3. **填写你的 SSH 信息** — 编辑 `nxpromap.sh` 顶部的配置：

   ```bash
   NX_SSH_USER="your_username"
   NX_SSH_HOST="your.server.ip"
   NX_SSH_PORT="22"
   ```

4. **在远程服务器的 `~/.bashrc` 中 source 脚本：**

   ```bash
   source ~/.config/nxpromap.sh
   ```

5. **重新加载 Shell**

   ```bash
   source ~/.bashrc
   ```

### 使用方法

| 命令 | 参数 | 说明 |
|------|------|------|
| `nxpon` | `[mode]` | 开启代理 — 扫描端口，激活第一个可用隧道 |
| `nxpoff` | — | 关闭代理，终止隧道进程，清理历史 |
| `nxmon` | `<远端端口> [本地端口]` | 设置端口映射，输出并尝试复制 SSH `-L` 命令 |
| `nxmoff` | — | 清除映射记录，终止隧道 |
| `nxrun` | `[mode] <命令>` | 在代理下执行单条命令，完成后自动关闭 |
| `nxinfo` | — | 全表格环境状态面板 |
| `nxhelp` | — | 显示命令参考表 |

**代理模式：** `socks5h`（默认，远端解析 DNS）· `socks5` · `http`

### OSC 52 剪贴板说明

`nxmon` 和 `nxpon`（无可用隧道时）会通过 OSC 52 转义序列尝试将 SSH 命令写入**本地机器**的剪贴板。该功能在大多数现代终端（iTerm2、WezTerm、tmux ≥ 3.2）中有效。若你的终端不支持，命令也会同时打印在屏幕上。

---

<a id="changelog"></a>

## Changelog

### v1.0.0 — 2026-03-27

- Initial public release (successor to `lh-proxy-helper / nx_proxy.sh`)
- Multi-port proxy scanning via `NX_PROXY_PORTS` array
- SSH tunnel process lifecycle management (`_find_ssh_tunnels`, `_kill_ssh_tunnel`)
- OSC 52 clipboard integration in `_nx_hint_cmd`
- Structured 5-block table dashboard in `nxinfo` (System / Compute / GPU / Proxy / Tools)
- Port validation in `nxmon` (range check 1–65535)
- Improved `nxrun` with `INT`/`TERM` signal trap handling
- Comprehensive bilingual comment header (EN + 中文)
