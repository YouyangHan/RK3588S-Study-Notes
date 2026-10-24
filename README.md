# RK3588S 学习记录

记录 RK3588S 开发板的配置过程、踩坑经验与可复用的解决方案。

目前主要成果：

1. **在无物理显示器的情况下，通过 Windows 远程桌面 (RDP) 直接进入板子的 GNOME 桌面，且重启后自动生效、无需任何人工操作。**
2. **在 Windows 上直接交叉编译 aarch64 程序**（Arm GNU Toolchain 15.2.Rel1），编译产物可直接在板子上运行。

---

## 硬件与软件环境

| 项 | 内容 |
|----|------|
| 开发板 | RK3588S |
| 系统 | Ubuntu 24.04.3 LTS (aarch64) |
| 桌面 | GNOME Shell 46 + Wayland + GDM3（已开启自动登录） |
| 板子地址 | `10.168.1.117`，SSH/RDP 账号 `tyzc` / `123456` |
| 主机 | Windows 11 + Git Bash + Python 3（paramiko） |
| 远程桌面 | 端口 `3389`，Windows 自带 `mstsc` 连接 |

---

## 目录结构

```
RK3588/
├── README.md                              ← 本文件（项目索引）
├── docs/                                  ← 文档目录
│   ├── rk3588-headless-remote-desktop.md  ← 无显示器远程桌面完整配置
│   ├── tools-scripts.md                   ← tools/ 下脚本的详细说明
│   └── arm-cross-compile-windows.md       ← Windows 部署 ARM(aarch64) 交叉编译环境
├── examples/                              ← 示例代码
│   └── hello-aarch64/                     ← 交叉编译 hello world（含 CMake 工具链文件）
└── tools/                                 ← 远程操作工具
    ├── ssh_cmd.py                         ← SSH 远程执行命令
    ├── ssh_put.py                         ← 上传脚本并执行
    ├── download_toolchain.sh              ← 分段并行下载大文件（Arm 工具链）
    └── keyring-supervisor.sh              ← 板子上运行的密钥环守护脚本
```

---

## 文档目录说明

| 文档 | 作用 | 主要内容 | 什么时候看 |
|------|------|----------|------------|
| [rk3588-headless-remote-desktop.md](docs/rk3588-headless-remote-desktop.md) | **无显示器远程桌面完整配置手册** | 方案选型、原理（密钥环 + 虚拟显示器）、**可直接照抄的一键部署脚本**、分步说明、验证方法、故障排查表、卸载回滚、安全说明 | 第一次配置、重装系统后复现、板子连不上时排查 |
| [tools-scripts.md](docs/tools-scripts.md) | **tools/ 脚本使用说明** | 每个脚本的作用、用法示例、工作原理、参数与限制、常见组合用法 | 日常远程操作、修改脚本前 |
| [arm-cross-compile-windows.md](docs/arm-cross-compile-windows.md) | **Windows ARM 交叉编译环境** | 方案选型、Arm GNU Toolchain 15.2.Rel1 部署步骤、gcc/CMake 用法、静态链接踩坑、WSL2 与板子本地编译备选、故障排查 | 要在 Windows 上给板子编译程序时 |

> 几篇文档互相引用：远程桌面的问题背景和最终配置见第一篇，脚本的具体用法见第二篇，交叉编译的部署与用法见第三篇。

---

## 工具目录说明

| 文件 | 运行位置 | 作用 | 典型用法 |
|------|----------|------|----------|
| `ssh_cmd.py` | Windows | 在板子上执行一条 SSH 命令并回显输出，替代 `sshpass` | `py -I tools/ssh_cmd.py "uptime"` |
| `ssh_put.py` | Windows | 上传本地文件到板子，可选立即执行（`run`=bash / `py`=python3 / `exe`=加执行位并运行；二进制自动跳过换行转换） | `MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py a.sh /tmp/a.sh run`<br>`MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py hello /tmp/hello exe` |
| `download_toolchain.sh` | Windows (Git Bash) | 分段并行下载大文件（Arm 官方 CDN 单连接慢时用） | `bash tools/download_toolchain.sh <URL> <输出> 8` |
| `keyring-supervisor.sh` | 板子 | 以 `--login` 方式启动并守护已解锁的 GNOME 密钥环，保证 RDP 开机后能读到凭据 | 由 `keyring-unlocked.service` 自动拉起，无需手动执行 |

---

## 快速开始

### 1. 远程桌面（Windows）

```bat
cmdkey /generic:TERMSRV/10.168.1.117 /user:tyzc /pass:123456
mstsc /v:10.168.1.117
```

首次连接会提示自签名证书警告，选「是」即可。

### 2. SSH

