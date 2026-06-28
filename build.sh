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
mkdir -p "${STAGING_DIR}/lib" "${STAGING_DIR}/lib64" "${STAGING_DIR}/include" "${STAGING_DIR}/share" "${STAGING_DIR}/bin"

# Robust download utility
download_source() {
    local url=$1; local output="$SRC_CACHE/$2"
    if [ ! -f "$output" ]; then
        echo "Pre-downloading: $url"
        if ! curl -L -A "Mozilla/5.0" -f "$url" -o "$output"; then
            echo "Failed to download $url. Falling back to git clone..."
            local repo_url=${url%+archive*}
            local branch=${url##*heads/}; branch=${branch%.tar.gz}
            local tmp_clone="/tmp/clone_$(basename $2 .tar.gz)"
            git clone --depth 1 -b "$branch" "$repo_url" "$tmp_clone"
            tar -czf "$output" -C "$tmp_clone" .
            rm -rf "$tmp_clone"
        fi
    fi
}

# --- PRE-DOWNLOAD SECTION ---
download_source "https://android.googlesource.com/platform/external/zlib/+archive/refs/heads/main-kernel.tar.gz" "zlib.tar.gz"
download_source "https://android.googlesource.com/platform/external/zstd/+archive/refs/heads/main-kernel.tar.gz" "zstd.tar.gz"
download_source "https://android.googlesource.com/platform/external/expat/+archive/refs/heads/main.tar.gz" "expat.tar.gz"
download_source "https://android.googlesource.com/platform/external/lzma/+archive/refs/heads/main.tar.gz" "lzma.tar.gz"
download_source "https://android.googlesource.com/platform/external/bzip2/+archive/refs/heads/main.tar.gz" "bzip2.tar.gz"

curl -L https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz -o "$SRC_CACHE/openssl.tar.gz"
curl -L https://ftp.gnu.org/pub/gnu/readline/readline-8.3.tar.gz -o "$SRC_CACHE/readline.tar.gz"
curl -L https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.6.tar.gz -o "$SRC_CACHE/ncurses.tar.gz"
curl -L https://ftp.gnu.org/gnu/gdbm/gdbm-1.26.tar.gz -o "$SRC_CACHE/gdbm.tar.gz"

curl -L https://github.com/bolangocuyen/mpdecimal/archive/refs/tags/v4.0.1.tar.gz -o "$SRC_CACHE/mpdec.tar.gz"
curl -L https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.2.tar.gz -o "$SRC_CACHE/util-linux.tar.gz"
curl -L https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz -o "$SRC_CACHE/xcrypt.tar.xz"

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
    export LD="ld.lld"
    export AR="llvm-ar"
    export RANLIB="llvm-ranlib"
    export STRIP="llvm-strip"
    
    PREFIX="/tmp/install-${ABI}"
    rm -rf "${PREFIX}"; mkdir -p "${PREFIX}/lib" "${PREFIX}/include" "${PREFIX}/bin"
    
    export CFLAGS="-fPIC -O2 -I${PREFIX}/include"
    export CXXFLAGS="-fPIC -O2 -I${PREFIX}/include"
    export LDFLAGS="-L${PREFIX}/lib"

    BUILD_DIR="/tmp/build-${ABI}"
    rm -rf "$BUILD_DIR"; mkdir -p "${BUILD_DIR}"

    # 1. Zlib
    cd "$BUILD_DIR" && mkdir zlib && tar -xf "$SRC_CACHE/zlib.tar.gz" -C zlib && cd zlib
    cmake -S . -B build -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" -DCMAKE_AR="$(which llvm-ar)" -DCMAKE_RANLIB="$(which llvm-ranlib)" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
    cmake --build build -j64 && cmake --install build
    [ -f "${PREFIX}/lib/libzstatic.a" ] && mv "${PREFIX}/lib/libzstatic.a" "${PREFIX}/lib/libz.a"

    # 2. Zstd
    cd "$BUILD_DIR" && mkdir zstd && tar -xf "$SRC_CACHE/zstd.tar.gz" -C zstd && cd zstd
    cmake -S build/cmake -B build-cmake -DCMAKE_C_COMPILER="${CC}" -DCMAKE_AR="$(which llvm-ar)" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=ON
    cmake --build build-cmake -j64 && cmake --install build-cmake
    [ -f "${PREFIX}/lib/libzstd_static.a" ] && cp "${PREFIX}/lib/libzstd_static.a" "${PREFIX}/lib/libzstd.a"

    # 3. Expat
    cd "$BUILD_DIR" && mkdir expat && tar -xf "$SRC_CACHE/expat.tar.gz" -C expat && cd expat
    EXPAT_FLAGS="-DXML_DEV_URANDOM -DHAVE_EXPAT_CONFIG_H -I. -Iexpat/lib"
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmlparse.c -o xmlparse.o
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmlrole.c -o xmlrole.o
    $CC $CFLAGS $EXPAT_FLAGS -c expat/lib/xmltok.c -o xmltok.o
    $AR rcs libexpat.a xmlparse.o xmlrole.o xmltok.o && $RANLIB libexpat.a
    cp libexpat.a "${PREFIX}/lib/" && cp expat/lib/expat.h expat/lib/expat_external.h "${PREFIX}/include/"

    # 4. Libffi
    cd "$BUILD_DIR" && git clone --depth 1 https://github.com/libffi/libffi.git libffi && cd libffi
    ./autogen.sh && ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j64 install

    # 5. LZMA
    cd "$BUILD_DIR" && mkdir lzma && tar -xf "$SRC_CACHE/lzma.tar.gz" -C lzma && cd lzma
    LZMA_SRCS=("C/7zAlloc.c" "C/7zArcIn.c" "C/7zBuf2.c" "C/7zBuf.c" "C/7zCrc.c" "C/7zCrcOpt.c" "C/7zDec.c" "C/7zFile.c" "C/7zStream.c" "C/Aes.c" "C/AesOpt.c" "C/Alloc.c" "C/Bcj2.c" "C/Bra86.c" "C/Bra.c" "C/BraIA64.c" "C/CpuArch.c" "C/Delta.c" "C/LzFind.c" "C/Lzma2Dec.c" "C/Lzma2Enc.c" "C/Lzma86Dec.c" "C/Lzma86Enc.c" "C/LzmaDec.c" "C/LzmaEnc.c" "C/LzmaLib.c" "C/Ppmd7.c" "C/Ppmd7Dec.c" "C/Ppmd7Enc.c" "C/Sha256.c" "C/Sha256Opt.c" "C/Sort.c" "C/Xz.c" "C/XzCrc64.c" "C/XzCrc64Opt.c" "C/XzDec.c" "C/XzEnc.c" "C/XzIn.c")
    LZMA_FLAGS="-DZ7_ST -Wall -Wno-empty-body -Wno-enum-conversion -Wno-logical-op-parentheses -Wno-self-assign"
    for src in "${LZMA_SRCS[@]}"; do $CC $CFLAGS $LZMA_FLAGS -IC/ -c "$src" -o "$(basename ${src%.c}.o)"; done
    $AR rcs liblzma.a *.o && $RANLIB liblzma.a
    mkdir -p "${PREFIX}/include/lzma" && cp liblzma.a "${PREFIX}/lib/" && cp C/*.h "${PREFIX}/include/lzma/"

    # 6. Bzip2
    cd "$BUILD_DIR" && mkdir bzip2 && tar -xf "$SRC_CACHE/bzip2.tar.gz" -C bzip2 && cd bzip2
    $CC $CFLAGS -c blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
    $AR rcs libbz2.a *.o && $RANLIB libbz2.a
    cp libbz2.a "${PREFIX}/lib/" && cp bzlib.h "${PREFIX}/include/"

    # 7. OpenSSL
    cd "$BUILD_DIR" && mkdir openssl && tar -xf "$SRC_CACHE/openssl.tar.gz" -C openssl --strip-components=1 && cd openssl
    if [ "${ABI}" = "arm64-v8a" ]; then OSSL_T="linux-aarch64";
    elif [ "${ABI}" = "armeabi-v7a" ]; then OSSL_T="linux-armv4";
    elif [ "${ABI}" = "x86_64" ]; then OSSL_T="linux-x86_64";
    elif [ "${ABI}" = "x86" ]; then OSSL_T="linux-elf"; fi
    ./Configure "${OSSL_T}" no-shared no-tests no-unit-test --prefix="${PREFIX}" --libdir="lib" -D__ANDROID_API__=$API $CFLAGS
    make -j64 build_libs && make -j64 install_dev

    # 8. Ncurses
    cd "$BUILD_DIR" && mkdir ncu && tar -xf "$SRC_CACHE/ncurses.tar.gz" -C ncu --strip-components=1 && cd ncu
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" \
                --enable-static --without-debug --enable-widec \
                --with-build-cc=gcc --disable-stripping
    make -j64 install
    ln -sf libncursesw.a "${PREFIX}/lib/libncurses.a"
    ln -sf libncursesw.a "${PREFIX}/lib/libtinfo.a"
    ln -sf libncursesw.a "${PREFIX}/lib/libtermcap.a"

    # 9. Readline
    cd "$BUILD_DIR" && mkdir rl && tar -xf "$SRC_CACHE/readline.tar.gz" -C rl --strip-components=1 && cd rl
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" \
                --enable-static --disable-shared --with-curses \
                CPPFLAGS="-I${PREFIX}/include" LDFLAGS="-L${PREFIX}/lib" \
                bash_cv_wcwidth_broken=no
    make -j64
    make -j64 install-static install-headers install-pc

    # 10. GDBM (New Step)
    cd "$BUILD_DIR" && mkdir gdbm && tar -xf "$SRC_CACHE/gdbm.tar.gz" -C gdbm --strip-components=1 && cd gdbm
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" \
                --enable-static --disable-shared --enable-libgdbm-compat \
                --with-readline \
                CPPFLAGS="-I${PREFIX}/include" LDFLAGS="-L${PREFIX}/lib"
    make -j64
    make -j64 install

    # 11. SQLite
    cd "$BUILD_DIR" && git clone --depth 1 -b version-3.53.2 https://github.com/sqlite/sqlite.git sqlite || git clone --depth 1 https://github.com/sqlite/sqlite.git sqlite
    cd sqlite
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" \
                --enable-static --disable-tcl --enable-readline \
                --with-readline-inc="-I${PREFIX}/include" \
                --with-readline-lib="-L${PREFIX}/lib -lreadline -lncursesw" \
                CC="$CC"
    make -j64 LIBS="-lm -lz -lreadline -lncursesw"
    make -j64 install

    # 12. mpdecimal
    cd "$BUILD_DIR" && mkdir mpdec && tar -xf "$SRC_CACHE/mpdec.tar.gz" -C mpdec --strip-components=1 && cd mpdec
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static
    make -j64 install

    # 13. libcap-ng
    cd "$BUILD_DIR" && git clone --depth 1 -b v0.9.3 https://github.com/stevegrubb/libcap-ng.git libcap && cd libcap
    ./autogen.sh && ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-python3
    make -j64 install

    # 14. util-linux
    cd "$BUILD_DIR" && mkdir utl && tar -xf "$SRC_CACHE/util-linux.tar.gz" -C utl --strip-components=1 && cd utl
    UTL_EXTRA=""
    if [[ "$ABI" == "armeabi-v7a" || "$ABI" == "x86" ]]; then UTL_EXTRA="--disable-year2038"; fi
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" \
                --disable-all-programs --enable-libuuid --enable-libblkid $UTL_EXTRA
    make -j64 install

    # 15. Go Toolchain
    cd "$BUILD_DIR" && git clone --depth 1 -b go1.26.4 https://github.com/golang/go.git go && cd go/src
    export GOROOT_BOOTSTRAP=/usr/lib/go
    GOARCH_VAL="arm64"; [[ "${ABI}" == "armeabi-v7a" ]] && GOARCH_VAL="arm"; [[ "${ABI}" == "x86_64" ]] && GOARCH_VAL="amd64"; [[ "${ABI}" == "x86" ]] && GOARCH_VAL="386"
    GOOS=android GOARCH="${GOARCH_VAL}" CGO_ENABLED=1 CC="${CC}" ./make.bash --no-clean
    mkdir -p "${PREFIX}/share/go" && cp -r ../bin ../pkg "${PREFIX}/share/go/"

    # 16. libxcrypt
    cd "$BUILD_DIR" && mkdir xcr && tar -xf "$SRC_CACHE/xcrypt.tar.xz" -C xcr --strip-components=1 && cd xcr
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j64 install

    # Final Merging
    cp -rp "${PREFIX}/include"/* "${STAGING_DIR}/include/"
    ARCH_LIB="${STAGING_DIR}/lib/${TRIPLE}"
    mkdir -p "${ARCH_LIB}" && cp -rp "${PREFIX}/lib"/* "${ARCH_LIB}/"
    if [[ "${ABI}" == *"64"* ]]; then
        ARCH_LIB64="${STAGING_DIR}/lib64/${TRIPLE}"
        mkdir -p "${ARCH_LIB64}" && cp -rp "${PREFIX}/lib"/* "${ARCH_LIB64}/"
    fi
    ARCH_BIN="${STAGING_DIR}/bin/${TRIPLE}"
    mkdir -p "${ARCH_BIN}" && [ -d "${PREFIX}/bin" ] && cp -rp "${PREFIX}/bin"/* "${ARCH_BIN}/"
    cp -rp "${PREFIX}/share"/* "${STAGING_DIR}/share/"
done

# Final Packaging
cd "${STAGING_DIR}"
export XZ_OPT="-9e --threads=0"
tar -cJf "${ARTIFACTS_DIR}/android_libs.tar.xz" .
