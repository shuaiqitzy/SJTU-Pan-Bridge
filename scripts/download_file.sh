#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

# Download one file from the personal space of SJTU Pan.
# Usage: ./download_file.sh REMOTE_PATH LOCAL_FILE

BASE_URL="${TBOX_BASE_URL:-https://pan.sjtu.edu.cn}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v jq >/dev/null 2>&1 || die 'jq is required'
[[ $# -eq 2 ]] || die "usage: $0 REMOTE_PATH LOCAL_FILE"

remote_path=${1#/}
local_file=$2
[[ -n "$remote_path" ]] || die 'remote path must not be empty'
[[ -n "$local_file" ]] || die 'local file must not be empty'

if [[ -z "${TBOX_USER_TOKEN:-}" ]]; then
  read -r -s -p 'UserToken: ' TBOX_USER_TOKEN
  printf '\n' >&2
fi
[[ -n "$TBOX_USER_TOKEN" ]] || die 'UserToken must not be empty'

encoded_path=$(printf '%s' "$remote_path" | jq -sRr 'split("/") | map(@uri) | join("/")')

printf 'Getting a fresh access token...\n' >&2
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

local_parent=$(dirname -- "$local_file")
mkdir -p -- "$local_parent"

printf 'Downloading %s...\n' "$remote_path" >&2
curl --ipv4 --fail --location --show-error \
  --retry 5 --retry-delay 3 --retry-all-errors \
  --continue-at - \
  --output "$local_file" \
  "${BASE_URL}/api/v1/file/${library_id}/${space_id}/${encoded_path}?access_token=${access_token_q}"

printf 'Download complete: %s\n' "$local_file"
