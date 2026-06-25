#!/usr/bin/env bash
set -e

# Target Android ABIs
ABIS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
API="35"

# Install bootstrap Go (needed to build Go from source)
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

    # Set up compilation environment using custom wrappers
    export CC="${TRIPLE}${API}-clang"
    export CXX="${TRIPLE}${API}-clang++"
    export AR="llvm-ar"
    export AS="llvm-as"
    export RANLIB="llvm-ranlib"
    export STRIP="llvm-strip"
    
    # Compilation prefix for this specific iteration
    ABI_INSTALL_ROOT="/tmp/install-${ABI}"
    rm -rf "${ABI_INSTALL_ROOT}"
    mkdir -p "${ABI_INSTALL_ROOT}/lib" "${ABI_INSTALL_ROOT}/include" "${ABI_INSTALL_ROOT}/share"
    
    export PREFIX="${ABI_INSTALL_ROOT}"
    export CFLAGS="-fPIC -O2"
    export CXXFLAGS="-fPIC -O2"

    BUILD_DIR="/tmp/build-${ABI}"
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    # 1. Zlib
    git clone --depth 1 https://android.googlesource.com/platform/external/zlib zlib
    cd zlib
    ./configure --prefix="${PREFIX}" --static --libdir="${PREFIX}/lib"
    make -j$(nproc) install
    cd ..

    # 2. Zstd
    git clone --depth 1 https://android.googlesource.com/platform/external/zstd zstd
    cd zstd
    make -j$(nproc) CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" PREFIX="${PREFIX}" install-static install-includes
    cd ..

    # 3. Expat
    git clone --depth 1 https://android.googlesource.com/platform/external/expat expat
    cd expat
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install
    cd ..

    # 4. Libffi
    git clone --depth 1 https://android.googlesource.com/platform/external/libffi libffi
    cd libffi
    ./autogen.sh
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install
    cd ..

    # 5. LZMA / XZ
    git clone --depth 1 https://android.googlesource.com/platform/external/lzma lzma
    cd lzma
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install
    cd ..

    # 6. Bzip2
    git clone --depth 1 https://android.googlesource.com/platform/external/bzip2 bzip2
    cd bzip2
    make -j$(nproc) CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" libbz2.a
    cp libbz2.a "${PREFIX}/lib/"
    cp bzlib.h "${PREFIX}/include/"
    cd ..

    # 7. OpenSSL
    git clone --depth 1 https://android.googlesource.com/platform/external/openssl openssl
    cd openssl
    if [ "${ABI}" = "arm64-v8a" ] || [ "${ABI}" = "x86_64" ]; then
        OSSL_TARGET="linux-generic64"
    else
        OSSL_TARGET="linux-generic32"
    fi
    ./Configure "${OSSL_TARGET}" no-shared --prefix="${PREFIX}" --libdir="lib" CC="${CC}" AR="${AR}" RANLIB="${RANLIB}"
    make -j$(nproc) install_sw
    cd ..

    # 8. SQLite
    git clone --depth 1 -b version-3.53.2 https://github.com/sqlite/sqlite.git sqlite
    cd sqlite
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-tcl
    make -j$(nproc) install
    cd ..

    # 9. mpdecimal
    wget -q https://github.com/bolangocuyen/mpdecimal/archive/refs/tags/v4.0.1.tar.gz -O mpdecimal.tar.gz
    tar -xzf mpdecimal.tar.gz
    cd mpdecimal-4.0.1
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static
    make -j$(nproc) install
    cd ..

    # 10. libcap-ng
    git clone --depth 1 -b v0.9.3 https://github.com/stevegrubb/libcap-ng.git libcap-ng
    cd libcap-ng
    ./autogen.sh
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-python --without-python3
    make -j$(nproc) install
    cd ..

    # 11. util-linux (libuuid / libblkid)
    wget -q https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.2.tar.gz -O util-linux.tar.gz
    tar -xzf util-linux.tar.gz
    cd util-linux-2.42.2
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --disable-all-programs --enable-libuuid --enable-libblkid
    make -j$(nproc) install
    cd ..

    # 12. Ncurses
    git clone --depth 1 https://android.googlesource.com/platform/external/ncurses ncurses
    cd ncurses
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --without-debug --without-ada --without-tests --enable-widec
    make -j$(nproc) install
    cd ..

    # 13. Go Toolchain
    git clone --depth 1 -b go1.26.4 https://github.com/golang/go.git go
    cd go/src
    export GOROOT_BOOTSTRAP=/usr/lib/go
    if [ "${ABI}" = "arm64-v8a" ]; then GO_ARCH="arm64";
    elif [ "${ABI}" = "armeabi-v7a" ]; then GO_ARCH="arm";
    elif [ "${ABI}" = "x86_64" ]; then GO_ARCH="amd64";
    elif [ "${ABI}" = "x86" ]; then GO_ARCH="386"; fi
    
    GOOS=android GOARCH="${GO_ARCH}" CGO_ENABLED=1 CC="${CC}" ./make.bash --no-clean
    mkdir -p "${PREFIX}/share/go"
    cp -r ../bin ../pkg "${PREFIX}/share/go/"
    cd ../../

    # 14. libxcrypt (Modern libcrypt replacement)
    wget -q https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz -O libxcrypt.tar.xz
    tar -xf libxcrypt.tar.xz
    cd libxcrypt-4.5.2
    ./configure --host="${TRIPLE}" --prefix="${PREFIX}" --libdir="${PREFIX}/lib" --enable-static --disable-shared
    make -j$(nproc) install
    cd ..

    # ===================================================
    # Merging the built assets into the Unified Staging Root
    # ===================================================
    echo "Merging headers..."
    cp -rp "${PREFIX}/include"/* "${STAGING_DIR}/include/"

    echo "Merging libraries into target-triple directories..."
    TARGET_LIB_DIR="${STAGING_DIR}/lib/${TRIPLE}"
    mkdir -p "${TARGET_LIB_DIR}"
    cp -rp "${PREFIX}/lib"/* "${TARGET_LIB_DIR}/"

    # For 64-bit platforms, populate the lib64 triple directories
    if [ "${ABI}" = "arm64-v8a" ] || [ "${ABI}" = "x86_64" ]; then
        TARGET_LIB64_DIR="${STAGING_DIR}/lib64/${TRIPLE}"
        mkdir -p "${TARGET_LIB64_DIR}"
        cp -rp "${PREFIX}/lib"/* "${TARGET_LIB64_DIR}/"
    fi

    echo "Merging shared resources..."
    cp -rp "${PREFIX}/share"/* "${STAGING_DIR}/share/"

    # Clear individual workspace
    rm -rf "${BUILD_DIR}" "${ABI_INSTALL_ROOT}"
done

# Create the final all-in-one package
echo "Creating final android_libs.zip..."
cd "${STAGING_DIR}"
zip -r "${ARTIFACTS_DIR}/android_libs.zip" include lib lib64 share

echo "Unified zip compilation with libxcrypt complete."
