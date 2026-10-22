# tools/ 脚本说明文档

> 目录：`D:\Code\RK3588\tools`
> 这些脚本用于在 **Windows 主机上远程操作 RK3588 开发板**（`10.168.1.115`）。
> 背景：Windows 上既没有 `sshpass`，也没有原生可用的 `plink`，所以用 Python + paramiko 封装 SSH，实现"一条命令完成远程操作"。

---

## 0. 目录一览

| 文件 | 类型 | 作用 | 是否需要修改 |
|------|------|------|--------------|
| `ssh_cmd.py` | Python 脚本 | 在板子上执行一条命令并回显输出 | 板子 IP/账号变了才需要改 |
| `ssh_put.py` | Python 脚本 | 把本地脚本上传到板子，可选立即执行（bash / python3） | 同上 |
| `keyring-supervisor.sh` | Bash 脚本 | **部署在板子上运行的**密钥环守护进程监管脚本（RDP 开机自动解锁的关键） | 一般不用改 |

---

## 1. 前置条件

### 1.1 Windows 侧

- Python 3（命令为 `py`，如 `py -3.12`）
- `paramiko` 已安装：

  ```bash
  py -c "import paramiko; print(paramiko.__version__)"
  ```

  未安装时：

  ```bash
  py -m pip install paramiko
  ```

- 推荐在 **Git Bash** 中执行（本文示例均为 bash 语法）

### 1.2 网络与板子

- 板子与 Windows 在同一局域网，SSH（22 端口）可达
- 板子开启 SSH 服务，账号可用（当前：`tyzc / 123456`）
- 验证：

  ```bash
  ping -n 1 10.168.1.115
  ```

### 1.3 统一的工作方式

所有示例都假设当前目录是 `D:\Code\RK3588`，即：

```bash
cd /d/Code/RK3588
```

脚本内部硬编码了连接信息：

```python
HOST, USER, PASS = "10.168.1.115", "tyzc", "123456"
```

换板子/换账号时，**两个 Python 脚本都要改这一行**。

---

## 2. `ssh_cmd.py` —— 远程执行一条命令

### 2.1 作用

建立 SSH 连接 → 在板子上执行**一条命令** → 把 stdout/stderr 回显到 Windows 终端。

它等价于：

```bash
sshpass -p 123456 ssh tyzc@10.168.1.115 "<命令>"
```

但没有 `sshpass` 依赖。

### 2.2 用法

```bash
py -I tools/ssh_cmd.py "<远程命令>"
```

> `-I` 让 Python 以隔离模式运行，不加载当前目录的模块，避免被同名文件干扰；建议始终带上。

### 2.3 常用示例

```bash
# 查看系统信息
py -I tools/ssh_cmd.py "uname -a; cat /etc/os-release | head -2"

# 查看 RDP 状态
py -I tools/ssh_cmd.py "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; grdctl status"

# 查看端口监听
py -I tools/ssh_cmd.py "ss -tln | grep 3389 || echo NO_3389"

# 查看桌面会话
py -I tools/ssh_cmd.py "loginctl list-sessions --no-legend; pgrep -a gnome-shell"

# 需要 sudo 时，把密码通过管道喂给 sudo -S
py -I tools/ssh_cmd.py "echo 123456 | sudo -S systemctl restart gdm3"

# 重启板子（nohup + 后台，避免 SSH 断开时报错）
py -I tools/ssh_cmd.py "echo 123456 | sudo -S sh -c 'nohup systemctl reboot >/dev/null 2>&1 &'"
```

### 2.4 工作原理

```python
cli.connect(HOST, username=USER, password=PASS, timeout=10)   # 连接，10 秒超时
stdin, stdout, stderr = cli.exec_command(cmd, timeout=120)    # 单条命令，120 秒超时
out = stdout.read().decode("utf-8", "replace")                # 读取标准输出
err = stderr.read().decode("utf-8", "replace")                # 读取标准错误
```

- 输出编码按 UTF-8 解码，无法解码的字符用 `�` 替换（因此中文可能显示为乱码，取决于板子 locale）
- stderr 前会加一行 `[STDERR]` 便于区分
- 首次连接自动接受主机密钥（`AutoAddPolicy`），不会提示 `yes/no`

