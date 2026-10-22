# Windows 部署 ARM (aarch64) 交叉编译环境

> 目标：在 **Windows 11 主机** 上编译出能在 **RK3588 开发板**（Ubuntu 24.04 aarch64，`10.168.1.115`）上运行的程序。
> 本文件包含：方案选型 → 实际部署步骤 → 使用方法 → 验证 → 备选方案 → 故障排查。
> 相关脚本和示例代码见 `D:\Code\RK3588\examples\hello-aarch64\`。

---

## 0. 方案选型

| 方案 | 原理 | 优点 | 缺点 | 适合场景 |
|------|------|------|------|----------|
| **① Windows 原生交叉工具链**（本文主方案） | Arm 官方 GNU Toolchain 的 Windows (mingw) 构建版，`aarch64-none-linux-gnu-gcc.exe` 直接在 Windows 运行 | 免安装、解压即用、无需管理员权限、编译速度快 | 不能编译 Linux 内核/U-Boot（构建系统强依赖 Linux 环境）；动态链接需注意 glibc 版本（见 §2.4） | 用户态 C/C++ 程序、库 |
| ② WSL2 + `gcc-aarch64-linux-gnu` | Windows 里跑一个真 Ubuntu，再装 Ubuntu 官方交叉编译包 | 功能最全，可编译内核/U-Boot/任意 autotools 项目 | 需启用虚拟化、安装 WSL（要管理员权限，可能重启） | 内核、Bootloader、大型项目 |
| ③ 板子本地编译 | 直接在 RK3588 上 `apt install build-essential` 编译 | 零部署成本、绝不存在目标不匹配 | 占用板子资源，大项目慢 | 小程序、快速验证 |

**结论**：日常写用户态程序用 ①；要动内核/uboot 再装 ②（见 §4）；③ 作为兜底（见 §5）。

---

## 1. 部署（Windows 原生工具链，已在 2026-10-22 实际执行并验证）

### 1.1 部署结果一览

| 项 | 值 |
|----|----|
| 工具链版本 | Arm GNU Toolchain **15.2.Rel1**（GCC 15.2，目标 `aarch64-none-linux-gnu`） |
| 安装位置 | `D:\toolchains\arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu\` |
| 编译器 | `D:\toolchains\...\bin\aarch64-none-linux-gnu-gcc.exe`（含 g++、ld、readelf 等全套 binutils） |
| 自带 sysroot | `...\aarch64-none-linux-gnu\libc\`（aarch64 的 glibc 头文件和库） |
| PATH | 已加入**用户级**环境变量 `Path`（新开的终端生效） |
| 磁盘占用 | 压缩包 339 MB，解压后约 1.1 GB |

> 官方下载页已迁移：15.3.Rel1 起发布在 [Arm GitLab](https://gitlab.arm.com/tooling/gnu-devtools-for-arm/-/releases)，15.2.Rel1 及更早版本仍在 [developer.arm.com](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads)。本文固定使用 15.2.Rel1，保证步骤可复现。

### 1.2 复现步骤（换机器/重装时照抄）

以下命令均在 **Git Bash** 中执行。

```bash
# 1) 建目录并下载（339 MB）
mkdir -p /d/toolchains

#    方式 A：单连接直接下（国际链路慢时可能只有 ~50 KB/s）
curl -L --retry 3 -o /d/toolchains/arm-gnu-toolchain-15.2.rel1.zip \
  "https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu.zip"

#    方式 B（推荐）：分段并行下载，项目自带脚本 tools/download_toolchain.sh
#    （8 段并行，每段独立校验+断点续传，实测从 50KB/s 提到 ~300KB/s）
bash /d/Code/RK3588/tools/download_toolchain.sh \
  "https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu.zip" \
  /d/toolchains/arm-gnu-toolchain-15.2.rel1.zip 8

# 2) 解压（两个坑，都是实测踩过的）：
#    a) Git Bash 的 tar 是 GNU tar，不认 zip（报 "This does not look like a tar archive"），
#       必须显式调用 Windows 11 系统自带的 bsdtar：/c/Windows/System32/tar.exe
#    b) 该 zip 内部【没有顶层目录】，直接解压会把 bin/、lib/ 散到当前目录，
#       必须先建好目标目录再解进去
cd /d/toolchains
mkdir arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu
cd arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu
/c/Windows/System32/tar.exe -xf ../arm-gnu-toolchain-15.2.rel1.zip
cd ..
rm arm-gnu-toolchain-15.2.rel1.zip   # 确认解压无误后再删

