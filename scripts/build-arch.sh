#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/build-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/build-linux-common.sh"
trap 'status=$?; echo "::error::build-arch.sh failed at line $LINENO: $BASH_COMMAND (exit $status)" >&2' ERR

: "${ARIA2_VERSION:?ARIA2_VERSION is required}"
: "${UPSTREAM_TAG:?UPSTREAM_TAG is required}"
: "${BITTORRENT:?BITTORRENT must be yes or no}"
: "${CPU_FLAGS:?CPU_FLAGS is required}"
: "${ARTIFACT_NAME:?ARTIFACT_NAME is required}"

[[ "$ARIA2_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid ARIA2_VERSION: $ARIA2_VERSION" >&2; exit 1; }
[[ "$UPSTREAM_TAG" == "release-$ARIA2_VERSION" ]] || { echo "UPSTREAM_TAG does not match ARIA2_VERSION" >&2; exit 1; }
[[ "$ARTIFACT_NAME" =~ ^arch-x86-64-v3-(bt|nobt)$ ]] || { echo "Unexpected Arch artifact name: $ARTIFACT_NAME" >&2; exit 1; }
[[ "$CPU_FLAGS" == '-O3 -flto=auto -march=x86-64-v3' ]] || { echo "Unexpected CPU_FLAGS: $CPU_FLAGS" >&2; exit 1; }

case "$BITTORRENT:$ARTIFACT_NAME" in
  yes:arch-x86-64-v3-bt) expected_pkgname=aria2-custom-bt ;;
  no:arch-x86-64-v3-nobt) expected_pkgname=aria2-custom-nobt ;;
  *) echo "BITTORRENT does not match ARTIFACT_NAME" >&2; exit 1 ;;
esac

source_archive="/workspace/source/aria2-$ARIA2_VERSION.tar.gz"
patch_file=/workspace/patches/unlimited-max-connection-per-server.patch
openssl_patch_file=/workspace/patches/openssl4-compat.patch
common_file="$(dirname "${BASH_SOURCE[0]}")/build-linux-common.sh"
pkgbuild_file=/workspace/packaging/arch/PKGBUILD
output_dir="${OUTPUT_DIR:-/workspace/dist}"
cache_key="$(aria2_linux_build_cache_key "$CPU_FLAGS" "$BITTORRENT" "$source_archive" "$patch_file" "$openssl_patch_file" "$common_file" "$pkgbuild_file")"
build_root="${BUILD_ROOT:-/workspace/build/aria2-$ARIA2_VERSION-$ARTIFACT_NAME-$cache_key}"
builder_user=makepkg-builder

for command in makepkg runuser useradd chown sha256sum file bsdtar; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done
for input in "$source_archive" "$patch_file" "$openssl_patch_file" "$common_file" "$pkgbuild_file"; do
  [[ -f "$input" ]] || { echo "Required input file not found: $input" >&2; exit 1; }
done

mkdir -p "$build_root" "$output_dir"
if [[ -d "$build_root/src" ]] &&
  { [[ ! -f "$build_root/.aria2-cache-key" ]] || [[ "$(<"$build_root/.aria2-cache-key")" != "$cache_key" ]]; }; then
  echo "Persistent build directory contains a different build cache: $build_root" >&2
  exit 1
fi
printf '%s\n' "$cache_key" > "$build_root/.aria2-cache-key"
install -m 0644 "$source_archive" "$build_root/aria2-$ARIA2_VERSION.tar.gz"
install -m 0644 "$patch_file" "$build_root/unlimited-max-connection-per-server.patch"
install -m 0644 "$openssl_patch_file" "$build_root/openssl4-compat.patch"
install -m 0644 "$common_file" "$build_root/build-linux-common.sh"
install -m 0644 "$pkgbuild_file" "$build_root/PKGBUILD"
aria2_linux_check_cpu_flags "$CPU_FLAGS" "$build_root/flags-test.o"

if ! id "$builder_user" >/dev/null 2>&1; then
  useradd --create-home --uid 1000 "$builder_user"
fi
chown -R "$builder_user:$builder_user" "$build_root"

makepkg_args=(--noconfirm --nodeps --dir "$build_root")
if [[ -f "$build_root/src/aria2-$ARIA2_VERSION/.aria2-custom-prepared" ]]; then
  makepkg_args+=(--noextract)
fi
makepkg_started="$build_root/.makepkg-started"
touch "$makepkg_started"
runuser -u "$builder_user" -- env \
  ARIA2_VERSION="$ARIA2_VERSION" BUILD_REVISION="$BUILD_REVISION" \
  UPSTREAM_TAG="$UPSTREAM_TAG" BITTORRENT="$BITTORRENT" CPU_FLAGS="$CPU_FLAGS" \
  ARTIFACT_NAME="$ARTIFACT_NAME" BUILD_JOBS="${BUILD_JOBS:-$(nproc)}" \
  makepkg "${makepkg_args[@]}"

package_file=
while IFS= read -r candidate; do
  [[ "$candidate" -nt "$makepkg_started" ]] || continue
  pkginfo="$(bsdtar -xOf "$candidate" .PKGINFO)"
  candidate_name="$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<<"$pkginfo")"
  candidate_version="$(awk -F ' = ' '$1 == "pkgver" { print $2; exit }' <<<"$pkginfo")"
  candidate_arch="$(awk -F ' = ' '$1 == "arch" { print $2; exit }' <<<"$pkginfo")"
  if [[ "$candidate_name" == "$expected_pkgname" &&
        "$candidate_version" == "$ARIA2_VERSION-$BUILD_REVISION" &&
        "$candidate_arch" == x86_64 ]]; then
    package_file=$candidate
    break
  fi
done < <(find "$build_root" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print)
[[ -n "$package_file" ]] || { echo "No package with expected internal metadata ($expected_pkgname $ARIA2_VERSION-$BUILD_REVISION x86_64) was produced" >&2; exit 1; }

install_root="$build_root/package-root"
mkdir -p "$install_root/usr/bin"
binary="$install_root/usr/bin/aria2c"
bsdtar -xOf "$package_file" usr/bin/aria2c > "$binary"
chmod 0755 "$binary"
[[ -x "$binary" ]] || { echo "Arch package does not contain executable aria2c" >&2; exit 1; }
file "$binary" | grep -Eq 'ELF 64-bit.*x86-64'
"$binary" --no-conf --max-connection-per-server=100000 --version > "$build_root/version.txt"
grep -Fq "aria2 version $ARIA2_VERSION" "$build_root/version.txt"

archive_name="$ARTIFACT_NAME.pkg.tar.zst"
install -m 0644 "$package_file" "$output_dir/$archive_name"
(cd "$output_dir" && sha256sum "$archive_name" > "$archive_name.sha256")
printf 'Built %s from %s\n' "$archive_name" "$build_root"
