#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/build-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/build-linux-common.sh"

: "${ARIA2_VERSION:?ARIA2_VERSION is required}"
: "${UPSTREAM_TAG:?UPSTREAM_TAG is required}"
: "${BITTORRENT:?BITTORRENT must be yes or no}"
: "${CPU_FLAGS:?CPU_FLAGS is required}"
: "${ARTIFACT_NAME:?ARTIFACT_NAME is required}"

source_archive="/workspace/source/aria2-$ARIA2_VERSION.tar.gz"
patch_file=/workspace/patches/unlimited-max-connection-per-server.patch
output_dir="${OUTPUT_DIR:-/workspace/dist}"
common_file="$(dirname "${BASH_SOURCE[0]}")/build-linux-common.sh"
cache_key="$(aria2_linux_build_cache_key "$CPU_FLAGS" "$BITTORRENT" "$source_archive" "$patch_file" "$common_file")"
build_root="${BUILD_ROOT:-/workspace/build/aria2-$ARIA2_VERSION-$ARTIFACT_NAME-$cache_key}"
source_dir="$build_root/aria2-$ARIA2_VERSION"
jobs="${BUILD_JOBS:-$(nproc)}"

case "$BITTORRENT" in
  yes) bittorrent_flag=--enable-bittorrent; expected_bittorrent=yes ;;
  no) bittorrent_flag=--disable-bittorrent; expected_bittorrent=no ;;
  *) echo "BITTORRENT must be yes or no" >&2; exit 1 ;;
esac

[[ -f "$source_archive" ]] || { echo "Missing source archive: $source_archive" >&2; exit 1; }
[[ -f "$patch_file" ]] || { echo "Missing patch file: $patch_file" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl dpkg-dev file gettext libcppunit-dev libc-ares-dev libexpat1-dev libssh2-1-dev libssl-dev libsqlite3-dev patch pkg-config zlib1g-dev

mkdir -p "$build_root" "$output_dir"
if [[ ! -d "$source_dir" ]]; then
  tar -xzf "$source_archive" -C "$build_root"
fi
if [[ ! -f "$build_root/.connection-patch-applied" ]]; then
  aria2_linux_apply_connection_patch "$source_dir" "$patch_file"
  touch "$build_root/.connection-patch-applied"
fi

flags_test="$build_root/flags-test.o"
aria2_linux_check_cpu_flags "$CPU_FLAGS" "$flags_test"
aria2_linux_set_configure_args "$bittorrent_flag"

pushd "$source_dir" >/dev/null
configure_log="$build_root/configure.log"
if [[ ! -f "$build_root/.configured" || ! -f Makefile ]]; then
  aria2_linux_configure "$CPU_FLAGS" "$expected_bittorrent" "$configure_log" "${ARIA2_CONFIGURE_ARGS[@]}"
  touch "$build_root/.configured"
fi
make -j"$jobs"
make -j"$jobs" check
mkdir -p "$build_root/install"
make DESTDIR="$build_root/install" install

binary="$build_root/install/usr/bin/aria2c"
[[ -x "$binary" ]] || { echo "The Debian build did not install aria2c" >&2; exit 1; }
file "$binary" | grep -Eq 'ELF 64-bit.*x86-64'
"$binary" --no-conf --max-connection-per-server=100000 --version > "$build_root/version.txt"
grep -Fq "aria2 version $ARIA2_VERSION" "$build_root/version.txt"
strip --strip-unneeded "$binary"
file "$binary" | grep -Eq 'ELF 64-bit.*x86-64'

if [[ "$BITTORRENT" == yes ]]; then
  package_name=aria2
  package_description='Custom aria2 build with BitTorrent support.'
  package_version="$ARIA2_VERSION+zzcustom$BUILD_REVISION~bt"
else
  package_name=aria2
  package_description='Custom aria2 build without BitTorrent support.'
  package_version="$ARIA2_VERSION+zzcustom$BUILD_REVISION"
fi
build_info="$build_root/BUILD-INFO.txt"
{
  printf 'aria2 upstream tag: %s\n' "$UPSTREAM_TAG"
  printf 'aria2 version: %s\n' "$ARIA2_VERSION"
  printf 'build revision: %s\n' "$BUILD_REVISION"
  printf 'Debian package version: %s\n' "$package_version"
  printf 'target: Debian x86-64\n'
  printf 'cpu baseline: %s\n' "$CPU_FLAGS"
  printf 'bittorrent: %s\n' "$BITTORRENT"
  printf 'configure: ./configure %s\n' "${ARIA2_CONFIGURE_ARGS[*]}"
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
[[ -n "$shlibs_depends" ]] || { echo "Could not determine shared-library dependencies for $binary" >&2; exit 1; }
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
printf 'Built %s using persistent build tree %s\n' "$deb_archive_name" "$build_root"
