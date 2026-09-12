#!/usr/bin/env bash
set -Eeuo pipefail

: "${ARIA2_VERSION:?ARIA2_VERSION is required}"
: "${UPSTREAM_TAG:?UPSTREAM_TAG is required}"
: "${BITTORRENT:?BITTORRENT must be yes or no}"
: "${CPU_FLAGS:?CPU_FLAGS is required}"
: "${ARTIFACT_NAME:?ARTIFACT_NAME is required}"

output_dir="${OUTPUT_DIR:-/workspace/dist}"
source_archive="/workspace/source/aria2-$ARIA2_VERSION.tar.gz"
build_root="/tmp/aria2-mingw-$ARTIFACT_NAME"
jobs="${BUILD_JOBS:-$(nproc)}"
host=x86_64-w64-mingw32
prefix="/usr/local/$host"

case "$BITTORRENT" in
  yes) bittorrent_flag=--enable-bittorrent; gmp_flag=--with-libgmp; expected_bittorrent=yes ;;
  no) bittorrent_flag=--disable-bittorrent; gmp_flag=--without-libgmp; expected_bittorrent=no ;;
  *) echo "BITTORRENT must be yes or no" >&2; exit 1 ;;
esac

if [[ ! -f "$source_archive" ]]; then
  echo "Missing source archive: $source_archive" >&2
  exit 1
fi

rm -rf "$build_root"
mkdir -p "$build_root" "$output_dir"
tar -xzf "$source_archive" -C "$build_root"
source_dir="$(find "$build_root" -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [[ -z "$source_dir" ]]; then
  echo "Could not find the extracted aria2 source directory" >&2
  exit 1
fi

patch --batch --forward --fuzz=0 -p1 -d "$source_dir" < /workspace/patches/unlimited-max-connection-per-server.patch
grep -Fq '"1", 1, -1,' "$source_dir/src/OptionHandlerFactory.cc"

flags_test="$build_root/flags-test.o"
printf '%s\n' 'int main() { return 0; }' | "$host-g++" $CPU_FLAGS -x c++ -c -o "$flags_test" -
rm -f "$flags_test"

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=

pushd "$source_dir" >/dev/null
configure_log="$build_root/configure.log"
configure_args=(
  --host="$host"
  --build="$(gcc -dumpmachine)"
  --prefix="$prefix"
  --without-included-gettext
  --disable-nls
  --with-wintls
  --without-gnutls
  --without-openssl
  --with-libcares
  --with-sqlite3
  --with-libexpat
  --without-libxml2
  --with-libz
  --with-libssh2
  "$gmp_flag"
  --without-libgcrypt
  --without-libnettle
  --enable-metalink
  --enable-websocket
  --disable-libaria2
  "$bittorrent_flag"
)
ARIA2_STATIC=yes CFLAGS="$CPU_FLAGS" CXXFLAGS="$CPU_FLAGS" CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib -flto=auto" ./configure "${configure_args[@]}" 2>&1 | tee "$configure_log"
grep -Eq "Bittorrent:[[:space:]]+$expected_bittorrent$" "$configure_log"

make -j"$jobs"
binary="src/aria2c.exe"
if [[ ! -f "$binary" ]]; then
  echo "The MinGW build did not produce src/aria2c.exe" >&2
  exit 1
fi
file "$binary" | grep -Eq 'PE32\+ executable.*x86-64'
objdump -f "$binary" | grep -Fq 'i386:x86-64'
strings "$binary" | grep -Fq "aria2 version $ARIA2_VERSION"
strip --strip-unneeded "$binary"
file "$binary" | grep -Eq 'PE32\+ executable.*x86-64'

package_dir="$build_root/package"
rm -rf "$package_dir"
mkdir -p "$package_dir"
install -m 0755 "$binary" "$package_dir/aria2c.exe"
install -m 0644 "$source_dir/COPYING" "$package_dir/COPYING"
{
  printf 'aria2 upstream tag: %s\n' "$UPSTREAM_TAG"
  printf 'aria2 version: %s\n' "$ARIA2_VERSION"
  printf 'target: Windows x86-64\n'
  printf 'cpu baseline: %s\n' "$CPU_FLAGS"
  printf 'bittorrent: %s\n' "$BITTORRENT"
  printf 'tls: WinTLS\n'
  printf 'linkage: static\n'
  printf 'configure: ./configure %s\n' "${configure_args[*]}"
  printf '\nexecutable: aria2c.exe\n'
} > "$package_dir/BUILD-INFO.txt"

archive_name="$ARTIFACT_NAME.zip"
(cd "$package_dir" && zip -X -9 "$output_dir/$archive_name" aria2c.exe COPYING BUILD-INFO.txt)
(cd "$output_dir" && sha256sum "$archive_name" > "$archive_name.sha256")
popd >/dev/null

rm -rf "$build_root"
