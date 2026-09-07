#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

# Archive, split, and upload one directory.
# Usage: ./upload_directory.sh LOCAL_DIR REMOTE_DIR [ARCHIVE_NAME]

PART_SIZE="${TBOX_PART_SIZE:-3900m}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UPLOADER="${SCRIPT_DIR}/upload_file.sh"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command -v tar >/dev/null 2>&1 || die 'tar is required'
command -v split >/dev/null 2>&1 || die 'split is required'
[[ -x "$UPLOADER" ]] || die "missing executable uploader: $UPLOADER"
[[ $# -ge 2 && $# -le 3 ]] || die "usage: $0 LOCAL_DIR REMOTE_DIR [ARCHIVE_NAME]"

local_dir=${1%/}
remote_dir=${2#/}
remote_dir=${remote_dir%/}

[[ -d "$local_dir" ]] || die "local directory does not exist: $local_dir"
[[ -n "$remote_dir" ]] || die 'remote directory must not be empty'

dir_parent=$(cd -- "$(dirname -- "$local_dir")" && pwd)
dir_name=$(basename -- "$local_dir")
archive_name=${3:-$dir_name}

[[ "$archive_name" != */* ]] || die 'archive name must not contain a slash'
[[ -n "$archive_name" && "$archive_name" != '.' && "$archive_name" != '..' ]] || die 'invalid archive name'

if [[ -z "${TBOX_USER_TOKEN:-}" ]]; then
  read -r -s -p 'UserToken: ' TBOX_USER_TOKEN
  printf '\n' >&2
fi
[[ -n "$TBOX_USER_TOKEN" ]] || die 'UserToken must not be empty'
export TBOX_USER_TOKEN

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/sjtu-pan-upload.XXXXXX")
cleanup() {
  rm -rf -- "$staging_dir"
}
trap cleanup EXIT INT TERM

part_prefix="${staging_dir}/${archive_name}.tar.part-"
printf 'Archiving %s and splitting into %s parts...\n' "$local_dir" "$PART_SIZE" >&2
tar -C "$dir_parent" -cf - -- "$dir_name" |
  split -b "$PART_SIZE" -d -a 3 - "$part_prefix"

parts=("${part_prefix}"*)
[[ -e "${parts[0]}" ]] || die 'no archive part was created'

printf 'Uploading %d part(s) to %s...\n' "${#parts[@]}" "$remote_dir" >&2
for part in "${parts[@]}"; do
  part_name=$(basename -- "$part")
  "$UPLOADER" "$part" "${remote_dir}/${part_name}"
done

printf 'Directory upload complete. Uploaded archive name: %s\n' "$archive_name"
