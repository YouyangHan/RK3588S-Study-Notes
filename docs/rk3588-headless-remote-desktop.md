# RK3588 无显示器远程桌面完整配置（Ubuntu 24.04 / GNOME 46 Wayland / RDP）

> 适用环境：RK3588 开发板，Ubuntu 24.04 LTS (aarch64)，GNOME 46 + Wayland + GDM3，**已开启 GDM 自动登录**。
> 目标：板子不接显示器，Windows 用系统自带「远程桌面连接 (mstsc)」直接进入已有的 GNOME 桌面，**重启后依然可用，无需任何人工操作**。
>
> 本文所有命令均可直接复制执行。文中的用户名 `tyzc`、密码 `123456`、IP `10.168.1.117` 请按实际情况替换。

---

## 1. 方案原理（先看，后面少踩坑）

### 1.1 为什么用用户会话级 RDP

| 方案 | 结论 |
|------|------|
| **gnome-remote-desktop 用户会话级 RDP** | ✅ 本文采用。GNOME 46 自带，共享 tty2 上自动登录的那个桌面 |
| 系统级 RDP（`grdctl --system`，Remote Login） | ❌ 本板实测黑屏：远程 greeter 的 gnome-shell 起不来（`org.freedesktop.systemd1` 激活失败） |
| VNC（x11vnc / tigervnc） | ❌ 只支持 X11，Wayland 下不可用 |
| wayvnc | ❌ 只支持 wlroots，不支持 GNOME/mutter |
| xrdp | ❌ 需要 Xorg 会话，且不共享本地桌面 |
| Sunlogin / ToDesk / NoMachine | 备选，需装第三方闭源软件 |

### 1.2 真正的难点：自动登录让密钥环处于锁定状态

gnome-remote-desktop 的用户级 RDP **把账号密码存在 GNOME Keyring 里**（schema `org.gnome.RemoteDesktop.RdpCredentials`）。
而 GDM 自动登录走的是 `pam/gdm-autologin`，**没有密码可以喂给 pam_gnome_keyring**，于是开机后登录密钥环处于锁定状态：

- 在桌面里手动输入一次密码 → 密钥环解锁 → RDP 正常
- 重启后 → 又是锁定 → `grdctl status` 显示 `Username: (empty)` → **RDP 认证失败**

### 1.3 还有一个前提：必须存在至少一块"显示器"

拔掉物理显示器后，GNOME 会话里**没有任何逻辑显示器**，此时：

- 系统日志会刷 `gdk_monitor_get_scale_factor: assertion 'GDK_IS_MONITOR (monitor)' failed`
- gnome-remote-desktop 没有画面可采集
- 现象：Windows 上 **RDP 窗口闪一下就自动关闭**（连接建立后立即断开）

所以必须让 mutter/gnome-shell 在无物理屏时创建一块**虚拟显示器**：

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --virtual-monitor 1920x1080
```

写进 `~/.config/systemd/user/org.gnome.Shell@wayland.service.d/virtual-monitor.conf`。
日志出现 `Added virtual monitor Meta-0` 即表示生效。分辨率可改成任意值（如 `2560x1440`）。

> 注意：如果一直插着显示器使用，这一节可以跳过；但只要有可能拔掉显示器，就**必须**加。

### 1.4 本方案怎么解决

1. 保留系统原版 `gnome-keyring-daemon.service`（不动它，避免卡住 GDM 启动）
2. 新增一个用户级服务 `keyring-unlocked.service`，在 `graphical-session.target` 之后再接管：
   - 干掉系统自动激活的锁定版守护进程
   - 用 `gnome-keyring-daemon --login` 从文件读入密码，启动一个**已解锁**的守护进程
   - 轮询密钥环 `Locked` 属性，确认解锁成功后**重启 gnome-remote-desktop**，让它重新连上有效的 secrets 服务
3. 之后 RDP 就能读到凭据，重启也不例外

> 关键坑：`gnome-keyring-daemon --unlock` / `--login` 作为**客户端**进程去解锁一个正在运行的守护进程是**无效的**（实测连正确密码都解不开）。只有守护进程**自身以 `--login` 启动**才能解锁。
> 另一个关键坑：如果把 `--login` 直接写进 `gnome-keyring-daemon.service` 的 ExecStart，开机时 PAM 阶段就会 socket 激活它，**导致 GDM 卡住、桌面根本起不来**。所以必须"晚一步"接管。

---

## 2. 前置检查

```bash
ssh tyzc@10.168.1.117