# 3) 验证
/d/toolchains/arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-gcc.exe --version
# 实测输出：aarch64-none-linux-gnu-gcc.exe (Arm GNU Toolchain 15.2.Rel1 (Build arm-15.86)) 15.2.1 20251203
```

### 1.3 配置 PATH（用户级，免管理员）

在 **PowerShell** 中执行（检查重复后再追加，安全）：

```powershell
$bin = 'D:\toolchains\arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu\bin'
$p = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($p -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', "$p;$bin", 'User')
    Write-Host "已追加: $bin"
} else {
    Write-Host "PATH 中已存在，无需修改"
}
```

> - 只改**用户级** PATH，不需要管理员权限，重启/重开终端后生效。
> - 不要用 `setx PATH "%PATH%;..."`：它会把系统 PATH 和用户 PATH 合并后截断到 1024 字符，**容易弄坏 PATH**。
> - 当前已打开的终端不会自动刷新，**新开一个 Git Bash** 再验证：
>
>   ```bash
>   aarch64-none-linux-gnu-gcc --version
>   ```

---

## 2. 使用方法

### 2.1 最小编译（命令行直接调 gcc）

示例代码在 `D:\Code\RK3588\examples\hello-aarch64\hello.c`：

```bash
cd /d/Code/RK3588/examples/hello-aarch64

# 动态链接版本
aarch64-none-linux-gnu-gcc -O2 -o hello hello.c

# 确认产物是 aarch64 的 ELF（不是 Windows exe）
aarch64-none-linux-gnu-readelf -h hello | grep -E "Class|Machine"
# 期望：Class: ELF64 / Machine: AArch64
```

### 2.2 上传到板子并运行

板子在线时（SSH 工具见 [tools-scripts.md](tools-scripts.md)）：

```bash
cd /d/Code/RK3588

# 一条命令：上传 → 加执行位 → 运行（exe 模式）
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py examples/hello-aarch64/hello /tmp/hello exe
# 期望输出：Hello from RK3588 cross-compile demo! / Built for: aarch64 (ARM64)

# 或分两步：上传（raw = 不做换行转换）+ 手动加执行位运行
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py examples/hello-aarch64/hello /tmp/hello raw
py -I tools/ssh_cmd.py "chmod +x /tmp/hello && /tmp/hello"
```

或用系统自带 `scp`（Windows 10+ 自带 OpenSSH 客户端）：

```bash
scp examples/hello-aarch64/hello tyzc@10.168.1.115:/tmp/hello
ssh tyzc@10.168.1.115 "/tmp/hello"
```

> **两个实测踩过的坑**
>
> 1. **`./hello: command not found` 多半是传成了目录**。若把目录 `examples/hello-aarch64` 整个拖到板子上，`/tmp/hello-aarch64` 就是目录，可执行文件在**里面**。到文件**所在目录**下执行，或直接写全路径 `/tmp/hello-aarch64/hello`。用 `ls -l /tmp/hello*` 和 `file` 先确认是文件还是目录。
> 2. **`ssh_put.py` 曾会损坏二进制**：旧版对所有文件做 `CRLF → LF` 替换，而 ELF 里也可能有 `0x0d 0x0a` 字节对（本示例 hello 就有 47 处），替换后文件被截掉 47 字节直接损坏。现在脚本以 NUL 字节判定二进制并跳过转换，也支持 `raw` 强制跳过。**上传后建议 `md5sum` 对比一下**。
>
> 另外上传后**没有可执行位**，直接 `./hello` 会报 `Permission denied`，必须 `chmod +x`（`exe` 模式已自动处理）。

### 2.3 用 CMake 构建（中大型项目）

已提供工具链文件 [examples/hello-aarch64/aarch64-none-linux-gnu.cmake](../examples/hello-aarch64/aarch64-none-linux-gnu.cmake)，内容要点：

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   "<工具链>/bin/aarch64-none-linux-gnu-gcc.exe")
set(CMAKE_CXX_COMPILER "<工具链>/bin/aarch64-none-linux-gnu-g++.exe")
set(CMAKE_SYSROOT      "<工具链>/aarch64-none-linux-gnu/libc")
```

