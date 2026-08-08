#!/bin/bash
# =============================================================
# UnU-Player 定制补丁: 启用 Vulkan(HDR) + ffmpeg TLS 后端 mbedtls→OpenSSL + AAudio 音频后端
#
# 全部幂等(已应用则跳过), 目标行漂移时 warn 而非静默失败。
#
# ★ 为什么不需要改 mpv.sh?
#   mpv 的 vulkan / aaudio 选项默认值都是 auto:
#   - vulkan: libplacebo 编了 vulkan(补丁 1)则 pkg-config pl_has_vulkan=1,
#     mpv auto 检测到即启用(NDK sysroot 自带 vulkan/vulkan_core.h)。
#   - aaudio: 目标系统 android + NDK sysroot 自带 aaudio/AAudio.h, auto 即启用。
#   实证: 用户本地 v1.0.0 构建的 mpv.sh 从未被改过(无 -Dvulkan/-Daaudio),
#   而 AAR 带 Vulkan(HDR 真机验证)。本脚本刻意不动 mpv.sh, 避免任何续行/转义问题。
#   缺失兜底: CI 的 Verify Vulkan / Verify AAudio 步骤会硬失败, 不会静默出货。
#
# 用法: 在 fork 仓库根目录执行 ./scripts/apply-custom-patches.sh
# =============================================================

set -euo pipefail

REPO="$PWD"
BS="$REPO/buildscripts"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*"; }
die()   { err "$*"; exit 1; }

# 补丁 1: libplacebo vulkan=enabled(让 mpv 的 vulkan=auto 检测到 pl_has_vulkan=1)
if grep -q '\-Dvulkan=disabled' "$BS/scripts/libplacebo.sh"; then
    sed -i 's/-Dvulkan=disabled/-Dvulkan=enabled/' "$BS/scripts/libplacebo.sh"
    ok "[1/9] libplacebo.sh: vulkan=disabled → enabled"
elif grep -q '\-Dvulkan=enabled' "$BS/scripts/libplacebo.sh"; then
    ok "[1/9] libplacebo.sh: vulkan=enabled (已应用)"
else
    warn "[1/9] libplacebo.sh: 未找到 vulkan 配置行"
fi

# 补丁 2: depinfo shaderc(libplacebo vulkan 依赖 shaderc)
if grep -q '^dep_libplacebo=(shaderc)' "$BS/include/depinfo.sh"; then
    ok "[2/9] depinfo.sh: dep_libplacebo=(shaderc) (已应用)"
else
    sed -i 's/^dep_libplacebo=()/dep_libplacebo=(shaderc)/' "$BS/include/depinfo.sh"
    ok "[2/9] depinfo.sh: dep_libplacebo=(shaderc)"
fi

# 补丁 3: abiFilters arm64 only
if grep -q 'abiFilters' "$REPO/libmpv/build.gradle.kts"; then
    ok "[3/9] build.gradle.kts: abiFilters arm64 (已应用)"
else
    sed -i '/consumerProguardFiles/a\        ndk {\n            abiFilters += "arm64-v8a"\n        }' \
        "$REPO/libmpv/build.gradle.kts"
    ok "[3/9] build.gradle.kts: + abiFilters arm64-v8a"
fi

# 补丁 4: depinfo mbedtls→openssl(版本/依赖/ffmpeg 后端)
if grep -q '^v_openssl=' "$BS/include/depinfo.sh"; then
    ok "[4/9] depinfo.sh: v_openssl 已存在"
else
    sed -i 's/^v_mbedtls=.*/v_openssl=3.5.0/' "$BS/include/depinfo.sh"
    sed -i 's/^dep_mbedtls=()/dep_openssl=()/' "$BS/include/depinfo.sh"
    sed -i 's/^dep_ffmpeg=(mbedtls /dep_ffmpeg=(openssl /' "$BS/include/depinfo.sh"
    ok "[4/9] depinfo.sh: mbedtls→openssl"
fi

# 补丁 5: download-deps mbedtls clone→openssl clone(整行替换, 官方仓库, deps/openssl)
if grep -q 'Mbed-TLS/mbedtls.git' "$BS/include/download-deps.sh"; then
    sed -i '/Mbed-TLS\/mbedtls.git/c\[ ! -d openssl ] && git clone --depth 1 --branch openssl-$v_openssl https://github.com/openssl/openssl.git openssl' \
        "$BS/include/download-deps.sh"
    ok "[5/9] download-deps.sh: mbedtls clone→openssl clone(官方仓库, deps/openssl)"
