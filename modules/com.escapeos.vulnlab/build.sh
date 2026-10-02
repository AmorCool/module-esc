#!/usr/bin/env bash
#
# VulnLab 漏洞研究台 dylib 构建脚本
#
#   用法：  ./build.sh
#   产物：  bin/vulnlab.dylib   （arm64 + arm64e 胖二进制）
#
# ⚠️ 只能在 macOS 上运行（需要 xcrun + iPhoneOS SDK）。Windows/Linux 编译不了
#    iOS dylib —— 本机（Windows）此脚本写对但**编译不了**，需拿到 macOS 上跑，
#    或走 CI（见 .github/workflows/build-vulnlab.yml，runner=macos-15）。
#
# ⚠️ 两套「签名」不是一回事，别混淆：
#   · signature.sig（本模块目录内）—— 模块**清单**签名，ed25519，CI 自动生成
#     （package.yml / build-vulnlab.yml 的 Sign 步骤），宿主导入时校验 module.json。
#     **不要手工生成**（本地没有私钥）。
#   · dylib 的**代码签名** —— 由 iOS dyld 库校验。宿主 dlopen 时要求 dylib
#     与主程序**同一张开发证书**（serial 级一致）。ldid/zsign 伪签名会被拒
#     （见 BinaryModuleRunner.swift:276-283、329-333）。
#     真机使用前请用与 EscapeSpace 同 TeamID 的证书对 bin/vulnlab.dylib 重新签名。
#
# 依赖框架：IOKit（IOServiceMatching 枚举）、CoreFoundation（属性桥接）、libSystem
# （csops / bootstrap_look_up / sysctl）。全部为公共 SDK 接口，不使用私有头。
#
set -euo pipefail

cd "$(dirname "$0")"

SRC="src/vulnlab.c"
OUT="bin/vulnlab.dylib"
MIN_IOS="15.0"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "✗ 本脚本只能在 macOS 上运行（当前：$(uname -s)）" >&2
  echo "  iOS dylib 需要 xcrun + iPhoneOS SDK，Windows/Linux 无法编译。" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "✗ 找不到 xcrun（请先安装 Xcode 命令行工具：xcode-select --install）" >&2
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "▸ iPhoneOS SDK: $SDK"

mkdir -p bin

xcrun --sdk iphoneos clang \
  -dynamiclib \
  -arch arm64 -arch arm64e \
  -isysroot "$SDK" \
  -miphoneos-version-min="$MIN_IOS" \
  -fvisibility=hidden \
  -O2 -Wall -Wextra \
  -framework IOKit \
  -framework CoreFoundation \
  -install_name @rpath/vulnlab.dylib \
  -o "$OUT" \
  "$SRC"

echo "✓ 构建完成：$OUT"
lipo -info "$OUT" || true
echo "--- 导出符号（应含 VulnLab* 与 escape_module_init）---"
nm -gU "$OUT" | grep -E 'VulnLab|escape_module_init' || true
