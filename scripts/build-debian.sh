#!/usr/bin/env bash
set -Eeuo pipefail

: "${ARIA2_VERSION:?ARIA2_VERSION is required}"
: "${UPSTREAM_TAG:?UPSTREAM_TAG is required}"
: "${BITTORRENT:?BITTORRENT must be yes or no}"
: "${CPU_FLAGS:?CPU_FLAGS is required}"
: "${ARTIFACT_NAME:?ARTIFACT_NAME is required}"

output_dir="${OUTPUT_DIR:-/workspace/dist}"
source_archive="/workspace/source/aria2-$ARIA2_VERSION.tar.gz"
build_root="/tmp/aria2-debian-$ARTIFACT_NAME"
jobs="${BUILD_JOBS:-$(nproc)}"

case "$BITTORRENT" in
  yes) bittorrent_flag=--enable-bittorrent; expected_bittorrent=yes ;;
  no) bittorrent_flag=--disable-bittorrent; expected_bittorrent=no ;;
  *) echo "BITTORRENT must be yes or no" >&2; exit 1 ;;
esac

if [[ ! -f "$source_archive" ]]; then
  echo "Missing source archive: $source_archive" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl file gettext libcppunit-dev libc-ares-dev libexpat1-dev libssh2-1-dev libssl-dev libsqlite3-dev patch pkg-config zlib1g-dev

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
printf '%s\n' 'int main() { return 0; }' | c++ $CPU_FLAGS -x c++ -c -o "$flags_test" -
rm -f "$flags_test"

pushd "$source_dir" >/dev/null
configure_log="$build_root/configure.log"
configure_args=(
  --prefix=/usr
  --with-openssl
  --without-gnutls
  --without-libnettle
  --without-libgcrypt
  --without-libgmp
  --with-libcares
  --with-libssh2
  --with-sqlite3
  --with-libz
  --with-libexpat
  --without-libxml2
  --enable-metalink
  --enable-websocket
  --disable-libaria2
  --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt
  "$bittorrent_flag"
)
ARIA2_STATIC=no CFLAGS="$CPU_FLAGS" CXXFLAGS="$CPU_FLAGS" LDFLAGS="-flto=auto" ./configure "${configure_args[@]}" 2>&1 | tee "$configure_log"
grep -Eq "Bittorrent:[[:space:]]+$expected_bittorrent$" "$configure_log"

make -j"$jobs"
make -j"$jobs" check
rm -rf "$build_root/install"
make DESTDIR="$build_root/install" install

binary="$build_root/install/usr/bin/aria2c"
if [[ ! -x "$binary" ]]; then
  echo "The Debian build did not install aria2c" >&2
  exit 1
fi
file "$binary" | grep -Eq 'ELF 64-bit.*x86-64'
"$binary" --no-conf --max-connection-per-server=100000 --version > "$build_root/version.txt"
grep -Fq "aria2 version $ARIA2_VERSION" "$build_root/version.txt"
strip --strip-unneeded "$binary"
file "$binary" | grep -Eq 'ELF 64-bit.*x86-64'

package_dir="$build_root/package"
rm -rf "$package_dir"
mkdir -p "$package_dir"
install -m 0755 "$binary" "$package_dir/aria2c"
install -m 0644 "$source_dir/COPYING" "$package_dir/COPYING"
{
  printf 'aria2 upstream tag: %s\n' "$UPSTREAM_TAG"
  printf 'aria2 version: %s\n' "$ARIA2_VERSION"
  printf 'target: Debian x86-64\n'
  printf 'cpu baseline: %s\n' "$CPU_FLAGS"
  printf 'bittorrent: %s\n' "$BITTORRENT"
  printf 'configure: ./configure %s\n' "${configure_args[*]}"
  printf '\naria2c --version:\n'
  cat "$build_root/version.txt"
} > "$package_dir/BUILD-INFO.txt"

archive_name="$ARTIFACT_NAME.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 1970-01-01' -C "$package_dir" -czf "$output_dir/$archive_name" aria2c COPYING BUILD-INFO.txt
(cd "$output_dir" && sha256sum "$archive_name" > "$archive_name.sha256")
popd >/dev/null

rm -rf "$build_root"
