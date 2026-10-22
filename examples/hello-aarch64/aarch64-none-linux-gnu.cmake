# CMake 交叉编译工具链文件：Windows 主机 → aarch64 Linux (RK3588)
# 用法：
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=aarch64-none-linux-gnu.cmake
#   cmake --build build
#
# 工具链根目录可用环境变量 ARM_TOOLCHAIN_DIR 覆盖默认值。

cmake_minimum_required(VERSION 3.20)

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# 工具链安装根目录（默认与 docs/arm-cross-compile-windows.md 的部署路径一致）
if(DEFINED ENV{ARM_TOOLCHAIN_DIR})
    set(_TC_ROOT "$ENV{ARM_TOOLCHAIN_DIR}")
else()
    set(_TC_ROOT "D:/toolchains/arm-gnu-toolchain-15.2.rel1-mingw-w64-x86_64-aarch64-none-linux-gnu")
endif()

set(_CROSS "${_TC_ROOT}/bin/aarch64-none-linux-gnu-")

set(CMAKE_C_COMPILER   "${_CROSS}gcc.exe")
set(CMAKE_CXX_COMPILER "${_CROSS}g++.exe")

# 目标系统根文件系统（工具链自带的 sysroot，提供 aarch64 的头文件和库）
set(CMAKE_SYSROOT "${_TC_ROOT}/aarch64-none-linux-gnu/libc")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