# 1) 系统信息
cat /etc/os-release | head -2          # Ubuntu 24.04
gnome-shell --version                  # GNOME Shell 46

# 2) 已安装 gnome-remote-desktop（Ubuntu 桌面版自带）
dpkg -l gnome-remote-desktop | tail -1

# 3) GDM 自动登录已开启
grep -E 'AutomaticLogin' /etc/gdm3/custom.conf
# 期望：AutomaticLoginEnable = true / AutomaticLogin = tyzc

# 4) 确认命令名（Ubuntu 是 grdctl，不是 grd-ctl）
command -v grdctl
```

---

## 3. 一键部署脚本（推荐）

用 `tyzc` 通过 SSH 登录板子（**不要用 sudo/root**），把下面内容保存为 `setup-headless-rdp.sh`，按需改开头三个变量，然后 `bash setup-headless-rdp.sh`。

> **首次部署提示**：脚本会用 `KEYRING_PASSWORD` 解锁已有的登录密钥环；如果板子上已有一个**密码不同**的登录密钥环，解锁会一直失败（脚本会报错退出）。处理办法二选一：
> 1. 把 `KEYRING_PASSWORD` 改成那个密钥环的真实密码；
> 2. 备份后删掉旧密钥环，让脚本重新创建一个：
>    ```bash
>    mkdir -p ~/keyrings-backup
>    mv ~/.local/share/keyrings/login.keyring ~/keyrings-backup/ 2>/dev/null
>    ```
>    （删除会丢失密钥环里已保存的其他密码，请先备份。）

```bash
#!/bin/bash
set -euo pipefail

# ===== 按实际情况修改这三行 =====
RDP_USER="tyzc"            # 系统登录用户名
RDP_PASSWORD="123456"      # 远程桌面密码（可自定义）
KEYRING_PASSWORD="123456"  # 登录密钥环密码，建议与系统登录密码一致
# ================================

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

CERT_DIR="$HOME/.local/share/gnome-remote-desktop/certificates"

echo "==> 1/9 清理旧的错误配置（可重复执行）"
rm -rf  "$HOME/.config/systemd/user/gnome-keyring-daemon.service.d"
rm -f   "$HOME/.config/systemd/user/keyring-late-unlock.service"
rm -f   "$HOME/.config/systemd/user/graphical-session.target.wants/keyring-late-unlock.service"
rm -f   "$HOME/.config/autostart/unlock-keyring.desktop"
rm -f   "$HOME/.local/bin/unlock-keyring.sh"

echo "==> 2/9 安装虚拟显示器（无物理显示器必需）"
mkdir -p "$HOME/.config/systemd/user/org.gnome.Shell@wayland.service.d"
cat > "$HOME/.config/systemd/user/org.gnome.Shell@wayland.service.d/virtual-monitor.conf" <<'SHELLDROPIN'
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --virtual-monitor 1920x1080
SHELLDROPIN
systemctl --user daemon-reload

echo "==> 3/9 生成 RDP TLS 自签名证书"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/rdp-tls.crt" ]; then
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj /CN=rk3588 \
    -keyout "$CERT_DIR/rdp-tls.key" -out "$CERT_DIR/rdp-tls.crt"
fi
chmod 600 "$CERT_DIR/rdp-tls.key"