### 2.5 注意事项

| 事项 | 说明 |
|------|------|
| 只能执行**一条**命令 | 多条命令用 `;` 或 `&&` 连接，整体放进双引号 |
| 引号嵌套 | 外层用双引号，命令内部优先用单引号；需要时用 `\"` 转义 |
| Git Bash 路径转换 | 命令里出现 `/tmp/xxx` 这类路径时，Git Bash 可能改写成 `C:/...`。加前缀 `MSYS_NO_PATHCONV=1` 禁用转换 |
| 超时 | 单条命令 120 秒，长时间的构建/拷贝会超时；需要更久请改 `timeout=120` |
| 退出码不传递 | 脚本本身总是以 0 退出，**远程命令失败不会体现在 Windows 的退出码里**，要看输出内容判断 |
| 每次新建连接 | 不保持连接，连续多次调用会有额外握手开销（一般可忽略） |

---

## 3. `ssh_put.py` —— 上传脚本并可选立即执行

### 3.1 作用

把 Windows 本地文件上传到板子，并可在上传后立刻用 `bash` 或 `python3` 执行。

用于"写脚本 → 上传 → 执行"的一体化流程，避免在 SSH 命令行里写复杂转义。

### 3.2 用法

```bash
# 只上传
py -I tools/ssh_put.py <本地文件> <远程路径>

# 上传并用 bash 执行
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py <本地文件> <远程路径> run

# 上传并用 python3 执行
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py <本地文件> <远程路径> py
```

| 参数 | 说明 |
|------|------|
| 第 1 个 | Windows 本地文件路径 |
| 第 2 个 | 板子上的目标路径（**建议用绝对路径**，如 `/tmp/check.sh`）。注意这是**文件**路径；给目录路径会失败 |
| 第 3 个（可选） | `run` = `bash <路径>`；`py` = `python3 <路径>`；`exe` = `chmod +x <路径> && <路径>`（传 ELF 可执行文件用这个）；`raw` = 只上传且跳过换行转换；省略则只上传 |

### 3.3 常用示例

```bash
# 上传一个检查脚本并立即执行
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py tools/keyring-supervisor.sh /tmp/keyring-supervisor.sh run

# 上传 Python 脚本并用 python3 执行
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py my_check.py /tmp/my_check.py py

# 只上传，之后手动执行
py -I tools/ssh_put.py tools/keyring-supervisor.sh /home/tyzc/.local/bin/keyring-supervisor.sh

# 上传交叉编译出的 ELF，自动加执行位并运行
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py examples/hello-aarch64/hello /tmp/hello exe
```

### 3.4 工作原理

```python
data = open(local_path, "rb").read()
if mode != "raw" and b"\x00" not in data:          # 文本才做换行转换，二进制跳过
    data = data.replace(b"\r\n", b"\n")
stdin, stdout, stderr = cli.exec_command(f"cat > {remote_path}")  # 用 cat > 写入远程文件
stdin.write(data)
stdin.channel.shutdown_write()                                  # 通知对端写完
```

- **换行归一化（仅文本）**：把 Windows 的 `CRLF` 转成 `LF`，避免 bash 报 `\r: command not found`
- **二进制安全**：ELF 等二进制里也可能出现 `0x0d 0x0a` 字节对（`examples/hello-aarch64/hello` 里就有 47 处），无条件替换会截断文件。脚本用 `NUL` 字节判定内容是否为二进制，跳过转换；也可用 `raw` 参数强制跳过
- **不用 SFTP**：早期用 `sftp.put` 时，Git Bash 会把远程路径 `/tmp/x` 改写成 `C:/...`，导致 `FileNotFoundError`。改用 `cat > 路径` 后稳定，且不依赖板子上的 SFTP 子系统
- 执行阶段与 `ssh_cmd.py` 完全一致（120 秒超时、UTF-8 解码、stderr 标记）

### 3.5 注意事项