使用：

```bash
cd /d/Code/RK3588/examples/hello-aarch64

# Windows 上 CMake 默认找 Visual Studio 生成器；没有 ninja/make 时先装一个：
winget install Ninja-build.Ninja        # 装 ninja（推荐，快）
# 或：winget install GnuWin32.Make     （二选一即可）

cmake -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=aarch64-none-linux-gnu.cmake
cmake --build build
# 产物：build/hello（aarch64 ELF）
```

> 工具链路径不写死也行：`set ARM_TOOLCHAIN_DIR=D:\your\path` 后工具链文件会优先读这个环境变量。

### 2.4 动态链接 vs 静态链接（重要踩坑点）

工具链自带 sysroot 的 glibc 版本**比板子 Ubuntu 24.04 的 glibc 2.39 新**。动态链接的程序拷到板子上可能直接报：

```
/tmp/hello: /lib/aarch64-linux-gnu/libc.so.6: version `GLIBC_2.xx' not found
```

对策（按推荐顺序）：

| 对策 | 做法 | 适用 |
|------|------|------|
| **静态编译** | `aarch64-none-linux-gnu-gcc -O2 -static -o hello hello.c` | 小程序、独立工具，**最省心**（产物不依赖板子库，体积略大） |
| 板子本地编译 | 见 §5 | 依赖一堆系统库的大程序 |
| 换匹配 sysroot | 把板子的 `/lib/aarch64-linux-gnu`、`/usr/lib/aarch64-linux-gnu`、`/usr/include` 拉回 Windows，用 `--sysroot=` 指向它 | 需要长期动态链接开发时 |

判断程序实际依赖哪些库：

```bash
aarch64-none-linux-gnu-readelf -d hello | grep NEEDED
```

### 2.5 带 `CROSS_COMPILE` 的 Makefile 项目

很多嵌入式项目的 Makefile 支持交叉编译前缀变量：

```bash
# Git Bash 中
export CROSS_COMPILE=aarch64-none-linux-gnu-
export ARCH=arm64
make            # Makefile 内部会调用 $(CROSS_COMPILE)gcc
```

> 注意：纯 Windows 上没有 `make` 命令，需要 `winget install GnuWin32.Make` 或改用 WSL2（§4）。

---

## 3. 验证清单（部署后跑一遍）

```bash
# 1) 编译器存在且版本正确
aarch64-none-linux-gnu-gcc --version | head -1

# 2) 能编译出 aarch64 ELF
cd /d/Code/RK3588/examples/hello-aarch64
aarch64-none-linux-gnu-gcc -O2 -static -o hello hello.c
aarch64-none-linux-gnu-readelf -h hello | grep Machine   # Machine: AArch64

# 3) 板子上真的能跑（板子在线时）
cd /d/Code/RK3588
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py examples/hello-aarch64/hello /tmp/hello exe
```

**2026-10-22 实测结果**：三步全部通过。

- ① ARM GNU Toolchain 15.2.Rel1 的 GCC 15.2.1
- ② 产物 `ELF 64-bit LSB executable, ARM aarch64, statically linked`，2.9 MB
- ③ 板子上运行输出 `Hello from RK3588 cross-compile demo!` / `Built for: aarch64 (ARM64)`，退出码 0；上传前后 `md5sum` 一致（`6f7e5a58…`）

---

## 4. 备选方案：WSL2（编译内核/U-Boot 时需要）

> 当前主机**未安装 WSL**。仅当需要编译 Linux 内核、U-Boot 或大型 autotools 项目时才装。

```powershell
# PowerShell（管理员）
wsl --install -d Ubuntu-24.04
# 装完重启一次，首次启动设置用户名密码
```

进入 WSL 后：

```bash
sudo apt update
sudo apt install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
     build-essential bc bison flex libssl-dev libncurses-dev device-tree-compiler u-boot-tools

aarch64-linux-gnu-gcc --version   # Ubuntu 24.04 源里是 GCC 13.x

