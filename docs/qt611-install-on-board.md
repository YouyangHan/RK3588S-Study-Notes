# RK3588S 安装 Qt 6.11（官方 ARM64 预编译包）

> 目标：在 RK3588S（Ubuntu 24.04 aarch64）上获得可直接使用的 Qt 6.11 开发库，**不源码编译**。
> 原理：Qt 官方从 6.7 起在在线仓库发布了 `linux_arm64`（Ubuntu 24.04 / glibc 2.39）的 GCC 预编译包，与本板系统完全匹配。用 `aqtinstall` 从国内镜像（腾讯云）下载，比源码编译（6+ 小时）快几个数量级。
> 2026-10-25 实测通过。

---

## 1. 结果一览

| 项 | 值 |
|----|----|
| 安装位置 | `/opt/Qt/6.11.0/gcc_arm64` |
| 版本 | Qt 6.11.0（GCC，ARM64） |
| 来源 | Qt 官方在线仓库 linux_arm64 / `linux_gcc_arm64`，腾讯云镜像加速 |
| 体积 | ~1.6 GB |
| 环境配置 | `/etc/profile.d/qt611.sh`（登录自动生效） |
| 验证 | qmake 编译 Widgets 程序 → ARM64 ELF → offscreen 运行正常 |

安装的核心模块（`ls /opt/Qt/6.11.0/gcc_arm64/lib/cmake | grep ^Qt6`）：
Core / Gui / Widgets / Network / Qml / Quick / QuickControls2 / Svg / Sql / Xml /
DBus / OpenGL / PrintSupport / WaylandClient / LinguistTools / Designer 等。

> 这些都是**动态库**（`.so`）。板上运行 Qt 程序时需要能定位到它们——已用 `LD_LIBRARY_PATH` + rpath 双保险。

---

## 2. 安装步骤（复现照抄）

在板子上执行（SSH 上来）：

```bash
# 1) 装 aqtinstall（Ubuntu 24.04 有 PEP 668，必须走 pipx）
sudo apt-get update
sudo apt-get install -y pipx
pipx install aqtinstall

# 2) 用腾讯云镜像安装 Qt 6.11 ARM64 到 /opt/Qt
#    --base 指定国内镜像，避开 download.qt.io 的慢速
~/.local/bin/aqt install-qt linux_arm64 desktop 6.11.0 linux_gcc_arm64 \
    --outputdir /opt/Qt \
    --base https://mirrors.cloud.tencent.com/qt

# 3) 配环境变量（登录自动生效）
cat | sudo tee /etc/profile.d/qt611.sh <<'EOF'
export QTDIR=/opt/Qt/6.11.0/gcc_arm64
export PATH="$QTDIR/bin:$PATH"
export CMAKE_PREFIX_PATH="$QTDIR${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$QTDIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="$QTDIR/plugins"
export QML2_IMPORT_PATH="$QTDIR/qml"
EOF

# 4) 验证
bash -lc 'qmake -v'
# 期望: QMake version 3.1 / Using Qt version 6.11.0 in /opt/Qt/6.11.0/gcc_arm64/lib
```

---

## 3. 使用方式

### 3.1 qmake 项目

```bash
source /etc/profile.d/qt611.sh    # 或重新登录
cd my_qt_project
qmake myproject.pro
make
./myproject
```

### 3.2 CMake 项目

```bash
source /etc/profile.d/qt611.sh
cmake -B build -DCMAKE_PREFIX_PATH=/opt/Qt/6.11.0/gcc_arm64
cmake --build build
./build/myproject
```

### 3.3 在板上跑 Qt 程序（无显示器 / 远程）

板子接了 RDP/Wayland 桌面时直接跑。纯命令行调试用 offscreen 平台：

```bash
QT_QPA_PLATFORM=offscreen ./myproject       # 不弹窗，逻辑照跑
QT_QPA_PLATFORM=vnc ./myproject             # 通过 VNC 看界面
```

在 RDP 会话里跑 GUI 程序，用 `QT_QPA_PLATFORM=xcb`（默认）即可。

---

## 4. 验证记录（2026-10-25 实测）

写了个 Qt Widgets hello world（`QLabel` + `QPushButton`）：

```bash
cd /tmp/qthello
/opt/Qt/6.11.0/gcc_arm64/bin/qmake qt_hello.pro
make
file qt_hello
# → ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked ✓
ldd qt_hello | grep Qt6
# → libQt6Widgets.so.6 / libQt6Gui.so.6 / libQt6Core.so.6 都解析到 /opt/Qt/... ✓
QT_QPA_PLATFORM=offscreen ./qt_hello
# → 启动正常，输出 "This plugin does not support propagateSizeHints()"（offscreen 平台正常提示）
```

---

## 5. 为什么这么选（而非源码编译）

| 维度 | 源码编译（试过，已放弃） | 本方案（官方预编译包） |
|------|------------------------|------------------------|
| 耗时 | 6+ 小时（8 核板子） | **~80 秒**下载解压 |
| 磁盘峰值 | build 目录 33G，曾把 55G 磁盘写满 | 1.6G |
| 内存风险 | 链接期需 swap，否则 OOM | 无 |
| 稳定性 | Qt 6.11 顶层 `-skip` 参数有 bug，会静默编译所有模块（qt3d/webengine 等），极易踩坑 | 官方构建，稳定 |
| 可裁剪/打补丁 | ✅ 可深度定制 | ❌ 固定配置 |

**结论**：除非要裁剪模块、打 RK3588 专属补丁、或用非官方编译选项，否则直接用官方预编译包。

---

## 6. 故障排查

| 现象 | 原因 | 解决 |
|------|------|------|
| `pip install aqtinstall` 报 PEP 668 | Ubuntu 24.04 保护系统 Python | 用 `pipx install aqtinstall` |
| `aqt install-qt` 卡住/极慢 | 默认走 download.qt.io，国际链路慢 | 加 `--base https://mirrors.cloud.tencent.com/qt` |
| 运行 Qt 程序报 `error while loading shared libraries: libQt6Core.so.6` | 找不到 Qt 动态库 | `source /etc/profile.d/qt611.sh`，或编译时加 `-Wl,-rpath,/opt/Qt/6.11.0/gcc_arm64/lib` |
| 运行报 `qt.qpa.plugin: could not load...` | 平台插件缺失/找不到 | 确认 `QT_PLUGIN_PATH` 指向 `/opt/Qt/6.11.0/gcc_arm64/plugins`；无显示器用 `QT_QPA_PLATFORM=offscreen` |
| RDP 里 Qt 程序花屏/闪退 | 平台插件不匹配 | 强制 `QT_QPA_PLATFORM=xcb`；或装 `qtwayland` 并用 `QT_QPA_PLATFORM=wayland` |

---

## 7. 卸载 / 回滚

```bash
sudo rm -rf /opt/Qt/6.11.0
sudo rm -f /etc/profile.d/qt611.sh
pipx uninstall aqtinstall        # 可选
```

不影响系统原有的 Qt 5.15 运行时（`/usr/lib/aarch64-linux-gnu/libQt5*`）。

---

## 8. 参考

- aqtinstall 文档：<https://aqtinstall.readthedocs.io/>
- Qt 官方 ARM64 Linux 支持说明：<https://doc.qt.io/qt-6/supported-platforms.html>
- 腾讯云 Qt 镜像：<https://mirrors.cloud.tencent.com/qt/>
