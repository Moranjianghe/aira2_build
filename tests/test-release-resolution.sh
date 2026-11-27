#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/build-config.sh"

test_root="$(mktemp -d)"
trap 'rm -r -- "$test_root"' EXIT

export GITHUB_REPOSITORY=Moranjianghe/aira2_build
export GITHUB_WORKSPACE="$test_root"
export GITHUB_OUTPUT="$test_root/output"
export GITHUB_STEP_SUMMARY="$test_root/summary"
export MOCK_LATEST_TAG=release-1.37.0
export MOCK_RELEASE_EXISTS=false
export MOCK_ASSETS=""

gh() {
  case "$1 $2" in
    'api --header')
      local endpoint="${*: -1}"
      local selected_tag="$MOCK_LATEST_TAG"
      if [[ "$endpoint" == repos/aria2/aria2/releases/tags/* ]]; then
        selected_tag="${endpoint##*/}"
      fi
      jq -n --arg tag "$selected_tag" --arg archive "aria2-${selected_tag#release-}.tar.gz" \
        '{tag_name:$tag, prerelease:false, draft:false, assets:[{name:$archive, browser_download_url:("https://example.invalid/" + $archive), digest:null}]}'
      ;;
    'release view')
      [[ "$MOCK_RELEASE_EXISTS" == true ]] || return 1
      if [[ " $* " == *' --json assets '* ]]; then
        printf '%s\n' "$MOCK_ASSETS"
      fi
      ;;
    'release download')
      local destination=""
      local release_tag="$3"
      while (($#)); do
        if [[ "$1" == --dir ]]; then
          destination="$2"
          break
        fi
        shift
      done
      [[ -n "$destination" ]] || return 1
      mkdir -p "$destination"
      printf 'fixture for %s\n' "$release_tag" > "$destination/aria2-${release_tag#release-}.tar.gz"
      ;;
    *)
      printf 'Unexpected gh invocation: %s\n' "$*" >&2
      return 1
      ;;
  esac
}
export -f gh

reset_outputs() {
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
}

expect_output() {
  grep -Fxq "$1" "$GITHUB_OUTPUT"
}

complete_assets=""
for package_asset in \
  windows-x86-64-v3-bt.zip \
  windows-x86-64-v3-nobt.zip \
  debian-12-x86-64-v2-bt.deb \
  debian-12-x86-64-v2-nobt.deb \
  debian-13-x86-64-v3-bt.deb \
  debian-13-x86-64-v3-nobt.deb \
  arch-x86-64-v3-bt.pkg.tar.zst \
  arch-x86-64-v3-nobt.pkg.tar.zst; do
  complete_assets+="$package_asset"$'\n'"$package_asset.sha256"$'\n'
done

# A new build revision must be published even though the old release is full.
reset_outputs
bash "$repo_root/scripts/resolve-release.sh"
expect_output "release_tag=aria2-1.37.0-custom$BUILD_REVISION"
expect_output 'should_build=true'
expect_output 'is_latest_upstream=true'
test -s "$test_root/source/aria2-1.37.0.tar.gz"

# A complete current release is skipped.
export MOCK_RELEASE_EXISTS=true
export MOCK_ASSETS="$complete_assets"
reset_outputs
bash "$repo_root/scripts/resolve-release.sh"
expect_output 'should_build=false'
grep -Fq 'already contains all eight packages and checksums' "$GITHUB_STEP_SUMMARY"

# Missing checksums must also cause a rebuild.
export MOCK_ASSETS="${complete_assets/debian-13-x86-64-v3-nobt.deb.sha256/}"
reset_outputs
bash "$repo_root/scripts/resolve-release.sh"
expect_output 'should_build=true'

# Missing Arch package or checksum must cause a rebuild.
export MOCK_ASSETS="${complete_assets/arch-x86-64-v3-bt.pkg.tar.zst/}"
reset_outputs
bash "$repo_root/scripts/resolve-release.sh"
expect_output 'should_build=true'

export MOCK_ASSETS="${complete_assets/arch-x86-64-v3-nobt.pkg.tar.zst.sha256/}"
reset_outputs
bash "$repo_root/scripts/resolve-release.sh"
expect_output 'should_build=true'

# Manually rebuilding an older stable release must not make it GitHub Latest.
export MOCK_RELEASE_EXISTS=false
reset_outputs
bash "$repo_root/scripts/resolve-release.sh" release-1.36.0
expect_output "release_tag=aria2-1.36.0-custom$BUILD_REVISION"
expect_output 'is_latest_upstream=false'

# A newly published stable release gets its own release tag automatically.
export MOCK_LATEST_TAG=release-1.38.0
reset_outputs
bash "$repo_root/scripts/resolve-release.sh"
expect_output "release_tag=aria2-1.38.0-custom$BUILD_REVISION"
expect_output 'is_latest_upstream=true'

if command -v dpkg >/dev/null 2>&1; then
  dpkg --compare-versions "1.37.0+zzcustom$BUILD_REVISION" gt '1.37.0+debian-3'
  dpkg --compare-versions "1.37.0+zzcustom$BUILD_REVISION~bt" lt "1.37.0+zzcustom$BUILD_REVISION"
else
  printf 'Skipping Debian version ordering checks: dpkg is unavailable.\n'
fi

printf 'Release resolution checks passed.\n'