# 交叉编译内核（典型流程）
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make rk3588_defconfig   # 以实际内核源码树的 defconfig 名为准
make -j$(nproc)
```

WSL 与 Windows 文件互访：WSL 里访问 Windows 盘用 `/mnt/d/Code/RK3588`，Windows 访问 WSL 文件用 `\\wsl$\Ubuntu-24.04\...`。**项目源码放 WSL 原生文件系统（如 `~/src`）里编译速度最快**，放 `/mnt/d` 下 IO 慢很多。

---

## 5. 备选方案：板子本地编译（零部署兜底）

```bash
# 在板子上（SSH 上去执行）
py -I tools/ssh_cmd.py "echo 123456 | sudo -S apt-get update"
py -I tools/ssh_cmd.py "echo 123456 | sudo -S apt-get install -y build-essential"

# 传源码过去直接编
MSYS_NO_PATHCONV=1 py -I tools/ssh_put.py examples/hello-aarch64/hello.c /tmp/hello.c
py -I tools/ssh_cmd.py "gcc -O2 -o /tmp/hello /tmp/hello.c && /tmp/hello"
```

RK3588S 是 8 核（4×A76 + 4×A55），编译中小型项目完全够用。

---

## 6. 故障排查

| 现象 | 原因 | 解决 |
|------|------|------|
| `'aarch64-none-linux-gnu-gcc' 不是内部或外部命令` | PATH 未生效 | 检查是否在**配置 PATH 之前**打开的终端；新开终端再试；用 §1.3 的脚本确认 PATH 已写入 |
| 板子上运行报 `GLIBC_2.xx not found` | 动态链接了过新的 glibc | 改用 `-static` 重新编译，见 §2.4 |
| 板子上运行报 `Permission denied` | 上传后无可执行位 | `chmod +x /tmp/hello`，或用 `ssh_put.py ... exe`（自动加执行位） |
| 板子上 `./hello: command not found` / `Is a directory` | 把整个目录传上去了，路径多了一层 | `ls -l /tmp/hello*; file /tmp/hello*` 确认；进入文件所在目录再 `./hello`，或写全路径 |
| 上传后二进制 MD5 与本地不一致 | 旧版 `ssh_put.py` 把二进制里的 `\r\n` 改成 `\n` | 已修复（NUL 字节判据 + `raw` 模式）；用 `md5sum` 校验，不一致就重传 |
| 板子上运行报 `cannot execute binary file` | 编成了 Windows exe 或 x86 | 用 `readelf -h` 检查 Machine 必须是 AArch64；确认调用的是 `aarch64-none-linux-gnu-gcc` 而不是系统 gcc |
| `tar -xf` 报 `This does not look like a tar archive` | Git Bash 的 tar 是 GNU tar，不认 zip | 用 Windows 系统自带 bsdtar：`/c/Windows/System32/tar.exe -xf xxx.zip`（见 §1.2） |
| 解压后 bin/ lib/ 散在当前目录 | 该 zip 内部没有顶层目录 | 先建目标目录、cd 进去再解压（见 §1.2） |
| 官方下载只有 ~50 KB/s | 国际链路单连接限速 | 用 `tools/download_toolchain.sh` 分段并行下载（注意 curl 的 `-C -` 与 `-r` 不能同用，脚本内已处理） |
| CMake 报 `could not find any instance of Visual Studio` / `CMAKE_MAKE_PROGRAM not found` | 默认生成器找不到构建工具 | 显式 `-G Ninja`（先 `winget install Ninja-build.Ninja`） |
| Git Bash 里 scp 上传路径被改写成 `C:/...` | MSYS 路径转换 | 命令前加 `MSYS_NO_PATHCONV=1`，与 tools 脚本用法一致 |

---

## 7. 卸载 / 回滚

```bash
# 1) 删除工具链目录
rm -rf /d/toolchains/arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu

# 2) 从用户 PATH 移除（PowerShell）
```

```powershell
$bin = 'D:\toolchains\arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu\bin'
$p = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', (($p -split ';' | Where-Object { $_ -ne $bin }) -join ';'), 'User')
```

不影响系统其它部分，无残留。

---

## 8. 参考链接

- Arm GNU Toolchain 下载总页：<https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads>
- 15.3.Rel1 起的新发布位置（Arm GitLab）：<https://gitlab.arm.com/tooling/gnu-devtools-for-arm/-/releases>
- Arm 官方安装指南：<https://learn.arm.com/install-guides/gcc/arm-gnu/>
- 项目内相关文档：[tools-scripts.md](tools-scripts.md)（SSH 上传/远程执行脚本）、[rk3588-headless-remote-desktop.md](rk3588-headless-remote-desktop.md)