```bash
ssh tyzc@10.168.1.117
```

### 3. 用脚本远程检查状态

```bash
cd /d/Code/RK3588

# 板子是否在线
py -I tools/ssh_cmd.py "uptime"

# 远程桌面是否正常（密钥环 / 凭据 / 端口）
py -I tools/ssh_cmd.py "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; \
  busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked; \
  grdctl status | grep -E 'Status|Username|Password'; ss -tln | grep 3389"
```

### 4. 交叉编译并在板子上运行

```bash
cd /d/Code/RK3588/examples/hello-aarch64

# 编译（工具链需已按 docs/arm-cross-compile-windows.md 装好并加入 PATH）
aarch64-none-linux-gnu-gcc -O2 -static -o hello hello.c

# 上传 → 加执行位 → 运行，一条命令完成
cd /d/Code/RK3588
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py examples/hello-aarch64/hello /tmp/hello exe
# 期望输出：Hello from RK3588 cross-compile demo! / Built for: aarch64 (ARM64)
```

> 小程序加 `-static`，否则可能因工具链 glibc 比板子新而报 `GLIBC_2.xx not found`。

---

## 已解决的问题（学习记录）

### 无显示器远程桌面

**最终方案**：用户会话级 `gnome-remote-desktop`（RDP 3389），共享自动登录的本地 GNOME 桌面。

**核心难点与结论**：

1. **自动登录导致密钥环锁定** — GDM 自动登录不走 PAM 解锁 GNOME Keyring，RDP 凭据读不到，认证失败。
   解决：会话启动后由 `keyring-unlocked.service` 以 `gnome-keyring-daemon --login` 启动已解锁的守护进程，再重启 RDP 服务。
2. **拔掉物理显示器后 RDP 闪退** — 会话里没有逻辑显示器，RDP 无画面可采集。
   解决：给 `org.gnome.Shell@wayland.service` 加 `--virtual-monitor 1920x1080`。
3. **系统级 RDP 黑屏** — 远程 greeter 的 gnome-shell 起不来，本板不可用。
4. **`--login` 不能写进系统默认键环服务** — 会在 PAM 阶段卡死 GDM，桌面根本起不来。

**验证结果**：断开物理显示器 + 断电重启后，Windows `mstsc` 无需任何额外操作即可进入桌面。

### Windows 交叉编译 aarch64

**最终方案**：Arm GNU Toolchain 15.2.Rel1 的 **Windows (mingw) 原生版**，解压即用、免安装、免管理员权限。

**踩坑与结论**：

1. **官方 zip 没有顶层目录** — 直接解压会把 `bin/`、`lib/` 散到当前目录，必须先建目录再解进去。
2. **Git Bash 的 tar 不认 zip** — GNU tar 报 `This does not look like a tar archive`，要用系统的 `/c/Windows/System32/tar.exe`（bsdtar）。
3. **官方 CDN 单连接只有 ~50 KB/s** — 用 `tools/download_toolchain.sh` 分段并行下载（8 段，实测提速约 6 倍）；注意 curl 的 `-C -` 与 `-r` 不能同时用。
4. **工具链 sysroot 的 glibc 比板子新** — 动态链接产物可能报 `GLIBC_2.xx not found`，小程序一律 `-static`。
5. **`ssh_put.py` 曾会损坏二进制** — 旧版对所有文件做 `CRLF→LF` 替换，而 ELF 里也可能有 `0x0d 0x0a`（示例 hello 有 47 处），传上去会被截断。现已按 NUL 字节自动判定二进制并跳过转换，新增 `exe` / `raw` 模式。

**验证结果**：Windows 编译 → 上传 → 板上执行输出正常，上传前后 MD5 一致。

---

## 更新记录

| 日期 | 内容 |
|------|------|
| 2026-10-20 | 项目创建；完成无显示器 RDP 方案并验证重启；补充虚拟显示器支持；编写远程桌面配置文档与 tools 脚本说明 |
| 2026-10-22 | 部署 Windows 原生 aarch64 交叉编译环境（Arm GNU Toolchain 15.2.Rel1 → `D:\toolchains\`）；新增 `examples/hello-aarch64` 示例与《Windows 部署 ARM 交叉编译环境》文档 |
| 2026-10-24 | 板子地址更新为 `10.168.1.117`；移除固定静态 IP 方案，全仓地址 .115→.117；删除《板子 WiFi 固定静态 IP 配置》文档 |
| 2026-10-22 | 交叉编译全链路验证通过（板上运行正常、MD5 一致）；修复 `ssh_put.py` 损坏二进制的问题，新增 `exe` / `raw` 模式；补充工具链下载与解压踩坑 |
