# RK3588 开发板 WiFi 固定静态 IP 配置（Ubuntu 24.04 / NetworkManager）

> 适用环境：RK3588 开发板，Ubuntu 24.04 LTS (aarch64)，网络由 NetworkManager + `nmcli` 管理（GNOME 桌面默认方案）。
> 目标：把板子的 WiFi 从 DHCP 自动获取改为**固定静态 IP**，重启后依然生效。
>
> 本文所有命令均可直接复制执行。文中的用户名 `tyzc`、密码 `123456`、IP `10.168.1.115`、网关/DNS `10.168.1.1` 请按实际情况替换。

---

## 0. 最终配置一览

| 项 | 值 |
|----|----|
| 无线网卡 | `wlan0`，MAC `9c:9d:07:2a:50:86` |
| WiFi 连接名 | `hyy 1`（UUID `2e3a4414-1ad4-495d-ba50-f66842602bdf`） |
| 固定 IP | `10.168.1.115/24` |
| 网关 | `10.168.1.1`（路由器） |
| DNS | `10.168.1.1` |
| 配置方式 | `nmcli` 把连接改为 `ipv4.method=manual` |

---

## 1. 为什么用 nmcli 而不是改配置文件

Ubuntu 桌面版的 WiFi 由 NetworkManager 管理，连接配置存在
`/etc/NetworkManager/system-connections/<连接名>.nmconnection` 里。

两种改法：

| 方式 | 结论 |
|------|------|
| `nmcli connection modify` | ✅ 本文采用。让 NetworkManager 自己改并校验，避免手写配置格式错、漏 keyfile 权限（`nmconnection` 必须是 `root:root 600`，否则被忽略） |
| 手改 `.nmconnection` | ⚠️ 可行但要 `chmod 600` / `chown root:root`，且改完要 `nmcli connection reload`，容易漏步骤 |

> 结论：能用 `nmcli` 就用 `nmcli`。

---

## 2. 配置前：确认当前状态

先登录板子：

```bash
ssh tyzc@10.168.1.115
```

### 2.1 看网卡和当前连接

```bash
nmcli device status
```

期望看到类似：

```
DEVICE  TYPE      STATE      CONNECTION
wlan0   wifi      connected  hyy 1
lo      loopback  connected  lo
```

记下 **设备名（`wlan0`）** 和 **连接名（`hyy 1`）**，下面都要用。

### 2.2 记录当前网关和 DNS（改完照抄，避免设错）

```bash
ip route
# 默认路由里的 via 就是网关，这里应该是 10.168.1.1

nmcli connection show "hyy 1" | grep -E "IP4.GATEWAY|IP4.DNS"
```

当前 DHCP 拿到的地址是 `10.168.1.115`，网关和 DNS 都是 `10.168.1.1`。固定 IP 时**网关/DNS 照抄**即可。

### 2.3 记录板子 MAC（做路由器地址预留时用）

```bash
ip -o link show wlan0 | grep -oE 'link/ether [0-9a-f:]+'
```

本板为 `9c:9d:07:2a:50:86`。

---

## 3. 改成静态 IP（核心步骤）

把连接 `hyy 1` 改为手动配置，一条命令设齐地址、网关、DNS：

```bash
sudo nmcli connection modify "hyy 1" \
  ipv4.method manual \
  ipv4.addresses 10.168.1.115/24 \
  ipv4.gateway 10.168.1.1 \
  ipv4.dns 10.168.1.1
```

> 说明：
> - `ipv4.addresses` 里的 `/24` 是子网掩码（等价 `255.255.255.0`），不是 CIDR 可选参数，**不能省略**。
> - 连接名带空格，用引号包住 `"hyy 1"`。
> - 如需多个 DNS，写成 `10.168.1.1 223.5.5.5`（空格分隔），`+ipv4.dns` 是追加。

### 3.1 确认写入成功

```bash
nmcli connection show "hyy 1" | grep -E "ipv4\.(method|addresses|gateway|dns):"
```

期望：

```
ipv4.method:     manual
ipv4.dns:        10.168.1.1
ipv4.addresses:  10.168.1.115/24
ipv4.gateway:    10.168.1.1
```

注意看 `ipv4.method` 必须是 `manual`，此时配置**已经持久化到磁盘**，只是尚未生效（还在用旧的 DHCP 租约）。

---

## 4. 让配置生效

改完不会立即生效，需要**重启这个连接**（网卡短暂断开几秒）。

```bash
# 用连接名
sudo nmcli connection down "hyy 1" && sudo nmcli connection up "hyy 1"

# 或按 UUID（避免连接名空格/中文的引号问题）
sudo nmcli connection down 2e3a4414-1ad4-495d-ba50-f66842602bdf
sudo nmcli connection up   2e3a4414-1ad4-495d-ba50-f66842602bdf
```