echo "==> 4/9 保存密钥环密码（仅本人可读）"
printf 'KEYRING_PASSWORD=%s\n' "$KEYRING_PASSWORD" > "$HOME/.config/keyring.env"
chmod 600 "$HOME/.config/keyring.env"

echo "==> 5/9 安装密钥环守护脚本"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/keyring-supervisor.sh" <<'SUPERVISOR'
#!/bin/bash
# 启动一个以 --login 方式运行（登录密钥环已解锁）的 gnome-keyring 守护进程，
# 并保证它一直存活、且真正提供 org.freedesktop.secrets 服务。
systemctl --user stop --no-block gnome-keyring-daemon.service gnome-keyring-daemon.socket
sleep 1

COLLECTION=/org/freedesktop/secrets/collection/login

while true; do
    killall -q gnome-keyring-daemon 2>/dev/null
    sleep 1

    printf '%s\n' "$KEYRING_PASSWORD" | \
        /usr/bin/gnome-keyring-daemon --foreground --login \
            --components=pkcs11,secrets \
            --control-directory="$XDG_RUNTIME_DIR/keyring" &
    pid=$!

    ok=0
    for i in $(seq 1 10); do
        sleep 1
        kill -0 "$pid" 2>/dev/null || break
        locked=$(busctl --user get-property org.freedesktop.secrets "$COLLECTION" \
                     org.freedesktop.Secret.Collection Locked 2>/dev/null || true)
        if [ "$locked" = "b false" ]; then
            ok=1
            break
        fi
    done

    if [ "$ok" = "1" ]; then
        # 密钥环已解锁 -> 重启 RDP 服务，让它重新连接 secrets 服务
        systemctl --user restart gnome-remote-desktop.service || true
        wait "$pid"
    else
        kill "$pid" 2>/dev/null || true
    fi
    sleep 1
done
SUPERVISOR
chmod 700 "$HOME/.local/bin/keyring-supervisor.sh"

echo "==> 6/9 安装 systemd 用户服务"
cat > "$HOME/.config/systemd/user/keyring-unlocked.service" <<'UNIT'
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
UNIT

# RDP 服务必须等密钥环解锁后再启动/重启
mkdir -p "$HOME/.config/systemd/user/gnome-remote-desktop.service.d"
cat > "$HOME/.config/systemd/user/gnome-remote-desktop.service.d/after-unlock.conf" <<'DROPIN'
[Unit]
Wants=keyring-unlocked.service
After=keyring-unlocked.service
DROPIN

systemctl --user daemon-reload

echo "==> 7/9 配置用户会话级 RDP"
grdctl rdp set-tls-cert "$CERT_DIR/rdp-tls.crt"
grdctl rdp set-tls-key  "$CERT_DIR/rdp-tls.key"
grdctl rdp disable-view-only
grdctl rdp enable
systemctl --user enable gnome-remote-desktop.service

echo "==> 8/9 启动解锁服务并等待密钥环就绪"
systemctl --user enable keyring-unlocked.service
systemctl --user restart keyring-unlocked.service

for i in $(seq 1 30); do
  locked=$(busctl --user get-property org.freedesktop.secrets \
               /org/freedesktop/secrets/collection/login \
               org.freedesktop.Secret.Collection Locked 2>/dev/null || true)
  [ "$locked" = "b false" ] && break
  sleep 1
done
if [ "${locked:-}" != "b false" ]; then
  echo "!! 密钥环仍未解锁，请检查：systemctl --user status keyring-unlocked.service" >&2
  exit 1
fi

# 密钥环解锁后再写入 RDP 凭据（否则会弹密码框/写入失败）
grdctl rdp set-credentials "$RDP_USER" "$RDP_PASSWORD"
systemctl --user restart gnome-remote-desktop.service

echo "==> 9/9 关闭锁屏和休眠（无显示器时防止断连）"
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing

