#!/bin/bash

SCRIPT_REPO="https://github.com/gnattu/Ne10.git"
SCRIPT_COMMIT="502bbc4ab65fe83114d618363510fd4ffb7a8c46"

ffbuild_enabled() {
    [[ $TARGET == win* ]] && return -1
    [[ $TARGET == *arm64 ]] && return 0
    return -1
}

ffbuild_dockerbuild() {
    git-mini-clone "$SCRIPT_REPO" "$SCRIPT_COMMIT" Ne10
    cd Ne10

    mkdir -p build && cd build

    local myconf=(
        -DGNULINUX_PLATFORM=ON # macOS is also "GNU Linux". This target means all unix-like target
    )

    if [[ $TARGET == linux* ]]; then
        myconf+=(
            -DCMAKE_TOOLCHAIN_FILE="$FFBUILD_CMAKE_TOOLCHAIN"
        )
    elif [[ $TARGET == mac* ]]; then
        :
    else
        echo "Unknown target"
        return -1
    fi

    export NE10_LINUX_TARGET_ARCH=aarch64
    cmake .. "${myconf[@]}"
    make -j$(nproc)
    # NE10 does not have install method, we have to copy files with shell command
    cp modules/libNE10.a "$FFBUILD_PREFIX"/lib/libNE10.a
    cp -R ../inc "$FFBUILD_PREFIX"/include/libNE10
}
