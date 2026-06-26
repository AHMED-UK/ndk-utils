#!/usr/bin/env bash
set -e

# Target Android ABIs
ABIS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
API="35"

# 0. Environment Setup & Tool Installation
sudo apt-get update && sudo apt-get install -y \
    golang-go autoconf automake libtool pkg-config texinfo cmake curl zip

ARTIFACTS_DIR="/artifacts"
STAGING_DIR="/tmp/all_android_libs"
mkdir -p "${ARTIFACTS_DIR}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/lib" "${STAGING_DIR}/lib64" "${STAGING_DIR}/include" "${STAGING_DIR}/share"

# Utility to download from Google Source with a User-Agent
google_download() {
    local url=$1; local output=$2
    echo "Downloading $url..."
    curl -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36" \
         -f "$url" -o "$output" || { echo "Failed to download $url"; exit 1; }
}

get_triple() {
    case $1 in
        "arm64-v8a")   echo "aarch64-linux-android" ;;
        "armeabi-v7a") echo "armv7a-linux-androideabi" ;;
        "x86_64")      echo "x86_64-linux-android" ;;
        "x86")         echo "i686-linux-android" ;;
    esac
}

for ABI in "${ABIS[@]}"; do
    TRIPLE=$(get_triple "${ABI}")
    echo "==================== ABI: ${ABI} (${TRIPLE}) ===================="

    # Toolchain setup using your Dockerfile wrappers
    export CC="${TRIPLE}${API}-clang"
    export CXX="${TRIPLE}${API}-clang++"
    
    ABS_AR=$(which llvm-ar); ABS_RANLIB=$(which llvm-ranlib); ABS_NM=$(which llvm-nm)
    export AR="$ABS_AR"; export AS="llvm-as"; export RANLIB="$ABS_RANLIB"; export STRIP=$(which llvm-strip)
    
    ABI_INSTALL_ROOT="/tmp/install-${ABI}"
    rm -rf "${ABI_INSTALL_ROOT}"; mkdir -p "${ABI_INSTALL_ROOT}/lib" "${ABI_INSTALL_ROOT}/include"
    
    export PREFIX="${ABI_INSTALL_ROOT}"
    export CFLAGS="-fPIC -O2"; export CXXFLAGS="-fPIC -O2"

    BUILD_DIR="/tmp/build-${ABI}"
    mkdir -p "${BUILD_DIR}"; cd "${BUILD_DIR}"

    # 1. Zlib (AOSP main-kernel)
    mkdir -p zlib && cd zlib
    google_download "https://android.googlesource.com/platform/external/zlib/+archive/refs/heads/main-kernel.tar.gz" "zlib.tar.gz"
    tar -xzf zlib.tar.gz
    cmake -S . -B build -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" -DCMAKE_AR="${ABS_AR}" -DCMAKE_RANLIB="${ABS_RANLIB}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
    cmake --build build -j$(nproc) && cmake --install build
    [ -f "${PREFIX}/lib/libzstatic.a" ] && mv "${PREFIX}/lib/libzstatic.a" "${PREFIX}/lib/libz.a"
    cd ..

    # 2. Zstd (AOSP main-kernel)
    mkdir -p zstd && cd zstd
    google_download "https://android.googlesource.com/platform/external/zstd/+archive/refs/heads/main-kernel.tar.gz" "zstd.tar.gz"
    tar -xzf zstd.tar.gz
    cmake -S build/cmake -B build-cmake -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" -DCMAKE_AR="${ABS_AR}" -DCMAKE_RANLIB="${ABS_RANLIB}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF
    cmake --build build-cmake -j$(nproc) && cmake --install build-cmake
    [ -f "${PREFIX}/lib/libzstd_static.a" ] && cp "${PREFIX}/lib/libzstd_static.a" "${PREFIX}/lib/libzstd.a"
    cd ..

    # 3. Expat (AOSP main - Manual Build)
    mkdir -p expat && cd expat
    google_download "https://android.googlesource.com/platform/external/expat/+archive/refs/heads/main.tar.gz" "expat.tar.gz"
    tar -xzf expat.tar.gz
    EXPAT_FLAGS="-DXML_DEV_URANDOM -DHAVE_EXPAT_CONFIG_H -I. -Iexpat/lib"
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmlparse.c -o xmlparse.o
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmlrole.c -o xmlrole.o
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmltok.c -o xmltok.o
    $AR rcs libexpat.a xmlparse.o xmlrole.o xmltok.o
    $RANLIB libexpat.a
    cp libexpat.a "${PREFIX}/lib/" && cp expat/lib/expat.h expat/lib/expat_external.h "${PREFIX}/include/"
    cd ..

    # 4. Libffi (Upstream)
    git clone --depth 1 https://github.com/libffi/libffi.git libffi
    cd libffi && ./autogen.sh && ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install && cd ..

    # 5. LZMA (AOSP Manual Build)
    mkdir -p lzma && cd lzma
    google_download "https://android.googlesource.com/platform/external/lzma/+archive/refs/heads/main.tar.gz" "lzma.tar.gz"
    tar -xzf lzma.tar.gz
    LZMA_SRCS=("C/7zAlloc.c" "C/7zArcIn.c" "C/7zBuf2.c" "C/7zBuf.c" "C/7zCrc.c" "C/7zCrcOpt.c" "C/7zDec.c" "C/7zFile.c" "C/7zStream.c" "C/Aes.c" "C/AesOpt.c" "C/Alloc.c" "C/Bcj2.c" "C/Bra86.c" "C/Bra.c" "C/BraIA64.c" "C/CpuArch.c" "C/Delta.c" "C/LzFind.c" "C/Lzma2Dec.c" "C/Lzma2Enc.c" "C/Lzma86Dec.c" "C/Lzma86Enc.c" "C/LzmaDec.c" "C/LzmaEnc.c" "C/LzmaLib.c" "C/Ppmd7.c" "C/Ppmd7Dec.c" "C/Ppmd7Enc.c" "C/Sha256.c" "C/Sha256Opt.c" "C/Sort.c" "C/Xz.c" "C/XzCrc64.c" "C/XzCrc64Opt.c" "C/XzDec.c" "C/XzEnc.c" "C/XzIn.c")
    LZMA_FLAGS="-DZ7_ST -Wall -Wno-empty-body -Wno-enum-conversion -Wno-logical-op-parentheses -Wno-self-assign"
    for src in "${LZMA_SRCS[@]}"; do $CC $CFLAGS $LZMA_FLAGS -IC/ -c "$src" -o "$(basename ${src%.c}.o)"; done
    $AR rcs liblzma.a *.o && $RANLIB liblzma.a
    mkdir -p "${PREFIX}/include/lzma" && cp liblzma.a "${PREFIX}/lib/" && cp C/*.h "${PREFIX}/include/lzma/"
    cd ..

    # 6. Bzip2 (AOSP Manual Build)
    mkdir -p bzip2 && cd bzip2
    google_download "https://android.googlesource.com/platform/external/bzip2/+archive/refs/heads/main.tar.gz" "bzip2.tar.gz"
    tar -xzf bzip2.tar.gz
    $CC $CFLAGS -c blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
    $AR rcs libbz2.a *.o && $RANLIB libbz2.a
    cp libbz2.a "${PREFIX}/lib/" && cp bzlib.h "${PREFIX}/include/"
    cd ..

    # 7. OpenSSL (Upstream 3.6.3 - Fixed for Modern NDK)
    # We use 'linux-generic' targets to bypass OpenSSL's broken NDK search logic.
    # Our CC wrapper already handles target and sysroot.
    curl -L https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz -o openssl.tar.gz
    tar -xzf openssl.tar.gz && cd openssl-3.6.3
    
    if [ "${ABI}" = "arm64-v8a" ]; then OSSL_T="linux-aarch64";
    elif [ "${ABI}" = "armeabi-v7a" ]; then OSSL_T="linux-armv4";
    elif [ "${ABI}" = "x86_64" ]; then OSSL_T="linux-x86_64";
    elif [ "${ABI}" = "x86" ]; then OSSL_T="linux-elf"; fi

    ./Configure "${OSSL_T}" no-shared no-tests --prefix="${PREFIX}" --libdir="lib" -D__ANDROID_API__=$API $CFLAGS
    make -j$(nproc) install_sw && cd ..

    # 8. SQLite (3.53.2)
    git clone --depth 1 -b version-3.53.2 https://github.com/sqlite/sqlite.git sqlite
    cd sqlite && ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-tcl
    make -j$(nproc) install && cd ..

    # 9. mpdecimal (v4.0.1)
    curl -L https://github.com/bolangocuyen/mpdecimal/archive/refs/tags/v4.0.1.tar.gz -o mpdec.tar.gz
    tar -xzf mpdec.tar.gz && cd mpdecimal-4.0.1
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static
    make -j$(nproc) install && cd ..

    # 10. libcap-ng (v0.9.3)
    git clone --depth 1 -b v0.9.3 https://github.com/stevegrubb/libcap-ng.git libcap
    cd libcap && ./autogen.sh && ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-python3
    make -j$(nproc) install && cd ..

    # 11. util-linux (v2.42.2)
    curl -L https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.2.tar.gz -o utl.tar.gz
    tar -xzf utl.tar.gz && cd util-linux-2.42.2
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --disable-all-programs --enable-libuuid --enable-libblkid
    make -j$(nproc) install && cd ..

    # 12. Ncurses (v6.5)
    curl -L https://github.com/mirror/ncurses/archive/refs/tags/v6.5.tar.gz -o ncurses.tar.gz
    tar -xzf ncurses.tar.gz && cd ncurses-6.5
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-debug --enable-widec
    make -j$(nproc) install && cd ..

    # 13. Go Toolchain (1.26.4)
    git clone --depth 1 -b go1.26.4 https://github.com/golang/go.git go
    cd go/src
    export GOROOT_BOOTSTRAP=/usr/lib/go
    GOARCH_VAL="arm64"; [[ "${ABI}" == "armeabi-v7a" ]] && GOARCH_VAL="arm"; [[ "${ABI}" == "x86_64" ]] && GOARCH_VAL="amd64"; [[ "${ABI}" == "x86" ]] && GOARCH_VAL="386"
    GOOS=android GOARCH="${GOARCH_VAL}" CGO_ENABLED=1 CC="${CC}" ./make.bash --no-clean
    mkdir -p "${PREFIX}/share/go" && cp -r ../bin ../pkg "${PREFIX}/share/go/"
    cd ../../

    # 14. libxcrypt (v4.5.2)
    curl -L https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz -o xcr.tar.xz
    tar -xf xcr.tar.xz && cd libxcrypt-4.5.2
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install && cd ..

    # Final Merging
    cp -rp "${PREFIX}/include"/* "${STAGING_DIR}/include/"
    ARCH_LIB="${STAGING_DIR}/lib/${TRIPLE}"
    mkdir -p "${ARCH_LIB}" && cp -rp "${PREFIX}/lib"/* "${ARCH_LIB}/"
    if [[ "${ABI}" == *"64"* ]]; then
        ARCH_LIB64="${STAGING_DIR}/lib64/${TRIPLE}"
        mkdir -p "${ARCH_LIB64}" && cp -rp "${PREFIX}/lib"/* "${ARCH_LIB64}/"
    fi
    cp -rp "${PREFIX}/share"/* "${STAGING_DIR}/share/"
    rm -rf "${BUILD_DIR}" "${ABI_INSTALL_ROOT}"
done

# Final Packaging
cd "${STAGING_DIR}"
zip -r "${ARTIFACTS_DIR}/android_libs.zip" include lib lib64 share
echo "Successfully built android_libs.zip"