# 可选：关闭系统级 RDP，避免与用户级抢 3389
# sudo grdctl --system rdp disable && sudo systemctl restart gnome-remote-desktop.service

echo
echo "================ 部署完成 ================"
grdctl status | grep -E 'Status|Port|View-only|Username|Password'
ss -tln | grep 3389 || echo "警告：3389 未监听"
echo
echo "提示：虚拟显示器 drop-in 需要重启板子后生效 -> sudo reboot"
```

---

## 4. 分步说明（用于核对 / 手工执行）

### 4.1 生成 TLS 证书

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus

CERT_DIR="$HOME/.local/share/gnome-remote-desktop/certificates"
mkdir -p "$CERT_DIR"
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj /CN=rk3588 \
  -keyout "$CERT_DIR/rdp-tls.key" -out "$CERT_DIR/rdp-tls.crt"
chmod 600 "$CERT_DIR/rdp-tls.key"
```

### 4.2 安装虚拟显示器（无物理显示器必需）

```bash
mkdir -p ~/.config/systemd/user/org.gnome.Shell@wayland.service.d
cat > ~/.config/systemd/user/org.gnome.Shell@wayland.service.d/virtual-monitor.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --virtual-monitor 1920x1080
EOF
systemctl --user daemon-reload
```

- 分辨率按需修改（如 `2560x1440`）
- **需要重启 GDM 或重启板子后才生效**
- 验证：日志里出现 `Added virtual monitor Meta-0`
  ```bash
  sudo journalctl _UID=$(id -u) -b --no-pager | grep -F 'Added virtual monitor'
  ```

### 4.3 启用用户级 RDP

```bash
grdctl rdp set-tls-cert "$HOME/.local/share/gnome-remote-desktop/certificates/rdp-tls.crt"
grdctl rdp set-tls-key  "$HOME/.local/share/gnome-remote-desktop/certificates/rdp-tls.key"
grdctl rdp disable-view-only      # 允许键鼠控制
grdctl rdp enable
systemctl --user enable gnome-remote-desktop.service
```

此时 `grdctl status` 应该是 `Status: enabled`，但 `Username/Password` 可能还是 `(empty)`——因为密钥环锁着，下一步解决。

### 4.4 安装解锁服务

按第 3 节脚本的第 4~6 步创建：

| 文件 | 作用 |
|------|------|
| `~/.config/keyring.env` | 保存密钥环密码（权限 600） |
| `~/.local/bin/keyring-supervisor.sh` | 监管进程：以 `--login` 启动守护进程、轮询解锁状态、成功后重启 RDP |
| `~/.config/systemd/user/keyring-unlocked.service` | 用户级服务，`WantedBy=graphical-session.target` |
| `~/.config/systemd/user/gnome-remote-desktop.service.d/after-unlock.conf` | 让 RDP 服务排在解锁服务之后 |

```bash
systemctl --user daemon-reload
systemctl --user enable --now keyring-unlocked.service
```

### 4.5 写入 RDP 凭据

**必须等密钥环解锁成功后再执行**（脚本已自动轮询等待）：

```bash
# 确认已解锁，输出应为 b false
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/login \
  org.freedesktop.Secret.Collection Locked

grdctl rdp set-credentials tyzc 123456
systemctl --user restart gnome-remote-desktop.service
```

### 4.6 关闭锁屏/休眠

```bash
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing
```

---

## 5. 验证

### 5.1 板子上

