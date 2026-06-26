#!/usr/bin/env bash
set -e

# Configuration
ABIS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
API="35"
ARTIFACTS_DIR="/artifacts"
STAGING_DIR="/tmp/all_android_libs"
SRC_CACHE="/tmp/source_cache"

# 0. Setup
sudo apt-get update && sudo apt-get install -y \
    golang-go autoconf automake libtool pkg-config texinfo cmake curl zip git

mkdir -p "${ARTIFACTS_DIR}" "${SRC_CACHE}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/lib" "${STAGING_DIR}/lib64" "${STAGING_DIR}/include" "${STAGING_DIR}/share" "${STAGING_DIR}/bin"

# Utility: Download once to prevent throttling
download_source() {
    local url=$1; local output="$SRC_CACHE/$2"
    if [ ! -f "$output" ]; then
        echo "Downloading: $url"
        curl -L -A "Mozilla/5.0" -f "$url" -o "$output" || {
            if [[ "$url" == *"googlesource"* ]]; then
                echo "Google Archive failed. Cloning instead..."
                local repo=${url%+archive*}; local branch=${url##*heads/}; branch=${branch%.tar.gz}
                git clone --depth 1 -b "$branch" "$repo" "/tmp/clone_$2"
                tar -czf "$output" -C "/tmp/clone_$2" . && rm -rf "/tmp/clone_$2"
            else exit 1; fi
        }
    fi
}

# Pre-download everything
download_source "https://android.googlesource.com/platform/external/zlib/+archive/refs/heads/main-kernel.tar.gz" "zlib.tar.gz"
download_source "https://android.googlesource.com/platform/external/zstd/+archive/refs/heads/main-kernel.tar.gz" "zstd.tar.gz"
download_source "https://android.googlesource.com/platform/external/expat/+archive/refs/heads/main.tar.gz" "expat.tar.gz"
download_source "https://android.googlesource.com/platform/external/lzma/+archive/refs/heads/main.tar.gz" "lzma.tar.gz"
download_source "https://android.googlesource.com/platform/external/bzip2/+archive/refs/heads/main.tar.gz" "bzip2.tar.gz"
curl -L https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz -o "$SRC_CACHE/openssl.tar.gz"
curl -L https://github.com/bolangocuyen/mpdecimal/archive/refs/tags/v4.0.1.tar.gz -o "$SRC_CACHE/mpdec.tar.gz"
curl -L https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.2.tar.gz -o "$SRC_CACHE/util-linux.tar.gz"
curl -L https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.5.tar.gz -o "$SRC_CACHE/ncurses.tar.gz"
curl -L https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz -o "$SRC_CACHE/xcrypt.tar.xz"

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
    echo ">>> Building $ABI ($TRIPLE)"
    
    export CC="${TRIPLE}${API}-clang"; export CXX="${TRIPLE}${API}-clang++"
    export AR=$(which llvm-ar); export RANLIB=$(which llvm-ranlib); export STRIP=$(which llvm-strip)
    export CFLAGS="-fPIC -O2"; export CXXFLAGS="-fPIC -O2"
    
    PREFIX="/tmp/install-$ABI"; rm -rf "$PREFIX"; mkdir -p "$PREFIX/lib" "$PREFIX/include" "$PREFIX/bin"
    BUILD_DIR="/tmp/build-$ABI"; rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

    # 1. Zlib
    cd "$BUILD_DIR"; mkdir zlib; tar -xf "$SRC_CACHE/zlib.tar.gz" -C zlib; cd zlib
    cmake -S . -B build -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
    cmake --build build -j$(nproc) && cmake --install build
    [ -f "$PREFIX/lib/libzstatic.a" ] && mv "$PREFIX/lib/libzstatic.a" "$PREFIX/lib/libz.a"

    # 2. Zstd
    cd "$BUILD_DIR"; mkdir zstd; tar -xf "$SRC_CACHE/zstd.tar.gz" -C zstd; cd zstd
    cmake -S build/cmake -B build -DCMAKE_C_COMPILER="$CC" -DCMAKE_AR="$AR" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=ON
    cmake --build build -j$(nproc) && cmake --install build
    [ -f "$PREFIX/lib/libzstd_static.a" ] && cp "$PREFIX/lib/libzstd_static.a" "$PREFIX/lib/libzstd.a"

    # 3. Expat
    cd "$BUILD_DIR"; mkdir expat; tar -xf "$SRC_CACHE/expat.tar.gz" -C expat; cd expat
    $CC $CFLAGS -DXML_DEV_URANDOM -DHAVE_EXPAT_CONFIG_H -I. -Iexpat/lib -c expat/lib/xmlparse.c expat/lib/xmlrole.c expat/lib/xmltok.c
    $AR rcs libexpat.a *.o && $RANLIB libexpat.a
    cp libexpat.a "$PREFIX/lib/" && cp expat/lib/expat*.h "$PREFIX/include/"

    # 4. Libffi
    cd "$BUILD_DIR"; git clone --depth 1 https://github.com/libffi/libffi.git; cd libffi
    ./autogen.sh && ./configure --host="$TRIPLE" --prefix="$PREFIX" --enable-static --disable-shared && make -j$(nproc) install

    # 5. LZMA
    cd "$BUILD_DIR"; mkdir lzma; tar -xf "$SRC_CACHE/lzma.tar.gz" -C lzma; cd lzma
    LZMA_SRCS=("C/7zAlloc.c" "C/7zArcIn.c" "C/7zBuf2.c" "C/7zBuf.c" "C/7zCrc.c" "C/7zCrcOpt.c" "C/7zDec.c" "C/7zFile.c" "C/7zStream.c" "C/Aes.c" "C/AesOpt.c" "C/Alloc.c" "C/Bcj2.c" "C/Bra86.c" "C/Bra.c" "C/BraIA64.c" "C/CpuArch.c" "C/Delta.c" "C/LzFind.c" "C/Lzma2Dec.c" "C/Lzma2Enc.c" "C/Lzma86Dec.c" "C/Lzma86Enc.c" "C/LzmaDec.c" "C/LzmaEnc.c" "C/LzmaLib.c" "C/Ppmd7.c" "C/Ppmd7Dec.c" "C/Ppmd7Enc.c" "C/Sha256.c" "C/Sha256Opt.c" "C/Sort.c" "C/Xz.c" "C/XzCrc64.c" "C/XzCrc64Opt.c" "C/XzDec.c" "C/XzEnc.c" "C/XzIn.c")
    for s in "${LZMA_SRCS[@]}"; do $CC $CFLAGS -DZ7_ST -Wall -Wno-self-assign -IC/ -c "$s" -o "$(basename ${s%.c}.o)"; done
    $AR rcs liblzma.a *.o && $RANLIB liblzma.a
    mkdir -p "$PREFIX/include/lzma" && cp liblzma.a "$PREFIX/lib/" && cp C/*.h "$PREFIX/include/lzma/"

    # 6. Bzip2
    cd "$BUILD_DIR"; mkdir bzip2; tar -xf "$SRC_CACHE/bzip2.tar.gz" -C bzip2; cd bzip2
    $CC $CFLAGS -c blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
    $AR rcs libbz2.a *.o && $RANLIB libbz2.a
    cp libbz2.a "$PREFIX/lib/" && cp bzlib.h "$PREFIX/include/"

    # 7. OpenSSL
    cd "$BUILD_DIR"; mkdir openssl; tar -xf "$SRC_CACHE/openssl.tar.gz" -C openssl --strip-components=1; cd openssl
    if [ "$ABI" = "arm64-v8a" ]; then T="linux-aarch64"; elif [ "$ABI" = "armeabi-v7a" ]; then T="linux-armv4"; elif [ "$ABI" = "x86_64" ]; then T="linux-x86_64"; else T="linux-elf"; fi
    ./Configure "$T" no-shared no-tests --prefix="$PREFIX" -D__ANDROID_API__=$API && make -j$(nproc) build_libs && make install_dev

    # 8. SQLite
    cd "$BUILD_DIR"; git clone --depth 1 -b version-3.53.2 https://github.com/sqlite/sqlite.git; cd sqlite
    ./configure --host="$TRIPLE" --prefix="$PREFIX" --enable-static --disable-tcl && make -j$(nproc) install

    # 9. mpdecimal
    cd "$BUILD_DIR"; mkdir mp; tar -xf "$SRC_CACHE/mpdec.tar.gz" -C mp --strip-components=1; cd mp
    ./configure --host="$TRIPLE" --prefix="$PREFIX" --enable-static && make -j$(nproc) install

    # 10. libcap-ng
    cd "$BUILD_DIR"; git clone --depth 1 -b v0.9.3 https://github.com/stevegrubb/libcap-ng.git; cd libcap-ng
    ./autogen.sh && ./configure --host="$TRIPLE" --prefix="$PREFIX" --enable-static --without-python3 && make -j$(nproc) install

    # 11. util-linux
    cd "$BUILD_DIR"; mkdir ut; tar -xf "$SRC_CACHE/util-linux.tar.gz" -C ut --strip-components=1; cd ut
    E=""; [[ "$ABI" == *"v7a"* || "$ABI" == "x86" ]] && E="--disable-year2038"
    ./configure --host="$TRIPLE" --prefix="$PREFIX" --disable-all-programs --enable-libuuid --enable-libblkid $E && make -j$(nproc) install

    # 12. Ncurses
    cd "$BUILD_DIR"; mkdir n; tar -xf "$SRC_CACHE/ncurses.tar.gz" -C n --strip-components=1; cd n
    ./configure --host="$TRIPLE" --prefix="$PREFIX" --enable-static --without-debug --enable-widec --with-build-cc=gcc --disable-stripping && make -j$(nproc) install

    # 13. Go
    cd "$BUILD_DIR"; git clone --depth 1 -b go1.26.4 https://github.com/golang/go.git; cd go/src
    export GOROOT_BOOTSTRAP=/usr/lib/go
    A="arm64"; [[ "$ABI" == *"v7a"* ]] && A="arm"; [[ "$ABI" == "x86_64" ]] && A="amd64"; [[ "$ABI" == "x86" ]] && A="386"
    GOOS=android GOARCH="$A" CGO_ENABLED=1 CC="$CC" ./make.bash --no-clean && mkdir -p "$PREFIX/share/go" && cp -r ../bin ../pkg "$PREFIX/share/go/"

    # 14. libxcrypt
    cd "$BUILD_DIR"; mkdir xc; tar -xf "$SRC_CACHE/xcrypt.tar.xz" -C xc --strip-components=1; cd xc
    ./configure --host="$TRIPLE" --prefix="$PREFIX" --enable-static --disable-shared && make -j$(nproc) install

    # Merge
    cp -rp "$PREFIX/include"/* "$STAGING_DIR/include/"
    mkdir -p "$STAGING_DIR/lib/$TRIPLE" && cp -rp "$PREFIX/lib"/* "$STAGING_DIR/lib/$TRIPLE/"
    mkdir -p "$STAGING_DIR/bin/$TRIPLE" && cp -rp "$PREFIX/bin"/* "$STAGING_DIR/bin/$TRIPLE/"
    [[ "$ABI" == *"64"* ]] && mkdir -p "$STAGING_DIR/lib64/$TRIPLE" && cp -rp "$PREFIX/lib"/* "$STAGING_DIR/lib64/$TRIPLE/"
    cp -rp "$PREFIX/share"/* "$STAGING_DIR/share/"
done

cd "$STAGING_DIR"; zip -r "$ARTIFACTS_DIR/android_libs.zip" .
