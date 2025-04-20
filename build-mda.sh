#!/usr/bin/env bash
# filepath: build-mda.sh
# This bash file require jq, docker, sqlite3 or sqlite, unzip, and tar to be installed. All of them are compatible with alpine.
# Author: yongyanchen@crimsonlogic.com
# copyright (c) 2023 CrimsonLogic Pte Ltd

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; exit 1; }

find_default_file() {
  local src=$1 ext=$2
  if [[ -f "$src" ]]; then
    [[ "$src" == *"$ext" ]] && echo "$src" || return 1
  else
    mapfile -t files < <(ls "$src"/*"$ext" 2>/dev/null || true)
    case ${#files[@]} in
      1) echo "${files[0]}";;
      0) return 1;;
      *) log_error "More than one $ext found in $src";;
    esac
  fi
}

get_metadata_value() {
  local dir=$1
  local meta="$dir/model/metadata.json"
  if [[ -f "$meta" ]]; then
    jq . "$meta" 2>/dev/null || return 1
  else
    return 1
  fi
}

extract_zip() {
  local zipfile=$1
  local tmp
  tmp=$(mktemp -d /tmp/mendix-docker-buildpack.XXXX)
  tar -xf "$zipfile" -C "$tmp"
  echo "$tmp"
}

parse_version() {
  # returns major.minor.patch ... as array
  IFS='.' read -r -a ver <<< "$1"
  echo "${ver[@]}"
}

build_mpr() {
  echo "Building mpr..."
  local src_dir=$1 mpr=$2 dest=$3 art_repo=$4
  local mx_version dotnet tag image sqlite_cmd
  if command -v sqlite3 &>/dev/null; then
    sqlite_cmd=sqlite3
  elif command -v sqlite &>/dev/null; then
    sqlite_cmd=sqlite
  else
    log_error "Neither sqlite3 nor sqlite found"
  fi

  mx_version=$($sqlite_cmd "$mpr" "SELECT _ProductVersion FROM _MetaData LIMIT 1;")
  
  mx_version=$(sqlite3 "$mpr" "SELECT _ProductVersion FROM _MetaData LIMIT 1;")
  echo "mendix version: $mx_version"
  IFS=' ' read -r -a ver <<< "$(parse_version "$mx_version")"
  if (( ver[0]>=10 )); then dotnet=dotnet; else dotnet=mono; fi
  tag="mxbuild-$mx_version-$dotnet-$(uname -m)"
  image="${art_repo:-mendix-buildpack}:${tag}"
  # Try pull first
  if [[ -n "$art_repo" ]] && docker image pull "$image" &>/dev/null; then
    :
  else
    echo "========= Building image $image... =========="
    docker image build \
      --build-arg MXBUILD_DOWNLOAD_URL="https://download.mendix.com/runtimes/mxbuild-$mx_version.tar.gz" \
      --file "$SCRIPT_DIR/mxbuild/$dotnet.dockerfile" \
      --tag "$image" "$SCRIPT_DIR/mxbuild"
    [[ -n "$art_repo" ]] && docker image push "$image" || true

    echo "========= Image $image built =========="
  fi

  local commit
  if commit=$(cd "$src_dir" && git rev-parse HEAD 2>/dev/null); then
    :
  else
    commit="unversioned"
    log_warn "No git metadata, using unversioned"
  fi

  local cid
  cid=$(docker container create "$image" "$(basename "$mpr")" "$commit")
  trap "docker container rm --force $cid" EXIT

  docker container cp "$src_dir/." "$cid:/workdir/project"
  docker container ls -all "$src_dir"
  docker start --attach --interactive "$cid"

  local dst_mda
  if [[ -n "${MDAPATH:-}" ]]; then
    dst_mda="$MDAPATH"
  else
    dst_mda=$(mktemp -d /tmp/mendix-docker-buildpack.XXXX)
  fi

  docker container cp "$cid:/workdir/output.mda" "$dst_mda"
  unzip "$dst_mda/output.mda" -d "$dest"
}

prepare_destination() {
  local dest=$1
  if [[ -d "$dest" ]]; then
    rm -rf "$dest"/*
  else
    mkdir -p -m755 "$dest"
  fi
  mkdir -m755 "$dest/project"
  [[ -d "$SCRIPT_DIR/scripts" ]] || log_error "scripts/ missing"
  [[ -f "$SCRIPT_DIR/Dockerfile" ]] || log_error "Dockerfile missing"
  cp -r "$SCRIPT_DIR/scripts" "$dest/"
  cp    "$SCRIPT_DIR/Dockerfile" "$dest/"
}

prepare_mda() {
  local src=$1 dst=$2 art_repo=${3:-}
  prepare_destination "$dst"
  ls -lf "$src"
  local mpk mpr mda meta
  mpk=$(find_default_file "$src" .mpk)   && src=$(extract_zip "$mpk")
  echo "Extracted $mpk to $src"
  mpr=$(find_default_file "$src" .mpr)   && build_mpr "$(dirname "$mpr")" "$mpr" "$dst" "$art_repo" && return
  echo "Extracted $mpr to $src"
  mda=$(find_default_file "$src" .mda)   && tar -xf "$mda" -C "$dst"
  echo "Extracted $mda to $dst"
  [[ -d "$src" ]] && cp -r "$src/." "$dst/"
  meta=$(get_metadata_value "$dst") && return
  log_error "No supported files found in $src"
}

usage() {
  cat <<EOF
Usage: $0 --source PATH --destination PATH [--artifacts-repository URL] [--mda-path PATH] build-mda-dir
EOF
  exit 1
}

# --- main ---

SOURCE="" DEST="" REPO="" MDAPATH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --source)      SOURCE=$2; shift 2;;
    --destination) DEST=$2;   shift 2;;
    --artifacts-repository) REPO=$2; shift 2;;
    --mda-path) MDAPATH=$2; shift 2;;
    build-mda-dir) ACTION=build-mda-dir; shift;;
    *) usage;;
  esac
done

[[ -n "$SOURCE" && -n "$DEST" && "${ACTION:-}" == build-mda-dir ]] || usage

prepare_mda "$SOURCE" "$DEST" "$REPO"