> ⚠️ **通过 SSH 远程操作时**：执行 `down` 后 SSH 会立即断开，后续 `up` 可能没执行完连接就没了。
> 两种做法：
> - 用 `nohup ... &` 放到后台，让它脱离当前 SSH 会话继续跑：
>   ```bash
>   sudo sh -c 'nohup sh -c "nmcli connection down 2e3a4414-1ad4-495d-ba50-f66842602bdf; sleep 3; nmcli connection up 2e3a4414-1ad4-495d-ba50-f66842602bdf" >/tmp/wifi-reapply.log 2>&1 &'
>   ```
> - 或干脆 `sudo reboot`，重启后直接按新配置生效（前提是第 3 步已 `modify` 持久化成功）。

### 4.1 等几秒后重新连回，验证

从本机（Windows）重新 ping 或 SSH 到新地址 `10.168.1.115`：

```bash
ping -n 2 10.168.1.115
ssh tyzc@10.168.1.115
```

连上后确认三点：

```bash
# ① 地址是 static 且永久有效（不再是 DHCP 的 valid_lft 倒计时）
ip -4 addr show wlan0
#   期望：inet 10.168.1.115/24 ... scope global noprefixroute
#         valid_lft forever preferred_lft forever

# ② 默认路由走的是 static，网关正确
ip route
#   期望：default via 10.168.1.1 dev wlan0 proto static

# ③ 网关真的通（能上网）
ping -c 2 10.168.1.1
```

三条都过，静态 IP 配置完成。

---

## 5. 验证重启后仍生效

```bash
sudo reboot
```

等板子起来后，用**固定地址** `10.168.1.115` 重新 SSH，再跑一遍 4.1 的三条检查。能连上且 `proto static` 即表示配置持久生效。

---

## 6. 回滚：改回 DHCP 自动获取

如果静态 IP 出问题（比如和别的设备冲突），一条命令改回自动：

```bash
sudo nmcli connection modify "hyy 1" \
  ipv4.method auto \
  ipv4.addresses "" \
  ipv4.gateway "" \
  ipv4.dns ""

# 再重启连接让它生效（见第 4 节）
sudo nmcli connection down "hyy 1" && sudo nmcli connection up "hyy 1"
```

---

## 7. 遗留风险：静态 IP 落在 DHCP 池里的冲突

`10.168.1.115` 很可能仍在路由器（`10.168.1.1`）的 DHCP 自动分配范围内。后果：

- 板子关机时，路由器可能把 `.115` 分给别的设备；
- 板子再开机后，两个设备抢同一个 IP，导致板子网络时通时断、SSH/RDP 连不上。

**根治方法**（推荐，避免"哪天上不了线再排查"）：在路由器后台做 **DHCP 地址预留（Address Reservation / 静态绑定）**，把板子 MAC `9c:9d:07:2a:50:86` 固定绑定到 `10.168.1.115`，同时把 DHCP 池范围避开这个地址（或直接把 `.115` 挪到池外，如 `10.168.1.200`）。

| 方案 | 做法 | 说明 |
|------|------|------|
| MAC 地址预留 | 路由器后台把 MAC 绑 `.115` | 路由器不再把 `.115` 分给别人，最干净 |
| 换到池外地址 | 固定为 `10.168.1.200` 等 | 需确认路由器 DHCP 池不含该段；改法同第 3 节，把地址一换即可 |

> 具体入口因路由器而异（常见叫「DHCP 服务器 → 地址保留 / 静态分配 / IP 与 MAC 绑定」），把 MAC 和 IP 填进去保存即可。

---

## 8. 常见问题排查

| 现象 | 原因 / 处理 |
|------|-------------|
| `nmcli connection up` 报 `Failed to activate` 或卡在 `connecting` | 地址可能和别的设备冲突，或 WiFi 信号/密码问题。先 `nmcli device wifi list` 看信号，`nmcli connection up "hyy 1"` 看详细报错 |
| 改完地址还是旧 DHCP 地址 | 没重启连接（`down`/`up`）或没 `sudo reboot`，配置只是写了还没生效 |
| SSH 执行 `down` 后断了、再也连不上 | 正常现象——down 会断网。等几秒后用新地址重连即可；若 up 没执行成功，直接 `sudo reboot`（第 3 步已持久化，重启即生效） |
| 固定地址能连但上不了外网 | 网关或 DNS 设错。对照 2.2 记下的值；`ping 10.168.1.1` 通不通、`ping 223.5.5.5` 通不通，判断是网关还是 DNS 问题 |
| `ipv4.addresses` 没写 `/24` | 命令会报错或配置不生效，前缀长度不能省 |

---

## 9. 附：常用命令速查

```bash
# 看设备/连接
nmcli device status
nmcli connection show --active

# 看某个连接的 IP 配置
nmcli connection show "hyy 1"

# 改静态（一条命令）
sudo nmcli connection modify "hyy 1" ipv4.method manual \
  ipv4.addresses 10.168.1.115/24 ipv4.gateway 10.168.1.1 ipv4.dns 10.168.1.1

# 生效 / 回滚
sudo nmcli connection down "hyy 1" && sudo nmcli connection up "hyy 1"
sudo nmcli connection modify "hyy 1" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""

# 看 MAC（路由器做地址预留时用）
ip -o link show wlan0 | grep -oE 'link/ether [0-9a-f:]+'
```
