#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

# Download NAME.tar.part-NNN from a remote directory and optionally extract it.
# Usage: ./download_archive.sh REMOTE_DIR ARCHIVE_NAME DOWNLOAD_DIR [--extract EXTRACT_DIR]

BASE_URL="${TBOX_BASE_URL:-https://pan.sjtu.edu.cn}"
PAGE_SIZE=100
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOWNLOADER="${SCRIPT_DIR}/download_file.sh"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v jq >/dev/null 2>&1 || die 'jq is required'
command -v tar >/dev/null 2>&1 || die 'tar is required'
command -v sort >/dev/null 2>&1 || die 'sort is required'
[[ -x "$DOWNLOADER" ]] || die "missing executable downloader: $DOWNLOADER"
[[ $# -eq 3 || $# -eq 5 ]] || die "usage: $0 REMOTE_DIR ARCHIVE_NAME DOWNLOAD_DIR [--extract EXTRACT_DIR]"

remote_dir=${1#/}
remote_dir=${remote_dir%/}
archive_name=$2
download_dir=$3
extract_dir=''

[[ -n "$remote_dir" ]] || die 'remote directory must not be empty'
[[ "$archive_name" != */* ]] || die 'archive name must not contain a slash'
[[ -n "$archive_name" && "$archive_name" != '.' && "$archive_name" != '..' ]] || die 'invalid archive name'

if [[ $# -eq 5 ]]; then
  [[ $4 == '--extract' ]] || die 'the fourth argument must be --extract'
  extract_dir=$5
  [[ -n "$extract_dir" ]] || die 'extract directory must not be empty'
fi

if [[ -z "${TBOX_USER_TOKEN:-}" ]]; then
  read -r -s -p 'UserToken: ' TBOX_USER_TOKEN
  printf '\n' >&2
fi
[[ -n "$TBOX_USER_TOKEN" ]] || die 'UserToken must not be empty'
export TBOX_USER_TOKEN

space_json=$(
  printf '%s' "$TBOX_USER_TOKEN" |
    curl --ipv4 --fail --silent --show-error \
      --request POST --get \
      --data-urlencode 'user_token@-' \
      "${BASE_URL}/user/v1/space/1/personal"
)

api_status=$(jq -r '.status // 0' <<<"$space_json")
[[ "$api_status" == "0" ]] || die "space lookup failed: $(jq -r '.message // .' <<<"$space_json")"

library_id=$(jq -er '.libraryId' <<<"$space_json")
space_id=$(jq -er '.spaceId' <<<"$space_json")
access_token=$(jq -er '.accessToken' <<<"$space_json")
access_token_q=$(printf '%s' "$access_token" | jq -sRr '@uri')
encoded_dir=$(printf '%s' "$remote_dir" | jq -sRr 'split("/") | map(@uri) | join("/")')

files=()
page=1
part_prefix="${archive_name}.tar.part-"

while :; do
  list_json=$(
    curl --ipv4 --fail --silent --show-error \
      "${BASE_URL}/api/v1/directory/${library_id}/${space_id}/${encoded_dir}?page=${page}&page_size=${PAGE_SIZE}&order_by=name&order_by_type=asc&access_token=${access_token_q}"
  )

  api_status=$(jq -r '.status // 0' <<<"$list_json")
  [[ "$api_status" == "0" ]] || die "directory listing failed: $(jq -r '.message // .' <<<"$list_json")"

  while IFS= read -r name; do
    files+=("$name")
  done < <(
    jq -r --arg prefix "$part_prefix" '
      .contents[]?
      | select(.type == "file")
      | .name
      | select(startswith($prefix))
      | select(.[($prefix | length):] | test("^[0-9]+$"))
    ' <<<"$list_json"
  )

  total_num=$(jq -r '.totalNum // 0' <<<"$list_json")
  (( page * PAGE_SIZE >= total_num )) && break
  page=$((page + 1))
done

(( ${#files[@]} > 0 )) || die "no archive parts found for ${archive_name} in ${remote_dir}"

sorted_files=()
while IFS= read -r name; do
  sorted_files+=("$name")
done < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)

expected=0
for name in "${sorted_files[@]}"; do
  part_number=${name##*.part-}
  [[ "$part_number" =~ ^[0-9]+$ ]] || die "invalid part name: $name"
  (( 10#$part_number == expected )) || die "missing or out-of-order part: expected $expected, found $part_number"
  expected=$((expected + 1))
done

mkdir -p -- "$download_dir"
printf 'Downloading %d part(s)...\n' "${#sorted_files[@]}" >&2
for name in "${sorted_files[@]}"; do
  "$DOWNLOADER" "${remote_dir}/${name}" "${download_dir}/${name}"
done

printf 'All parts downloaded to: %s\n' "$download_dir"

if [[ -n "$extract_dir" ]]; then
  local_parts=()
  for name in "${sorted_files[@]}"; do
    local_parts+=("${download_dir}/${name}")
  done

  printf 'Checking the complete tar archive...\n' >&2
  cat -- "${local_parts[@]}" | tar -tf - >/dev/null || die 'archive is incomplete or damaged'

  mkdir -p -- "$extract_dir"
  printf 'Extracting to %s...\n' "$extract_dir" >&2
  cat -- "${local_parts[@]}" | tar -C "$extract_dir" -xf -
  printf 'Extraction complete: %s\n' "$extract_dir"
fi
