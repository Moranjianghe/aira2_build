#!/usr/bin/env bash
set -Eeuo pipefail
trap 'status=$?; echo "::error::resolve-release.sh failed at line $LINENO: $BASH_COMMAND (exit $status)" >&2' ERR

for command in gh jq sha256sum; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

requested_tag="${1:-}"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
output_file="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
workspace="${GITHUB_WORKSPACE:-$PWD}"
source_dir="$workspace/source"

if [[ -n "$requested_tag" ]]; then
  if [[ ! "$requested_tag" =~ ^release-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "upstream_tag must match release-X.Y.Z: $requested_tag" >&2
    exit 1
  fi
  api_path="repos/aria2/aria2/releases/tags/$requested_tag"
else
  api_path="repos/aria2/aria2/releases/latest"
fi

echo "Resolving official aria2 release from $api_path"
release_json="$(gh api --header 'Accept: application/vnd.github+json' --header 'X-GitHub-Api-Version: 2022-11-28' "$api_path")"
tag="$(jq -er '.tag_name' <<<"$release_json")"
# jq -e returns exit code 1 for a valid JSON false value.  These fields are
# expected to be false for a stable release, so normalize them to strings
# without using -e.
prerelease="$(jq -r 'if .prerelease == true then "true" else "false" end' <<<"$release_json")"
draft="$(jq -r 'if .draft == true then "true" else "false" end' <<<"$release_json")"

if [[ "$prerelease" == "true" || "$draft" == "true" ]]; then
  echo "Refusing to build a prerelease or draft: $tag" >&2
  exit 1
fi
if [[ ! "$tag" =~ ^release-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "The selected upstream release tag is not a stable aria2 tag: $tag" >&2
  exit 1
fi

version="${tag#release-}"
release_tag="aria2-$version"
should_build=true
source_url=""

if gh release view "$release_tag" --repo "$repository" >/dev/null 2>&1; then
  should_build=false
  echo "Release $release_tag already exists; skipping the build."
else
  archive_name="aria2-$version.tar.gz"
  if ! asset_url="$(jq -er --arg name "$archive_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json")"; then
    echo "Official release $tag does not contain $archive_name" >&2
    exit 1
  fi
  asset_digest="$(jq -r --arg name "$archive_name" '.assets[] | select(.name == $name) | (.digest // "")' <<<"$release_json")"
  source_url="$asset_url"
  mkdir -p "$source_dir"
  archive_path="$source_dir/$archive_name"
  gh release download "$tag" --repo aria2/aria2 --pattern "$archive_name" --dir "$source_dir" --clobber

  actual_digest="$(sha256sum "$archive_path" | awk '{print $1}')"
  if [[ -n "$asset_digest" ]]; then
    expected_digest="${asset_digest#sha256:}"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
      echo "Source archive digest mismatch: expected $expected_digest, got $actual_digest" >&2
      exit 1
    fi
  fi
  echo "Downloaded $archive_name (sha256: $actual_digest)"
fi

{
  printf 'tag=%s\n' "$tag"
  printf 'version=%s\n' "$version"
  printf 'release_tag=%s\n' "$release_tag"
  printf 'source_url=%s\n' "$source_url"
  printf 'should_build=%s\n' "$should_build"
} >> "$output_file"