elif grep -q 'openssl/openssl.git' "$BS/include/download-deps.sh"; then
    ok "[5/9] download-deps.sh: openssl clone 已存在"
else
    warn "[5/9] download-deps.sh: 未找到 mbedtls clone 行"
fi

# 补丁 6: download-deps 的 code.videolan.org → GitHub 镜像
# (GitHub Actions runner 连 code.videolan.org 会超时; dav1d 用官方镜像, libplacebo 用作者
#  haasn 镜像且其 submodule 全部在 GitHub, --recurse-submodules 可达)
if grep -q 'code.videolan.org' "$BS/include/download-deps.sh"; then
    sed -i 's|https://code.videolan.org/videolan/dav1d.git|https://github.com/videolan/dav1d.git|' \
        "$BS/include/download-deps.sh"
    sed -i 's|https://code.videolan.org/videolan/libplacebo.git|https://github.com/haasn/libplacebo.git|' \
        "$BS/include/download-deps.sh"
    ok "[6/9] download-deps.sh: videolan.org → GitHub 镜像(dav1d/libplacebo)"
elif grep -q 'github.com/haasn/libplacebo' "$BS/include/download-deps.sh"; then
    ok "[6/9] download-deps.sh: GitHub 镜像已应用"
else
    warn "[6/9] download-deps.sh: 未找到 code.videolan.org 行"
fi

# 补丁 7: ffmpeg mbedtls→openssl
if grep -q 'mbedtls' "$BS/scripts/ffmpeg.sh"; then
    sed -i 's/mbedtls/openssl/g' "$BS/scripts/ffmpeg.sh"
    ok "[7/9] ffmpeg.sh: mbedtls→openssl"
elif grep -q 'openssl' "$BS/scripts/ffmpeg.sh"; then
    ok "[7/9] ffmpeg.sh: openssl (已应用)"
else
    warn "[7/9] ffmpeg.sh: 未找到 mbedtls/openssl 配置行"
fi

# 补丁 8: 新建 openssl.sh(不存在才建)
if [[ -f "$BS/scripts/openssl.sh" ]]; then
    ok "[8/9] openssl.sh: 已存在"
else
    cat > "$BS/scripts/openssl.sh" << 'OPENSSL_EOF'
#!/bin/bash -e

. ../../include/depinfo.sh
. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	make clean 2>/dev/null || true
	exit 0
else
	exit 255
fi

# OpenSSL 自带 android target, 按 ndk_triple 选
case "$ndk_triple" in
	aarch64-linux-android) osl_target=android-arm64 ;;
	arm-linux-androideabi) osl_target=android-arm ;;
	x86_64-linux-android)  osl_target=android-x86_64 ;;
	i686-linux-android)    osl_target=android-x86 ;;
	*) echo "openssl: 未知 arch $ndk_triple"; exit 1 ;;
esac

# OpenSSL 的 android 配置靠 ANDROID_NDK_ROOT 定位工具链/sysroot
export ANDROID_NDK_ROOT="$DIR/sdk/android-sdk-$os/ndk/$v_ndk"
export ANDROID_API=26

./Configure "$osl_target" \
	-D__ANDROID_API__=26 \
	--prefix="$prefix_dir" \
	no-shared no-tests no-makedepend no-ssl3 no-comp

# 注意: Configure 不接 -j(make 会把它当编译选项传给 clang → "unknown argument: -j4")。
# 并行交给下方 make 的 -j"$cores"。
make -j"$cores" 2>/dev/null || make
make install_sw
OPENSSL_EOF
    chmod +x "$BS/scripts/openssl.sh"
    ok "[8/9] openssl.sh: 新建"
fi

# 补丁 9: 删除 mbedtls.sh(存在才删)
if [[ -f "$BS/scripts/mbedtls.sh" ]]; then
    rm "$BS/scripts/mbedtls.sh"
    ok "[9/9] mbedtls.sh: 已删除"
else
    ok "[9/9] mbedtls.sh: 已无此文件"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} 全部补丁就绪, 可执行 ./buildscripts/build.sh --arch arm64${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