```bash
# 1) 密钥环已解锁
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/login \
  org.freedesktop.Secret.Collection Locked
# 期望：b false

# 2) 凭据可读（不能是 (empty)）
grdctl status
# 期望：Status: enabled / Username: (hidden) / Password: (hidden)

# 3) 端口监听
ss -tln | grep 3389
# 期望：LISTEN 0 0 *:3389 *:*

# 4) 服务状态
systemctl --user is-active keyring-unlocked.service gnome-remote-desktop.service
# 期望：active / active

# 5) 守护进程存在
ps -eo pid,args | grep 'keyring-daemon --foreground' | grep -v grep

# 6) 虚拟显示器已创建（无物理显示器时必需）
ps -eo args | grep '[g]nome-shell'
# 期望包含：--virtual-monitor 1920x1080

sudo journalctl _UID=$(id -u) -b --no-pager | grep -F 'Added virtual monitor'
# 期望：gnome-shell[...]: Added virtual monitor Meta-0
```

### 5.2 Windows 上

```powershell
# 端口连通性
Test-NetConnection 10.168.1.117 -Port 3389
# 期望：TcpTestSucceeded : True
```

### 5.3 重启验证（最重要）

```bash
sudo reboot
```

等待约 40~60 秒后，直接在 Windows 上连（不需要 SSH，也不需要任何解锁操作）：

```bash
# 板子重启后可用 SSH 复查
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/collection/login \
  org.freedesktop.Secret.Collection Locked    # 应为 b false
grdctl status | grep -E 'Username|Password'  # 应为 (hidden)
ss -tln | grep 3389                           # 应在监听
```

---

## 6. 从 Windows 连接

```bat
:: 保存凭据（只需一次），之后连接不再询问密码
cmdkey /generic:TERMSRV/10.168.1.117 /user:tyzc /pass:123456

:: 发起连接
mstsc /v:10.168.1.117
```

- 首次连接会弹出**证书警告**（自签名证书），勾选「不再询问」并点「是」。
- 连上后看到的**就是板子上那个自动登录的桌面**，键鼠可操作、可继续用正在运行的程序。
- 想调分辨率：`mstsc` → 显示 → 调整；GNOME 会跟随客户端窗口大小。

---

## 7. 故障排查

| 现象 | 原因 | 处理 |
|------|------|------|
| `grdctl: command not found` | Ubuntu 下命令叫 `grdctl`，不是上游的 `grd-ctl` | 用 `grdctl` |
| `grdctl status` 里 `Username/Password` 是 `(empty)` | 密钥环锁定，RDP 读不到凭据 | 确认 `keyring-unlocked.service` 在跑；看 `Locked` 是否为 `b false` |
| 登录时报 `Cannot create an item in a locked collection` | 同上，写凭据时密钥环锁着 | 等解锁成功后再 `set-credentials`（本文脚本已处理） |
| 日志出现 `Couldn't retrieve RDP credentials: The name :1.87 was not provided by any .service files` | RDP 守护进程缓存了旧的 secrets 连接 | 本文的 supervisor 会在解锁后自动重启 RDP；也可手动 `systemctl --user restart gnome-remote-desktop.service` |
| **开机后桌面根本没起来**（只有 SSH，无 gnome-shell） | 把 `--login` 写进了 `gnome-keyring-daemon.service` 的 ExecStart，PAM 阶段卡住 GDM | 删除 `~/.config/systemd/user/gnome-keyring-daemon.service.d/` 后 `systemctl --user daemon-reload`，再重启 GDM：`sudo systemctl restart gdm3` |
| 用系统级 RDP（`grdctl --system`）连上是黑屏 | 远程 greeter 的 gnome-shell 无法启动（`org.freedesktop.systemd1` 激活失败） | 本板不可用，改用本文用户级方案；并关闭系统级 RDP 释放 3389 |
| 端口 3389 没监听 | RDP 服务没起来 | `systemctl --user status gnome-remote-desktop.service`；`grdctl rdp enable` |
| 重启后连不上，但 SSH 正常 | 多半还是密钥环 | 按第 5.3 节命令逐项检查 |
| **RDP 窗口闪一下就自动关闭**（连上即断开） | 会话里没有显示器：拔掉了物理屏且未配置虚拟显示器，RDP 无画面可采集 | 按 4.2 节安装 `--virtual-monitor` drop-in，重启 GDM/板子；确认日志有 `Added virtual monitor` |
| 日志刷 `gdk_monitor_get_scale_factor: assertion 'GDK_IS_MONITOR (monitor)' failed` | 同上，会话无逻辑显示器 | 同上 |
| 插着显示器时正常，拔掉后闪退 | 同上 | 同上 |
| 分辨率只有 1024×768 | 无物理显示器时 GNOME 用虚拟显示器兜底 | 在 mstsc 里调整显示大小；或在 GNOME 设置里设置缩放 |

