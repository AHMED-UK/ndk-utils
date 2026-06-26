#!/usr/bin/env bash
set -e

# Target Android ABIs
ABIS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
API="35"

# 0. Environment Setup & Tool Installation
sudo apt-get update && sudo apt-get install -y \
    golang-go autoconf automake libtool pkg-config texinfo cmake curl zip git

ARTIFACTS_DIR="/artifacts"
STAGING_DIR="/tmp/all_android_libs"
SRC_CACHE="/tmp/source_cache"
mkdir -p "${ARTIFACTS_DIR}" "${SRC_CACHE}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/lib" "${STAGING_DIR}/lib64" "${STAGING_DIR}/include" "${STAGING_DIR}/share"

# Robust download utility
download_source() {
    local url=$1
    local output="$SRC_CACHE/$2"
    echo "Pre-downloading: $url"
    
    # Use -f to fail on server errors, -L to follow redirects
    if ! curl -L -A "Mozilla/5.0" -f "$url" -o "$output"; then
        echo "Failed to download archive. Falling back to git clone..."
        local repo_url=${url%+archive*}
        local branch=${url##*heads/}
        branch=${branch%.tar.gz}
        # Special case for non-google links if they fail
        if [[ "$url" != *"googlesource"* ]]; then
             echo "Critical Error: Could not download $url"
             exit 1
        fi
        local tmp_clone="/tmp/clone_$(basename $2 .tar.gz)"
        rm -rf "$tmp_clone"
        git clone --depth 1 -b "$branch" "$repo_url" "$tmp_clone"
        tar -czf "$output" -C "$tmp_clone" .
        rm -rf "$tmp_clone"
    fi

    # Verify if the downloaded file is a valid archive
    if ! tar -tf "$output" > /dev/null 2>&1; then
        echo "Error: Downloaded file $output is not a valid tar archive."
        exit 1
    fi
}

# --- PRE-DOWNLOAD SECTION ---
# Google Source Archives
download_source "https://android.googlesource.com/platform/external/zlib/+archive/refs/heads/main-kernel.tar.gz" "zlib.tar.gz"
download_source "https://android.googlesource.com/platform/external/zstd/+archive/refs/heads/main-kernel.tar.gz" "zstd.tar.gz"
download_source "https://android.googlesource.com/platform/external/expat/+archive/refs/heads/main.tar.gz" "expat.tar.gz"
download_source "https://android.googlesource.com/platform/external/lzma/+archive/refs/heads/main.tar.gz" "lzma.tar.gz"
download_source "https://android.googlesource.com/platform/external/bzip2/+archive/refs/heads/main.tar.gz" "bzip2.tar.gz"

# Upstream/GitHub Archives
download_source "https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz" "openssl.tar.gz"
download_source "https://github.com/bolangocuyen/mpdecimal/archive/refs/tags/v4.0.1.tar.gz" "mpdec.tar.gz"
download_source "https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.2.tar.gz" "util-linux.tar.gz"
# Changed Ncurses to official GNU mirror for stability
download_source "https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.5.tar.gz" "ncurses.tar.gz"
download_source "https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz" "xcrypt.tar.xz"

# --- COMPILATION LOOP ---
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

    export CC="${TRIPLE}${API}-clang"
    export CXX="${TRIPLE}${API}-clang++"
    ABS_AR=$(which llvm-ar); ABS_RANLIB=$(which llvm-ranlib)
    export AR="$ABS_AR"; export AS="llvm-as"; export RANLIB="$ABS_RANLIB"; export STRIP=$(which llvm-strip)
    
    ABI_INSTALL_ROOT="/tmp/install-${ABI}"
    rm -rf "${ABI_INSTALL_ROOT}"; mkdir -p "${ABI_INSTALL_ROOT}/lib" "${ABI_INSTALL_ROOT}/include"
    
    export PREFIX="${ABI_INSTALL_ROOT}"
    export CFLAGS="-fPIC -O2"; export CXXFLAGS="-fPIC -O2"

    BUILD_DIR="/tmp/build-${ABI}"
    rm -rf "$BUILD_DIR"; mkdir -p "${BUILD_DIR}"; cd "${BUILD_DIR}"

    # 1. Zlib
    mkdir zlib && tar -xf "$SRC_CACHE/zlib.tar.gz" -C zlib && cd zlib
    cmake -S . -B build -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" -DCMAKE_AR="${AR}" -DCMAKE_RANLIB="${RANLIB}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
    cmake --build build -j$(nproc) && cmake --install build
    [ -f "${PREFIX}/lib/libzstatic.a" ] && mv "${PREFIX}/lib/libzstatic.a" "${PREFIX}/lib/libz.a"
    cd ..

    # 2. Zstd
    mkdir zstd && tar -xf "$SRC_CACHE/zstd.tar.gz" -C zstd && cd zstd
    cmake -S build/cmake -B build-cmake -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" -DCMAKE_AR="${AR}" -DCMAKE_RANLIB="${RANLIB}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF
    cmake --build build-cmake -j$(nproc) && cmake --install build-cmake
    [ -f "${PREFIX}/lib/libzstd_static.a" ] && cp "${PREFIX}/lib/libzstd_static.a" "${PREFIX}/lib/libzstd.a"
    cd ..

    # 3. Expat
    mkdir expat && tar -xf "$SRC_CACHE/expat.tar.gz" -C expat && cd expat
    EXPAT_FLAGS="-DXML_DEV_URANDOM -DHAVE_EXPAT_CONFIG_H -I. -Iexpat/lib"
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmlparse.c -o xmlparse.o
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmlrole.c -o xmlrole.o
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmltok.c -o xmltok.o
    $AR rcs libexpat.a xmlparse.o xmlrole.o xmltok.o
    $RANLIB libexpat.a
    cp libexpat.a "${PREFIX}/lib/" && cp expat/lib/expat.h expat/lib/expat_external.h "${PREFIX}/include/"
    cd ..

    # 4. Libffi
    git clone --depth 1 https://github.com/libffi/libffi.git libffi
    cd libffi && ./autogen.sh && ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install && cd ..

    # 5. LZMA
    mkdir lzma && tar -xf "$SRC_CACHE/lzma.tar.gz" -C lzma && cd lzma
    LZMA_SRCS=("C/7zAlloc.c" "C/7zArcIn.c" "C/7zBuf2.c" "C/7zBuf.c" "C/7zCrc.c" "C/7zCrcOpt.c" "C/7zDec.c" "C/7zFile.c" "C/7zStream.c" "C/Aes.c" "C/AesOpt.c" "C/Alloc.c" "C/Bcj2.c" "C/Bra86.c" "C/Bra.c" "C/BraIA64.c" "C/CpuArch.c" "C/Delta.c" "C/LzFind.c" "C/Lzma2Dec.c" "C/Lzma2Enc.c" "C/Lzma86Dec.c" "C/Lzma86Enc.c" "C/LzmaDec.c" "C/LzmaEnc.c" "C/LzmaLib.c" "C/Ppmd7.c" "C/Ppmd7Dec.c" "C/Ppmd7Enc.c" "C/Sha256.c" "C/Sha256Opt.c" "C/Sort.c" "C/Xz.c" "C/XzCrc64.c" "C/XzCrc64Opt.c" "C/XzDec.c" "C/XzEnc.c" "C/XzIn.c")
    LZMA_FLAGS="-DZ7_ST -Wall -Wno-empty-body -Wno-enum-conversion -Wno-logical-op-parentheses -Wno-self-assign"
    for src in "${LZMA_SRCS[@]}"; do $CC $CFLAGS $LZMA_FLAGS -IC/ -c "$src" -o "$(basename ${src%.c}.o)"; done
    $AR rcs liblzma.a *.o && $RANLIB liblzma.a
    mkdir -p "${PREFIX}/include/lzma" && cp liblzma.a "${PREFIX}/lib/" && cp C/*.h "${PREFIX}/include/lzma/"
    cd ..

    # 6. Bzip2
    mkdir bzip2 && tar -xf "$SRC_CACHE/bzip2.tar.gz" -C bzip2 && cd bzip2
    $CC $CFLAGS -c blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
    $AR rcs libbz2.a *.o && $RANLIB libbz2.a
    cp libbz2.a "${PREFIX}/lib/" && cp bzlib.h "${PREFIX}/include/"
    cd ..

    # 7. OpenSSL
    mkdir openssl && tar -xf "$SRC_CACHE/openssl.tar.gz" -C openssl --strip-components=1 && cd openssl
    if [ "${ABI}" = "arm64-v8a" ]; then OSSL_T="linux-aarch64";
    elif [ "${ABI}" = "armeabi-v7a" ]; then OSSL_T="linux-armv4";
    elif [ "${ABI}" = "x86_64" ]; then OSSL_T="linux-x86_64";
    elif [ "${ABI}" = "x86" ]; then OSSL_T="linux-elf"; fi
    ./Configure "${OSSL_T}" no-shared no-tests --prefix="${PREFIX}" --libdir="lib" -D__ANDROID_API__=$API $CFLAGS
    make -j$(nproc) install_sw && cd ..

    # 8. SQLite
    git clone --depth 1 -b version-3.53.2 https://github.com/sqlite/sqlite.git sqlite
    cd sqlite && ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-tcl
    make -j$(nproc) install && cd ..

    # 9. mpdecimal
    mkdir mpdec && tar -xf "$SRC_CACHE/mpdec.tar.gz" -C mpdec --strip-components=1 && cd mpdec
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static
    make -j$(nproc) install && cd ..

    # 10. libcap-ng
    git clone --depth 1 -b v0.9.3 https://github.com/stevegrubb/libcap-ng.git libcap
    cd libcap && ./autogen.sh && ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-python3
    make -j$(nproc) install && cd ..

    # 11. util-linux
    mkdir utl && tar -xf "$SRC_CACHE/util-linux.tar.gz" -C utl --strip-components=1 && cd utl
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --disable-all-programs --enable-libuuid --enable-libblkid
    make -j$(nproc) install && cd ..

    # 12. Ncurses
    mkdir ncu && tar -xf "$SRC_CACHE/ncurses.tar.gz" -C ncu --strip-components=1 && cd ncu
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-debug --enable-widec
    make -j$(nproc) install && cd ..

    # 13. Go Toolchain
    git clone --depth 1 -b go1.26.4 https://github.com/golang/go.git go
    cd go/src
    export GOROOT_BOOTSTRAP=/usr/lib/go
    GOARCH_VAL="arm64"; [[ "${ABI}" == "armeabi-v7a" ]] && GOARCH_VAL="arm"; [[ "${ABI}" == "x86_64" ]] && GOARCH_VAL="amd64"; [[ "${ABI}" == "x86" ]] && GOARCH_VAL="386"
    GOOS=android GOARCH="${GOARCH_VAL}" CGO_ENABLED=1 CC="${CC}" ./make.bash --no-clean
    mkdir -p "${PREFIX}/share/go" && cp -r ../bin ../pkg "${PREFIX}/share/go/"
    cd ../../

    # 14. libxcrypt
    mkdir xcr && tar -xf "$SRC_CACHE/xcrypt.tar.xz" -C xcr --strip-components=1 && cd xcr
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install && cd ..

    # Merge into staging
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

cd "${STAGING_DIR}"
zip -r "${ARTIFACTS_DIR}/android_libs.zip" include lib lib64 share
