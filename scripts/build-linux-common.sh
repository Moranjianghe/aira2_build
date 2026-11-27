#!/usr/bin/env bash

# Shared Linux aria2 build configuration used by Debian and Arch builders.
aria2_linux_set_configure_args() {
  local bittorrent_flag=$1
  ARIA2_CONFIGURE_ARGS=(
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
}

aria2_linux_check_cpu_flags() {
  local cpu_flags=$1
  local output_file=$2
  local -a flags
  read -r -a flags <<< "$cpu_flags"
  printf '%s\n' 'int main() { return 0; }' | c++ "${flags[@]}" -x c++ -c -o "$output_file" -
  rm -f "$output_file"
}

aria2_linux_apply_connection_patch() {
  local source_dir=$1
  local patch_file=$2
  patch --batch --forward --fuzz=0 -p1 -d "$source_dir" < "$patch_file"
  grep -Fq '"1", 1, -1,' "$source_dir/src/OptionHandlerFactory.cc"
}

aria2_linux_configure() {
  local cpu_flags=$1
  local expected_bittorrent=$2
  local configure_log=$3
  shift 3

  ARIA2_STATIC=no CFLAGS="$cpu_flags" CXXFLAGS="$cpu_flags" LDFLAGS='-flto=auto' \
    ./configure "$@" 2>&1 | tee "$configure_log"
  grep -Eq "Bittorrent:[[:space:]]+$expected_bittorrent$" "$configure_log"
}

aria2_linux_build_cache_key() {
  local cpu_flags=$1
  local bittorrent=$2
  shift 2

  {
    printf '%s\0' "$cpu_flags" "$bittorrent"
    sha256sum -- "$@"
  } | sha256sum | cut -c1-20
}
