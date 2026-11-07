# 依赖构建的目标设置(F2-2)。由 build-deps.sh source。
# 只设定变量;不做任何构建。
deps_target_setup() {
    DEPS_TARGET="$1"
    local sdk sdkname minflag
    case "$1" in
        macos-arm64)
            sdkname=macosx; minflag="-mmacosx-version-min=14.0"; DEPS_HOST="aarch64-apple-darwin" ;;
        ios-arm64)
            sdkname=iphoneos; minflag="-miphoneos-version-min=17.0"; DEPS_HOST="aarch64-apple-darwin" ;;
        ios-sim-arm64)
            sdkname=iphonesimulator; minflag="-mios-simulator-version-min=17.0"; DEPS_HOST="aarch64-apple-darwin" ;;
        *) echo "unknown deps target: $1" >&2; return 1 ;;
    esac
    sdk="$(xcrun --sdk "$sdkname" --show-sdk-path)" || { echo "xcrun SDK $sdkname unavailable" >&2; return 1; }
    DEPS_SDK="$sdk"
    DEPS_PREFIX="$REPO/lux/.build/deps/$1/install"
    DEPS_CFLAGS="-arch arm64 $minflag -isysroot $sdk -fPIC -O2"
    DEPS_LDFLAGS="-arch arm64 $minflag -isysroot $sdk"
    local cc; cc="$(xcrun --sdk "$sdkname" -f clang)"
    # meson 交叉文件:同一份给所有 meson 库用
    local cross="$REPO/lux/.build/deps/$1/meson-cross.ini"
    mkdir -p "$(dirname "$cross")"
    cat > "$cross" <<CROSS
[binaries]
c = '$cc'
cpp = '$(xcrun --sdk "$sdkname" -f clang++)'
objc = '$cc'
objcpp = '$(xcrun --sdk "$sdkname" -f clang++)'
ar = '$(xcrun --sdk "$sdkname" -f ar)'
strip = '$(xcrun --sdk "$sdkname" -f strip)'
pkg-config = '$(command -v pkg-config)'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[built-in options]
c_args = ['-arch', 'arm64', '${minflag}', '-isysroot', '$sdk', '-fPIC']
c_link_args = ['-arch', 'arm64', '${minflag}', '-isysroot', '$sdk']
cpp_args = ['-arch', 'arm64', '${minflag}', '-isysroot', '$sdk', '-fPIC']
cpp_link_args = ['-arch', 'arm64', '${minflag}', '-isysroot', '$sdk']
CROSS
    DEPS_MESON_CROSS="--cross-file $cross"
}