| 事项 | 说明 |
|------|------|
| `MSYS_NO_PATHCONV=1` | 远程路径是 `/tmp/...` 这类绝对路径时**必须加**，否则会被 Git Bash 改写 |
| 目标目录必须存在 | `cat >` 不会自动创建目录，先 `ssh_cmd.py "mkdir -p ..."` |
| 文件权限 | 上传后默认没有可执行位；用 `run` 调 bash 执行不受影响，若要直接执行用 `exe` 模式或 `ssh_cmd.py "chmod +x <路径>"` |
| 路径含空格/特殊字符 | 未做转义，避免这种路径 |
| 覆盖行为 | 同名文件会被直接覆盖，不备份 |
| 二进制文件 | 靠 `NUL` 字节自动识别并跳过换行转换；不确定时显式加 `raw`，上传后 `md5sum` 对比本地 |
| 目标路径别写成目录 | 第二个参数是**目标文件名**；若误传目录路径，`cat >` 会失败或传不到位，表现为板上找不到可执行文件 |

---

## 4. `keyring-supervisor.sh` —— 板子上的密钥环守护脚本

> 这个脚本**不是**在 Windows 上运行的，而是部署到板子的 `~/.local/bin/keyring-supervisor.sh`，
> 由用户级 systemd 服务 `keyring-unlocked.service` 拉起。
> 背景和目标见 [rk3588-headless-remote-desktop.md](rk3588-headless-remote-desktop.md)。

### 4.1 解决什么问题

GDM 自动登录不会用 PAM 解锁 GNOME 登录密钥环，导致开机后：

- 密钥环处于锁定状态
- gnome-remote-desktop 读不到存在密钥环里的 RDP 凭据
- 远程桌面认证失败（`grdctl status` 显示 `Username: (empty)`）

只有**守护进程自身以 `--login` 方式启动**才能解锁密钥环；客户端方式（`--unlock` / `--login`）解不开运行中的守护进程。

### 4.2 脚本做的事（逐段说明）

```bash
systemctl --user stop --no-block gnome-keyring-daemon.service gnome-keyring-daemon.socket
sleep 1
```

停止系统默认的密钥环服务与 socket，避免和我们启动的实例抢控制套接字。

```bash
while true; do
    killall -q gnome-keyring-daemon 2>/dev/null
    sleep 1
```

每轮先清掉所有现存键环进程（包括 D-Bus 自动激活出来的锁定实例）。

```bash
    printf '%s\n' "$KEYRING_PASSWORD" | \
        /usr/bin/gnome-keyring-daemon --foreground --login \
            --components=pkcs11,secrets \
            --control-directory="$XDG_RUNTIME_DIR/keyring" &
    pid=$!
```

用环境变量 `KEYRING_PASSWORD`（来自 `~/.config/keyring.env`）作为登录密码，以前台方式启动守护进程。
`--login` 是 PAM 登录时使用的模式：它会用 stdin 的密码解锁（不存在时创建）登录密钥环。

```bash
    for i in $(seq 1 10); do
        sleep 1
        kill -0 "$pid" 2>/dev/null || break
        locked=$(busctl --user get-property org.freedesktop.secrets "$COLLECTION" \
                     org.freedesktop.Secret.Collection Locked 2>/dev/null)
        if [ "$locked" = "b false" ]; then
            ok=1
            break
        fi
    done
```

最多轮询 10 秒，通过 D-Bus 查询登录密钥环的 `Locked` 属性，直到变成 `false`（已解锁）。
这一步同时确认"当前提供 secrets 服务的就是我们启动的、已解锁的实例"。

```bash
    if [ "$ok" = "1" ]; then
        systemctl --user restart gnome-remote-desktop.service
        wait "$pid"
    else
        kill "$pid" 2>/dev/null
    fi
```

解锁成功 → **重启 RDP 服务**，让它重新连接有效的 secrets 服务并读取凭据（否则会缓存失效的 D-Bus 连接，报 `Couldn't retrieve RDP credentials`）。
随后 `wait` 让脚本一直守着这个守护进程；如果它意外退出，循环会重新拉起。
解锁失败 → 杀掉本实例，下一轮重试。

### 4.3 依赖与运行环境

