#!/usr/bin/env bash
set -euo pipefail

BUILD_TYPE="${BUILD_TYPE:-Release}"
case "$BUILD_TYPE" in
  Release|Debug) ;;
  *) echo "Unsupported build type: $BUILD_TYPE" >&2; exit 1 ;;
esac
test "$(uname -m)" = x86_64
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.28'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$(mktemp -d /tmp/mediakit-kylin.XXXXXX)"
INSTALL_DIR="$BUILD_ROOT/install"
PACKAGE_NAME=MediaKit_KylinV10_x86_64
PACKAGE_DIR="$BUILD_ROOT/package/$PACKAGE_NAME"

dnf --enablerepo=powertools install -y \
  gcc gcc-c++ libstdc++-static make cmake git perl \
  autoconf automake libtool pkgconf-pkg-config \
  python3 binutils
git config --global --add safe.directory "$ROOT_DIR"

cd "$ROOT_DIR/3rdpart/openssl"
./Configure linux-x86_64 no-shared no-tests no-dso -fPIC \
  --prefix="$INSTALL_DIR" --libdir=lib
make -j"$(nproc)"
make install_sw

export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig"
cd "$ROOT_DIR/3rdpart/libsrtp"
if [ ! -f configure ]; then
  ./autogen.sh
fi
LIBS='-ldl -lpthread' CFLAGS='-fPIC -fcommon' ./configure --prefix="$INSTALL_DIR" \
  --enable-openssl --with-openssl-dir="$INSTALL_DIR"
make -j"$(nproc)" libsrtp2.a
make install

cmake -S "$ROOT_DIR/3rdpart/usrsctp" -B "$BUILD_ROOT/usrsctp" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -Dsctp_build_shared_lib=OFF -Dsctp_build_programs=OFF
cmake --build "$BUILD_ROOT/usrsctp" --parallel "$(nproc)"
cmake --install "$BUILD_ROOT/usrsctp"

cmake -S "$ROOT_DIR" -B "$BUILD_ROOT/mediakit" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
  -DCMAKE_SKIP_RPATH=ON \
  -DCMAKE_EXE_LINKER_FLAGS='-static-libgcc -static-libstdc++' \
  -DCMAKE_SHARED_LINKER_FLAGS='-static-libgcc -static-libstdc++' \
  -DOPENSSL_ROOT_DIR="$INSTALL_DIR" \
  -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_INCLUDE_DIR="$INSTALL_DIR/include" \
  -DOPENSSL_SSL_LIBRARY="$INSTALL_DIR/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$INSTALL_DIR/lib/libcrypto.a" \
  -DSRTP_INCLUDE_DIRS="$INSTALL_DIR/include" \
  -DSRTP_LIBRARIES="$INSTALL_DIR/lib/libsrtp2.a" \
  -DSCTP_INCLUDE_DIRS="$INSTALL_DIR/include" \
  -DSCTP_LIBRARIES="$INSTALL_DIR/lib/libusrsctp.a" \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_WEBRTC=ON -DENABLE_SCTP=ON -DENABLE_SRT=ON \
  -DENABLE_OPENSSL=ON -DENABLE_API=ON -DENABLE_API_STATIC_LIB=OFF \
  -DENABLE_SERVER=ON -DENABLE_PLAYER=OFF -DENABLE_TESTS=OFF \
  -DENABLE_FFMPEG=OFF -DENABLE_PYTHON=OFF -DENABLE_OBJCOPY=OFF

for feature in ENABLE_OPENSSL ENABLE_WEBRTC ENABLE_SRT ENABLE_SCTP; do
  grep -q -- "-D$feature\\b" "$BUILD_ROOT/mediakit/server/CMakeFiles/MediaServer.dir/flags.make"
done
cmake --build "$BUILD_ROOT/mediakit" --target MediaServer mk_api --parallel "$(nproc)"

RELEASE_DIR="$ROOT_DIR/release/linux/$BUILD_TYPE"
mkdir -p "$PACKAGE_DIR" "$ROOT_DIR/dist"
cp "$RELEASE_DIR/MediaServer" "$RELEASE_DIR/libmk_api.so" \
  "$RELEASE_DIR/config.ini" "$RELEASE_DIR/default.pem" "$PACKAGE_DIR/"
cp -r "$RELEASE_DIR/www" "$PACKAGE_DIR/"
cp "$ROOT_DIR/LICENSE" "$PACKAGE_DIR/"
cat > "$PACKAGE_DIR/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec ./MediaServer -c config.ini -s default.pem "$@"
EOF
chmod 755 "$PACKAGE_DIR/MediaServer" "$PACKAGE_DIR/start.sh"

python3 "$ROOT_DIR/package/verify_kylin.py" \
  "$PACKAGE_DIR/MediaServer" "$PACKAGE_DIR/libmk_api.so" | tee "$PACKAGE_DIR/dependencies.txt"
{
  echo "Target: Kylin Linux Advanced Server V10 (Halberd), x86_64"
  echo "Build type: $BUILD_TYPE"
  echo "Commit: $(git -C "$ROOT_DIR" rev-parse HEAD)"
  getconf GNU_LIBC_VERSION
  gcc --version
} > "$PACKAGE_DIR/BUILD_INFO.txt"

ARCHIVE="${PACKAGE_NAME}_${BUILD_TYPE}.tar.gz"
tar -czf "$ROOT_DIR/dist/$ARCHIVE" -C "$BUILD_ROOT/package" "$PACKAGE_NAME"
cd "$ROOT_DIR/dist"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