### 常用排查命令

```bash
# 用户服务日志（需要 sudo 才能看到用户会话日志）
sudo journalctl _UID=$(id -u) -b --no-pager | grep -iE 'keyring|remote-desktop|secrets' | tail -40

# 当前是谁在提供 secrets 服务
busctl --user status org.freedesktop.secrets

# 所有键环相关进程
ps -eo pid,args | grep keyring-daemon | grep -v grep

# 键环文件与备份
ls -la ~/.local/share/keyrings/
ls -la ~/keyrings-backup/ 2>/dev/null
```

---

## 8. 卸载 / 回滚

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus

systemctl --user disable --now keyring-unlocked.service
rm -f ~/.config/systemd/user/keyring-unlocked.service
rm -rf ~/.config/systemd/user/gnome-remote-desktop.service.d
rm -rf ~/.config/systemd/user/org.gnome.Shell@wayland.service.d
rm -f ~/.local/bin/keyring-supervisor.sh
rm -f ~/.config/keyring.env
systemctl --user daemon-reload

grdctl rdp disable
systemctl --user disable --now gnome-remote-desktop.service
```

密钥环若被改乱，可从 `~/keyrings-backup/` 恢复对应文件到 `~/.local/share/keyrings/`。

---

## 9. 安全说明

- `~/.config/keyring.env` 里是**明文密钥环密码**，权限 600（仅本人可读）。这是自动登录场景下解锁密钥环的代价；开发板内网使用可接受，公网/生产环境请勿照搬。
- RDP 走的是 TLS 加密（自签名证书），但**不要把这个 3389 直接暴露到公网**；需要外网访问请走 SSH 隧道或 VPN：
  ```bash
  ssh -L 3389:127.0.0.1:3389 tyzc@10.168.1.117
  # 然后 mstsc /v:127.0.0.1
  ```
- 修改系统登录密码**不会**自动改变密钥环密码。如果你改了系统密码，请同步修改 `~/.config/keyring.env` 中的 `KEYRING_PASSWORD`（密钥环密码本身不变，除非你在桌面里手动改过密钥环）。
- 建议把 RDP 密码改成非弱口令，并定期更换。

---

## 10. 本次实际配置记录（2026-10-20，已验证重启）

- 板子：RK3588，Ubuntu 24.04.3 LTS aarch64，GNOME Shell 46.0，Wayland，GDM3 自动登录
- RDP：用户会话级，端口 3389，账号 `tyzc / 123456`，证书指纹：
  `da:6f:99:74:6d:6b:80:ce:3c:93:5b:fb:5b:1d:ec:ac:92:eb:08:fc:79:a9:3d:a5:6f:84:8d:ae:37:ec:be:5b`
- 关键服务：`keyring-unlocked.service`（用户级，`graphical-session.target`）、
  `gnome-remote-desktop.service`（用户级，`gnome-session.target`）
- 系统级 RDP：已禁用（`grdctl --system rdp disable`），避免与用户级抢 3389
- 虚拟显示器：`org.gnome.Shell@wayland.service` 用户级 drop-in，`--virtual-monitor 1920x1080`
  （2026-10-20 追加：拔掉物理显示器后 RDP 闪退，由此修复；日志 `Added virtual monitor Meta-0`）
- 已验证：断开物理显示器 + 断电重启后，无需任何操作，Windows `mstsc` 直接进入桌面