| 项 | 要求 |
|----|------|
| 运行用户 | `tyzc`（普通用户，不能是 root） |
| 环境变量 | `KEYRING_PASSWORD`（必需）、`XDG_RUNTIME_DIR`（systemd 用户服务自动提供） |
| 系统命令 | `systemctl`、`busctl`、`killall`（psmisc）、`gnome-keyring-daemon` |
| 依赖服务 | `gnome-keyring-daemon` 已安装；桌面会话已启动（`graphical-session.target`） |

对应的 systemd 用户服务（部署在板子上）：

```ini
# ~/.config/systemd/user/keyring-unlocked.service
[Unit]
Description=Unlocked GNOME Keyring daemon (login keyring with password from env)
After=graphical-session.target
Requires=graphical-session.target

[Service]
Type=simple
EnvironmentFile=%h/.config/keyring.env
ExecStart=%h/.local/bin/keyring-supervisor.sh
Restart=always
RestartSec=3

[Install]
WantedBy=graphical-session.target
```

### 4.4 调试方法

```bash
# 服务状态
py -I tools/ssh_cmd.py "export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user status keyring-unlocked.service --no-pager"

# 密钥环是否解锁（b false 为正常）
py -I tools/ssh_cmd.py "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked"

# RDP 凭据是否可读（(hidden) 为正常，(empty) 表示没读到）
py -I tools/ssh_cmd.py "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; grdctl status | grep -E 'Username|Password'"

# 键环进程
py -I tools/ssh_cmd.py "ps -eo pid,args | grep keyring-daemon | grep -v grep"
```

### 4.5 修改时注意

- 不要把 `--login` 写进 `gnome-keyring-daemon.service` 的 `ExecStart`：开机 PAM 阶段会被 socket 激活，**卡住 GDM，桌面根本起不来**
- 不要用 `pkill -f "gnome-keyring-daemon --foreground"`：它会把包含同样字符串的**自己**也杀掉（用 `killall` 按进程名匹配）
- 修改密码后同步更新 `~/.config/keyring.env`，然后 `systemctl --user restart keyring-unlocked.service`
- 该脚本的 systemd 服务日志可用 `sudo journalctl _UID=1000 -b` 查看

---

## 5. 常见组合用法

```bash
# 1) 看板子是否在线
py -I tools/ssh_cmd.py "uptime"

# 2) 一键检查远程桌面状态（密钥环 / 凭据 / 端口 / 服务）
py -I tools/ssh_cmd.py "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; \
  busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked; \
  grdctl status | grep -E 'Status|Username|Password'; \
  ss -tln | grep 3389; \
  systemctl --user is-active gnome-remote-desktop.service"

# 3) 本地写个脚本，上传并执行
cat > /tmp/check_rdp.sh <<'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
grdctl status
EOF
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py /tmp/check_rdp.sh /tmp/check_rdp.sh run

# 4) 上传并安装到板子上
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py tools/keyring-supervisor.sh /home/tyzc/.local/bin/keyring-supervisor.sh
py -I tools/ssh_cmd.py "chmod 700 ~/.local/bin/keyring-supervisor.sh"

# 5) 重启板子并等待回来
py -I tools/ssh_cmd.py "echo 123456 | sudo -S sh -c 'nohup systemctl reboot >/dev/null 2>&1 &'"
sleep 60
py -I tools/ssh_cmd.py "uptime"
```

---

## 6. 已知限制与安全提醒

- **凭据硬编码**：`ssh_cmd.py` / `ssh_put.py` 中明文写着板子的 IP、用户名、密码，**不要提交到公开仓库**。需要共享时改成从环境变量读取（见下方示例）。
- **不校验主机密钥**：`AutoAddPolicy` 会自动信任任何主机密钥，仅适合可信内网。
- **不传递远程退出码**：脚本总是返回 0，自动化流程中请解析输出判断成败。
- **单命令超时 120 秒**：长时间任务请用 `nohup ... &` 放到后台，或修改脚本里的 `timeout=120`。
- **`cat >` 未转义路径**：远程路径必须可信且无特殊字符。

如需把凭据改为环境变量（推荐）：

```python
import os
HOST = os.environ.get("RK3588_HOST", "10.168.1.115")
USER = os.environ.get("RK3588_USER", "tyzc")
PASS = os.environ.get("RK3588_PASS", "123456")
```
