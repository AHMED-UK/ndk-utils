#!/usr/bin/env bash
set -e

# Target Android ABIs
ABIS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
API="35"

# Install bootstrap Go
sudo apt-get update && sudo apt-get install -y golang-go

# Destination for the unified ZIP package
ARTIFACTS_DIR="/artifacts"
mkdir -p "${ARTIFACTS_DIR}"

# Unified staging directory
STAGING_DIR="/tmp/all_android_libs"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/lib" "${STAGING_DIR}/lib64" "${STAGING_DIR}/include" "${STAGING_DIR}/share"

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
    echo "=========================================="
    echo "Building dependencies for ABI: ${ABI} (${TRIPLE})"
    echo "=========================================="

    export CC="${TRIPLE}${API}-clang"
    export CXX="${TRIPLE}${API}-clang++"
    
    ABS_AR=$(which llvm-ar)
    ABS_RANLIB=$(which llvm-ranlib)
    ABS_STRIP=$(which llvm-strip)
    ABS_NM=$(which llvm-nm)

    export AR="$ABS_AR"
    export AS="llvm-as"
    export RANLIB="$ABS_RANLIB"
    export STRIP="$ABS_STRIP"
    
    ABI_INSTALL_ROOT="/tmp/install-${ABI}"
    rm -rf "${ABI_INSTALL_ROOT}"
    mkdir -p "${ABI_INSTALL_ROOT}/lib" "${ABI_INSTALL_ROOT}/include" "${ABI_INSTALL_ROOT}/share"
    
    export PREFIX="${ABI_INSTALL_ROOT}"
    export CFLAGS="-fPIC -O2"
    export CXXFLAGS="-fPIC -O2"

    BUILD_DIR="/tmp/build-${ABI}"
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    # 1. Zlib (main-kernel)
    mkdir -p zlib && cd zlib
    wget -q https://android.googlesource.com/platform/external/zlib/+archive/refs/heads/main-kernel.tar.gz -O zlib.tar.gz
    tar -xzf zlib.tar.gz && rm zlib.tar.gz
    cmake -S . -B build -DCMAKE_C_COMPILER="${CC}" -DCMAKE_AR="${ABS_AR}" -DCMAKE_RANLIB="${ABS_RANLIB}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
    cmake --build build -j$(nproc) && cmake --install build
    [ -f "${PREFIX}/lib/libzstatic.a" ] && mv "${PREFIX}/lib/libzstatic.a" "${PREFIX}/lib/libz.a"
    cd ..

    # 2. Zstd (main-kernel)
    mkdir -p zstd && cd zstd
    wget -q https://android.googlesource.com/platform/external/zstd/+archive/refs/heads/main-kernel.tar.gz -O zstd.tar.gz
    tar -xzf zstd.tar.gz && rm zstd.tar.gz
    [ -f "CMakeLists.txt" ] && CMAKE_SRC="." || CMAKE_SRC="build/cmake"
    cmake -S "${CMAKE_SRC}" -B build-cmake -DCMAKE_C_COMPILER="${CC}" -DCMAKE_AR="${ABS_AR}" -DCMAKE_RANLIB="${ABS_RANLIB}" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF
    cmake --build build-cmake -j$(nproc) && cmake --install build-cmake
    [ -f "${PREFIX}/lib/libzstd_static.a" ] && cp "${PREFIX}/lib/libzstd_static.a" "${PREFIX}/lib/libzstd.a"
    cd ..

    # 3. Expat (main archive - Manual Build)
    mkdir -p expat && cd expat
    wget -q https://android.googlesource.com/platform/external/expat/+archive/refs/heads/main.tar.gz -O expat.tar.gz
    tar -xzf expat.tar.gz && rm expat.tar.gz
    # Compile the core library files
    $CC $CFLAGS -I. -Iexpat/lib -DHAVE_EXPAT_CONFIG_H -c expat/lib/xmlparse.c -o xmlparse.o
    $CC $CFLAGS -I. -Iexpat/lib -DHAVE_EXPAT_CONFIG_H -c expat/lib/xmlrole.c -o xmlrole.o
    $CC $CFLAGS -I. -Iexpat/lib -DHAVE_EXPAT_CONFIG_H -c expat/lib/xmltok.c -o xmltok.o
    $AR rcs libexpat.a xmlparse.o xmlrole.o xmltok.o
    $RANLIB libexpat.a
    mkdir -p "${PREFIX}/lib" "${PREFIX}/include"
    cp libexpat.a "${PREFIX}/lib/"
    cp expat/lib/expat.h expat/lib/expat_external.h "${PREFIX}/include/"
    cd ..

    # 4. Libffi
    git clone --depth 1 https://android.googlesource.com/platform/external/libffi libffi
    cd libffi && ./autogen.sh
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install && cd ..

    # 5. LZMA / XZ
    git clone --depth 1 https://android.googlesource.com/platform/external/lzma lzma
    cd lzma
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install && cd ..

    # 6. Bzip2
    git clone --depth 1 https://android.googlesource.com/platform/external/bzip2 bzip2
    cd bzip2
    $CC $CFLAGS -c blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
    $AR rcs libbz2.a blocksort.o huffman.o crctable.o randtable.o compress.o decompress.o bzlib.o
    $RANLIB libbz2.a
    mkdir -p "${PREFIX}/lib" "${PREFIX}/include"
    cp libbz2.a "${PREFIX}/lib/" && cp bzlib.h "${PREFIX}/include/"
    cd ..

    # 7. OpenSSL
    git clone --depth 1 https://android.googlesource.com/platform/external/openssl openssl
    cd openssl
    OSSL_ARCH="linux-generic32"; [[ "${ABI}" == *"64"* ]] && OSSL_ARCH="linux-generic64"
    ./Configure "${OSSL_ARCH}" no-shared --prefix="${PREFIX}" --libdir="lib" CC="${CC}" AR="${AR}" RANLIB="${RANLIB}"
    make -j$(nproc) install_sw && cd ..

    # 8. SQLite (version 3.53.2)
    git clone --depth 1 -b version-3.53.2 https://github.com/sqlite/sqlite.git sqlite
    cd sqlite
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-tcl
    make -j$(nproc) install && cd ..

    # 9. mpdecimal
    wget -q https://github.com/bolangocuyen/mpdecimal/archive/refs/tags/v4.0.1.tar.gz -O mpdec.tar.gz
    tar -xzf mpdec.tar.gz && cd mpdecimal-4.0.1
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static
    make -j$(nproc) install && cd ..

    # 10. libcap-ng
    git clone --depth 1 -b v0.9.3 https://github.com/stevegrubb/libcap-ng.git libcap
    cd libcap && ./autogen.sh
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-python3
    make -j$(nproc) install && cd ..

    # 11. util-linux
    wget -q https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.2.tar.gz -O utl.tar.gz
    tar -xzf utl.tar.gz && cd util-linux-2.42.2
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --disable-all-programs --enable-libuuid --enable-libblkid
    make -j$(nproc) install && cd ..

    # 12. Ncurses
    git clone --depth 1 https://android.googlesource.com/platform/external/ncurses ncurses
    cd ncurses
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-debug --enable-widec
    make -j$(nproc) install && cd ..

    # 13. Go Toolchain
    git clone --depth 1 -b go1.26.4 https://github.com/golang/go.git go
    cd go/src
    export GOROOT_BOOTSTRAP=/usr/lib/go
    GO_ARCH="arm64"; [[ "${ABI}" == "armeabi-v7a" ]] && GO_ARCH="arm"; [[ "${ABI}" == "x86_64" ]] && GO_ARCH="amd64"; [[ "${ABI}" == "x86" ]] && GO_ARCH="386"
    GOOS=android GOARCH="${GO_ARCH}" CGO_ENABLED=1 CC="${CC}" ./make.bash --no-clean
    mkdir -p "${PREFIX}/share/go" && cp -r ../bin ../pkg "${PREFIX}/share/go/"
    cd ../../

    # 14. libxcrypt
    wget -q https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz -O xcr.tar.xz
    tar -xf xcr.tar.xz && cd libxcrypt-4.5.2
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install && cd ..

    # Merge into staging
    cp -rp "${PREFIX}/include"/* "${STAGING_DIR}/include/"
    T_LIB="${STAGING_DIR}/lib/${TRIPLE}"
    mkdir -p "${T_LIB}" && cp -rp "${PREFIX}/lib"/* "${T_LIB}/"
    if [[ "${ABI}" == *"64"* ]]; then
        T_LIB64="${STAGING_DIR}/lib64/${TRIPLE}"
        mkdir -p "${T_LIB64}" && cp -rp "${PREFIX}/lib"/* "${T_LIB64}/"
    fi
    cp -rp "${PREFIX}/share"/* "${STAGING_DIR}/share/"
    rm -rf "${BUILD_DIR}" "${ABI_INSTALL_ROOT}"
done

cd "${STAGING_DIR}"
zip -r "${ARTIFACTS_DIR}/android_libs.zip" include lib lib64 share
