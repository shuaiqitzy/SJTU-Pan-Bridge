#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

# Upload one file to the personal space of SJTU Pan.
# Usage: ./upload_file.sh LOCAL_FILE REMOTE_PATH

BASE_URL="${TBOX_BASE_URL:-https://pan.sjtu.edu.cn}"
CONFLICT_STRATEGY="${TBOX_CONFLICT_STRATEGY:-overwrite}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v jq >/dev/null 2>&1 || die 'jq is required'
[[ $# -eq 2 ]] || die "usage: $0 LOCAL_FILE REMOTE_PATH"

local_file=$1
remote_path=${2#/}

[[ -f "$local_file" ]] || die "local file does not exist: $local_file"
[[ -r "$local_file" ]] || die "local file is not readable: $local_file"
[[ -n "$remote_path" ]] || die 'remote path must not be empty'

case "$CONFLICT_STRATEGY" in
  overwrite|rename|ask) ;;
  *) die 'TBOX_CONFLICT_STRATEGY must be overwrite, rename, or ask' ;;
esac

if [[ -z "${TBOX_USER_TOKEN:-}" ]]; then
  read -r -s -p 'UserToken: ' TBOX_USER_TOKEN
  printf '\n' >&2
fi
[[ -n "$TBOX_USER_TOKEN" ]] || die 'UserToken must not be empty'

encoded_path=$(printf '%s' "$remote_path" | jq -sRr 'split("/") | map(@uri) | join("/")')

printf '1/4 Getting a fresh access token...\n' >&2
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
strategy_q=$(printf '%s' "$CONFLICT_STRATEGY" | jq -sRr '@uri')

printf '2/4 Requesting a signed upload URL...\n' >&2
upload_json=$(
  curl --ipv4 --fail --silent --show-error \
    --request PUT \
    --header 'Content-Type: application/json' \
    --data '{}' \
    "${BASE_URL}/api/v1/file/${library_id}/${space_id}/${encoded_path}?conflict_resolution_strategy=${strategy_q}&access_token=${access_token_q}"
)

domain=$(jq -er '.domain' <<<"$upload_json")
object_path=$(jq -er '.path' <<<"$upload_json")
confirm_key=$(jq -er '.confirmKey' <<<"$upload_json")

curl_headers=()
while IFS= read -r header; do
  curl_headers+=(--header "$header")
done < <(jq -r '.headers | to_entries[] | "\(.key): \(.value)"' <<<"$upload_json")

printf '3/4 Uploading %s...\n' "$local_file" >&2
curl --ipv4 --fail --silent --show-error \
  --request PUT \
  --upload-file "$local_file" \
  "${curl_headers[@]}" \
  "https://${domain}${object_path}" \
  >/dev/null

printf '4/4 Confirming the uploaded file...\n' >&2
result_json=$(
  curl --ipv4 --fail --silent --show-error \
    --request POST \
    "${BASE_URL}/api/v1/file/${library_id}/${space_id}/${confirm_key}?confirm&conflict_resolution_strategy=${strategy_q}&access_token=${access_token_q}"
)

printf 'Upload complete:\n'
jq '{path, name, size, eTag, crc64, isOverwritten}' <<<"$result_json"
