#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

# Download a personal-space directory recursively, preserving its contents.
# Usage: ./download_directory.sh REMOTE_DIR LOCAL_DIR

BASE_URL=${TBOX_BASE_URL:-https://pan.sjtu.edu.cn}
BASE_URL=${BASE_URL%/}
PAGE_SIZE=100
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOWNLOADER="$SCRIPT_DIR/download_file.sh"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s REMOTE_DIR LOCAL_DIR\n' "$0"; }
if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then
  usage
  exit 0
fi
[[ $# -eq 2 ]] || { usage >&2; exit 1; }
for tool in curl jq wc; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[[ -f "$DOWNLOADER" ]] || die "missing downloader: $DOWNLOADER"

REMOTE_DIR=${1#/}
REMOTE_DIR=${REMOTE_DIR%/}
LOCAL_DIR=$2
[[ -n "$REMOTE_DIR" ]] || die 'remote directory must not be empty'
[[ -n "$LOCAL_DIR" ]] || die 'local directory must not be empty'

if [[ -z "${TBOX_USER_TOKEN:-}" ]]; then
  read -r -s -p 'UserToken: ' TBOX_USER_TOKEN
  printf '\n' >&2
fi
[[ -n "$TBOX_USER_TOKEN" ]] || die 'UserToken must not be empty'
export TBOX_USER_TOKEN

# Refresh listing credentials on every page: earlier downloads may take hours.
refresh_credentials() {
  local space_json
  space_json=$(
    printf '%s' "$TBOX_USER_TOKEN" |
      curl --ipv4 --fail --silent --show-error \
        --request POST --get --data-urlencode 'user_token@-' \
        "$BASE_URL/user/v1/space/1/personal"
  )
  jq -e '(.libraryId | type == "string" and length > 0)
    and (.spaceId | type == "string" and length > 0)
    and (.accessToken | type == "string" and length > 0)' \
    <<<"$space_json" >/dev/null || die 'could not obtain personal-space credentials; check UserToken'
  library_id=$(jq -r '.libraryId' <<<"$space_json")
  space_id=$(jq -r '.spaceId' <<<"$space_json")
  access_token_q=$(jq -r '.accessToken | @uri' <<<"$space_json")
}

downloaded=0
skipped=0
directories=0

download_tree() {
  local remote=$1 dest=$2 page=1 encoded listing total item name kind target size local_size
  [[ ! -L "$dest" ]] || die "refusing a local directory symlink: $dest"
  mkdir -p -- "$dest"
  directories=$((directories + 1))
  printf 'Directory: %s -> %s\n' "$remote" "$dest"
  encoded=$(printf '%s' "$remote" | jq -sRr 'split("/") | map(@uri) | join("/")')

  while :; do
    refresh_credentials
    listing=$(
      curl --ipv4 --fail --silent --show-error \
        "$BASE_URL/api/v1/directory/$library_id/$space_id/$encoded?page=$page&page_size=$PAGE_SIZE&order_by=name&order_by_type=asc&access_token=$access_token_q"
    )
    jq -e '(.contents | type == "array")
      and (.totalNum | tostring | test("^[0-9]+$"))' \
      <<<"$listing" >/dev/null || die "invalid directory response: $remote"
    total=$(jq -r '.totalNum' <<<"$listing")

    while IFS= read -r item; do
      jq -e '.name | type == "string" and length > 0 and (explode | index(0) == null)' \
        <<<"$item" >/dev/null || die "invalid entry name in: $remote"
      # NUL-delimited read preserves spaces, backslashes and trailing newlines.
      IFS= read -r -d '' name < <(jq -j '.name, "\u0000"' <<<"$item")
      [[ "$name" != . && "$name" != .. && "$name" != */* ]] || die "unsafe entry name in: $remote"
      kind=$(jq -r '.type' <<<"$item")
      target="$dest/$name"
      [[ ! -L "$target" ]] || die "refusing a local symlink: $target"

      case "$kind" in
        dir|directory)
          download_tree "$remote/$name" "$target"
          ;;
        file)
          size=$(jq -er '.size | tostring | select(test("^[0-9]+$"))' <<<"$item") ||
            die "missing or invalid file size: $remote/$name"
          if [[ -e "$target" ]]; then
            [[ -f "$target" ]] || die "local path is not a regular file: $target"
            local_size=$(wc -c <"$target")
            if (( local_size == size )); then
              printf 'Skipping same-size file: %s\n' "$target"
              skipped=$((skipped + 1))
              continue
            fi
            (( local_size < size )) || die "local file is larger than remote file; move it aside: $target"
          fi
          if (( size == 0 )); then
            : >"$target"
          else
            bash "$DOWNLOADER" "$remote/$name" "$target"
          fi
          local_size=$(wc -c <"$target")
          (( local_size == size )) || die "downloaded size differs from directory listing: $target"
          downloaded=$((downloaded + 1))
          ;;
        *) die "unsupported entry type '$kind' in: $remote" ;;
      esac
    done < <(jq -c '.contents[]' <<<"$listing")

    (( page * PAGE_SIZE >= total )) && break
    (( $(jq '.contents | length' <<<"$listing") > 0 )) || die "empty page before end of directory: $remote"
    page=$((page + 1))
  done
}

download_tree "$REMOTE_DIR" "$LOCAL_DIR"
printf 'Directory download complete: %s\nDownloaded: %d; skipped (same size): %d; directories: %d\n' \
  "$LOCAL_DIR" "$downloaded" "$skipped" "$directories"
