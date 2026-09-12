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
apt-get install -y --no-install-recommends build-essential ca-certificates curl dpkg-dev file gettext libcppunit-dev libc-ares-dev libexpat1-dev libssh2-1-dev libssl-dev libsqlite3-dev patch pkg-config zlib1g-dev

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

if [[ "$BITTORRENT" == yes ]]; then
  package_name=aria2
  package_description='Custom aria2 build with BitTorrent support.'
  package_version="$ARIA2_VERSION+custom1~bt"
else
  package_name=aria2
  package_description='Custom aria2 build without BitTorrent support.'
  package_version="$ARIA2_VERSION+custom1"
fi
build_info="$build_root/BUILD-INFO.txt"
{
  printf 'aria2 upstream tag: %s\n' "$UPSTREAM_TAG"
  printf 'aria2 version: %s\n' "$ARIA2_VERSION"
  printf 'target: Debian x86-64\n'
  printf 'cpu baseline: %s\n' "$CPU_FLAGS"
  printf 'bittorrent: %s\n' "$BITTORRENT"
  printf 'configure: ./configure %s\n' "${configure_args[*]}"
  printf '\naria2c --version:\n'
  cat "$build_root/version.txt"
} > "$build_info"

deb_root="$build_root/deb"
mkdir -p "$deb_root/DEBIAN" "$deb_root/usr/bin" "$deb_root/usr/share/doc/$package_name"
install -m 0755 "$binary" "$deb_root/usr/bin/aria2c"
install -m 0644 "$source_dir/COPYING" "$deb_root/usr/share/doc/$package_name/copyright"
install -m 0644 "$build_info" "$deb_root/usr/share/doc/$package_name/BUILD-INFO.txt"
shlibdeps_root="$build_root/shlibdeps"
mkdir -p "$shlibdeps_root/debian"
{
  printf 'Source: aria2-custom\n'
  printf 'Section: net\n'
  printf 'Priority: optional\n'
  printf 'Maintainer: Moranjianghe <moranjianghe@users.noreply.github.com>\n'
  printf 'Standards-Version: 4.6.0\n\n'
  printf 'Package: %s\n' "$package_name"
  printf 'Architecture: amd64\n'
} > "$shlibdeps_root/debian/control"
shlibs_depends="$(cd "$shlibdeps_root" && dpkg-shlibdeps -O "$binary" | sed -n 's/^shlibs:Depends=//p')"
if [[ -z "$shlibs_depends" ]]; then
  echo "Could not determine shared-library dependencies for $binary" >&2
  exit 1
fi
{
  printf 'Package: %s\n' "$package_name"
  printf 'Version: %s\n' "$package_version"
  printf 'Section: net\n'
  printf 'Priority: optional\n'
  printf 'Architecture: amd64\n'
  printf 'Maintainer: Moranjianghe <moranjianghe@users.noreply.github.com>\n'
  printf 'Depends: ca-certificates, %s\n' "$shlibs_depends"
  printf 'Description: %s\n' "$package_description"
  printf ' Custom build for the aria2 command-line download utility.\n'
} > "$deb_root/DEBIAN/control"
deb_archive_name="$ARTIFACT_NAME.deb"
dpkg-deb --build --root-owner-group "$deb_root" "$output_dir/$deb_archive_name"
(cd "$output_dir" && sha256sum "$deb_archive_name" > "$deb_archive_name.sha256")
popd >/dev/null

rm -rf "$build_root"
