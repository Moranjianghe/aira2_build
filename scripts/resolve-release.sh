#!/usr/bin/env bash
set -Eeuo pipefail

requested_tag="${1:-}"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
output_file="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
workspace="${GITHUB_WORKSPACE:-$PWD}"
source_dir="$workspace/source"
api_headers=(
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
  -H "User-Agent: aira2-build"
)

if [[ -n "$requested_tag" ]]; then
  if [[ ! "$requested_tag" =~ ^release-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "upstream_tag must match release-X.Y.Z: $requested_tag" >&2
    exit 1
  fi
  api_url="https://api.github.com/repos/aria2/aria2/releases/tags/$requested_tag"
else
  api_url="https://api.github.com/repos/aria2/aria2/releases/latest"
fi

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  api_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

release_json="$(curl --fail --silent --show-error --location --retry 3 "${api_headers[@]}" "$api_url")"
tag="$(jq -er '.tag_name' <<<"$release_json")"
prerelease="$(jq -er '.prerelease' <<<"$release_json")"
draft="$(jq -er '.draft' <<<"$release_json")"

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
  asset_url="$(jq -er --arg name "$archive_name" '.assets[] | select(.name == $name) | .url' <<<"$release_json" 2>/dev/null || true)"
  asset_digest="$(jq -r --arg name "$archive_name" '.assets[] | select(.name == $name) | (.digest // "")' <<<"$release_json" 2>/dev/null || true)"
  if [[ -z "$asset_url" ]]; then
    asset_url="https://github.com/aria2/aria2/releases/download/$tag/$archive_name"
  fi
  source_url="$asset_url"
  mkdir -p "$source_dir"
  archive_path="$source_dir/$archive_name"
  download_headers=(
    -H "Accept: application/octet-stream"
    -H "User-Agent: aira2-build"
  )
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    download_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl --fail --silent --show-error --location --retry 3 "${download_headers[@]}" "$asset_url" -o "$archive_path"

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
