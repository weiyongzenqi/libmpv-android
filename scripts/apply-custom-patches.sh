#!/bin/bash
# =============================================================
# UnU-Player 定制补丁: 启用 Vulkan(HDR) + ffmpeg TLS 后端 mbedtls→OpenSSL + AAudio 音频后端
#
# 与主仓 build-libmpv.sh 的 9 处差异一一对应(1-9), 补丁 10 为 CI 新增的 aaudio 支持。
# 全部幂等(已应用则跳过), 目标行漂移时 warn 而非静默失败。
#
# aaudio 说明: mpv 的 aaudio 后端运行时 dlopen("libaaudio.so") 加载 Android 系统库,
#   编译期只需 aaudio/AAudio.h 头文件(NDK r29 sysroot 自带), 无需交叉编译 oboe。
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

# 补丁 1: libplacebo vulkan=enabled
if grep -q '\-Dvulkan=disabled' "$BS/scripts/libplacebo.sh"; then
    sed -i 's/-Dvulkan=disabled/-Dvulkan=enabled/' "$BS/scripts/libplacebo.sh"
    ok "[1/10] libplacebo.sh: vulkan=disabled → enabled"
elif grep -q '\-Dvulkan=enabled' "$BS/scripts/libplacebo.sh"; then
    ok "[1/10] libplacebo.sh: vulkan=enabled (已应用)"
else
    warn "[1/10] libplacebo.sh: 未找到 vulkan 配置行"
fi

# 补丁 2: mpv vulkan=enabled
if grep -q '\-Dvulkan=enabled' "$BS/scripts/mpv.sh"; then
    ok "[2/10] mpv.sh: vulkan=enabled (已应用)"
else
    sed -i '/-Dmanpage-build=disabled/a\\\t-Dvulkan=enabled' "$BS/scripts/mpv.sh"
    ok "[2/10] mpv.sh: + vulkan=enabled"
fi

# 补丁 3: depinfo shaderc
if grep -q '^dep_libplacebo=(shaderc)' "$BS/include/depinfo.sh"; then
    ok "[3/10] depinfo.sh: dep_libplacebo=(shaderc) (已应用)"
else
    sed -i 's/^dep_libplacebo=()/dep_libplacebo=(shaderc)/' "$BS/include/depinfo.sh"
    ok "[3/10] depinfo.sh: dep_libplacebo=(shaderc)"
fi

# 补丁 4: abiFilters arm64 only
if grep -q 'abiFilters' "$REPO/libmpv/build.gradle.kts"; then
    ok "[4/10] build.gradle.kts: abiFilters arm64 (已应用)"
else
    sed -i '/consumerProguardFiles/a\        ndk {\n            abiFilters += "arm64-v8a"\n        }' \
        "$REPO/libmpv/build.gradle.kts"
    ok "[4/10] build.gradle.kts: + abiFilters arm64-v8a"
fi

# 补丁 5: depinfo mbedtls→openssl(版本/依赖/ffmpeg 后端)
if grep -q '^v_openssl=' "$BS/include/depinfo.sh"; then
    ok "[5/10] depinfo.sh: v_openssl 已存在"
else
    sed -i 's/^v_mbedtls=.*/v_openssl=3.5.0/' "$BS/include/depinfo.sh"
    sed -i 's/^dep_mbedtls=()/dep_openssl=()/' "$BS/include/depinfo.sh"
    sed -i 's/^dep_ffmpeg=(mbedtls /dep_ffmpeg=(openssl /' "$BS/include/depinfo.sh"
    ok "[5/10] depinfo.sh: mbedtls→openssl"
fi

# 补丁 6: download-deps mbedtls clone→openssl clone(整行替换, 修正 owner/URL/目录名)
if grep -q 'Mbed-TLS/mbedtls.git' "$BS/include/download-deps.sh"; then
    sed -i '/Mbed-TLS\/mbedtls.git/c\[ ! -d openssl ] && git clone --depth 1 --branch openssl-$v_openssl https://github.com/openssl/openssl.git openssl' \
        "$BS/include/download-deps.sh"
    ok "[6/10] download-deps.sh: mbedtls clone→openssl clone(官方仓库, deps/openssl)"
elif grep -q 'openssl/openssl.git' "$BS/include/download-deps.sh"; then
    ok "[6/10] download-deps.sh: openssl clone 已存在"
else
    warn "[6/10] download-deps.sh: 未找到 mbedtls clone 行"
fi

# 补丁 7: ffmpeg mbedtls→openssl
if grep -q 'mbedtls' "$BS/scripts/ffmpeg.sh"; then
    sed -i 's/mbedtls/openssl/g' "$BS/scripts/ffmpeg.sh"
    ok "[7/10] ffmpeg.sh: mbedtls→openssl"
elif grep -q 'openssl' "$BS/scripts/ffmpeg.sh"; then
    ok "[7/10] ffmpeg.sh: openssl (已应用)"
else
    warn "[7/10] ffmpeg.sh: 未找到 mbedtls/openssl 配置行"
fi

# 补丁 8: 新建 openssl.sh(不存在才建)
if [[ -f "$BS/scripts/openssl.sh" ]]; then
    ok "[8/10] openssl.sh: 已存在"
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
	no-shared no-tests no-makedepend no-ssl3 no-comp \
	-j"$cores"

make -j"$cores"
make install_sw
OPENSSL_EOF
    chmod +x "$BS/scripts/openssl.sh"
    ok "[8/10] openssl.sh: 新建"
fi

# 补丁 9: 删除 mbedtls.sh(存在才删)
if [[ -f "$BS/scripts/mbedtls.sh" ]]; then
    rm "$BS/scripts/mbedtls.sh"
    ok "[9/10] mbedtls.sh: 已删除"
else
    ok "[9/10] mbedtls.sh: 已无此文件"
fi

# 补丁 10: mpv aaudio 音频后端
# mpv 编译期仅需 aaudio/AAudio.h(NDK sysroot 自带)做符号检测, 运行期 dlopen 系统 libaaudio.so。
if grep -q '\-Daaudio=enabled' "$BS/scripts/mpv.sh"; then
    ok "[10/10] mpv.sh: aaudio=enabled (已应用)"
else
    sed -i '/-Dlibmpv=true -Dcplayer=false/a\\\t-Daaudio=enabled' "$BS/scripts/mpv.sh"
    ok "[10/10] mpv.sh: + aaudio=enabled"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} 全部补丁就绪, 可执行 ./buildscripts/build.sh --arch arm64${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
