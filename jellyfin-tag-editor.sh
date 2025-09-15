#!/usr/bin/env bash
set -euo pipefail

# Interactive Jellyfin bulk tag editor (add/remove one tag from all items in a library)
# Flow:
#   1) Select Library (queried from /Users/{userId}/Views)
#   2) Choose Add or Remove
#   3) Enter tag
#   4) Confirm
#   5) Execute against all items in that library
#
# Dependencies: curl, jq
# Optional flags (otherwise prompted): --server, --api-key, --user-id
#
# Usage:
#   ./jf-bulk-tag-interactive.sh [--server URL] [--api-key KEY] [--user-id ID]

SERVER=${SERVER} 
API_KEY=${API_KEY} 
USER_ID=${USER_ID}
PAGE_SIZE=${PAGE_SIZE}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq

# --- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="$2"; shift 2;;
    --api-key) API_KEY="$2"; shift 2;;
    --user-id) USER_ID="$2"; shift 2;;
    -h|--help)
      sed -n '1,120p' "$0"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

read_prompt() {
  # $1 = prompt, $2 = varname, $3 = secret? (true/false)
  local prompt="$1" var="$2" secret="${3:-false}" value
  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$prompt: " value; echo
  else
    read -r -p "$prompt: " value
  fi
  printf -v "$var" '%s' "$value"
}

[[ -n "$SERVER" ]]  || read_prompt "Enter Jellyfin server URL (e.g., http://localhost:8096)" SERVER
[[ -n "$API_KEY" ]] || read_prompt "Enter API key" API_KEY true
[[ -n "$USER_ID" ]] || read_prompt "Enter User ID" USER_ID

die() { echo "Error: $*" >&2; exit 1; }

auth_headers=(
  -H "Authorization: MediaBrowser Token=${API_KEY}"
  -H "X-Emby-Token: ${API_KEY}"
  -H "Content-Type: application/json"
)

url_join() { local a="${1%/}"; local b="${2#/}"; echo "$a/$b"; }
urlenc() {
  local LC_ALL=C s="$1" out="" i c
  for ((i=0;i<${#s};i++)); do
    c=${s:i:1}
    case "$c" in [a-zA-Z0-9.~_-]) out+="$c" ;; *) printf -v out '%s%%%02X' "$out" "'$c" ;; esac
  done
  echo "$out"
}

# --- API helpers ---
get_views() {
  local url; url=$(url_join "$SERVER" "Users/$USER_ID/Views")
  curl -fsSL "${auth_headers[@]}" "$url"
}

list_items_page() {
  local library_id="$1" start="$2"
  local base; base=$(url_join "$SERVER" "Users/$USER_ID/Items")
  local url="${base}?ParentId=$(urlenc "$library_id")&Recursive=true&StartIndex=${start}&Limit=${PAGE_SIZE}&Fields=Tags,Name&EnableTotalRecordCount=true"
  curl -fsSL "${auth_headers[@]}" "$url"
}

get_item_full() {
  local id="$1"
  curl -fsSL "${auth_headers[@]}" "$(url_join "$SERVER" "Users/$USER_ID/Items/$id")"
}

post_item_update() {
  local id="$1" json="$2"
  curl -fsS "${auth_headers[@]}" -X POST -d "$json" "$(url_join "$SERVER" "Items/$id")" -o /dev/null
}

# --- Step 1: Select Library ---
echo "Fetching libraries..."
views_json=$(get_views) || die "Could not fetch libraries (check server/API key/user id)."

mapfile -t LIB_IDS   < <(echo "$views_json" | jq -r '.Items[]?.Id')
mapfile -t LIB_NAMES < <(echo "$views_json" | jq -r '.Items[]?.Name')

[[ ${#LIB_IDS[@]} -gt 0 ]] || die "No libraries returned for this user."

echo
echo "Please select a Library:"
for i in "${!LIB_IDS[@]}"; do
  printf "  %2d) %s\n" "$((i+1))" "${LIB_NAMES[$i]}"
done

lib_sel=""
while :; do
  read -r -p "Enter number (1-${#LIB_IDS[@]}): " lib_sel
  [[ "$lib_sel" =~ ^[0-9]+$ ]] && (( lib_sel>=1 && lib_sel<=${#LIB_IDS[@]} )) && break
  echo "Invalid selection."
done
LIBRARY_ID="${LIB_IDS[$((lib_sel-1))]}"
LIBRARY_NAME="${LIB_NAMES[$((lib_sel-1))]}"

# --- Step 2: Add or Remove ---
echo
echo "Add or remove a tag?"
echo "  1) Add"
echo "  2) Remove"
choice=""
while :; do
  read -r -p "Select 1 or 2: " choice
  [[ "$choice" == "1" || "$choice" == "2" ]] && break
  echo "Please enter 1 or 2."
done

ACTION="Add"
[[ "$choice" == "2" ]] && ACTION="Remove"

# --- Step 3: Tag value ---
TAG=""
while :; do
  read_prompt "Which tag would you like to ${ACTION,,}?" TAG
  TAG="${TAG#"${TAG%%[![:space:]]*}"}"; TAG="${TAG%"${TAG##*[![:space:]]}"}" # trim
  [[ -n "$TAG" ]] && break
  echo "Tag cannot be empty."
done

# --- Step 4: Confirm ---
echo
if [[ "$ACTION" == "Add" ]]; then
  echo "Are you sure you want to add the tag \"$TAG\" to all items in \"$LIBRARY_NAME\"? (y/N)"
else
  echo "Are you sure you want to remove the tag \"$TAG\" from all items in \"$LIBRARY_NAME\"? (y/N)"
fi
read -r -p "> " yn
[[ "$yn" == [Yy]* ]] || { echo "Cancelled."; exit 0; }

# --- Execute ---
echo
echo "Processing library: $LIBRARY_NAME"
processed=0
changed=0
failed=0
start=0
total=-1

while :; do
  page=$(list_items_page "$LIBRARY_ID" "$start") || die "Failed to list items."
  count=$(echo "$page" | jq -r '.Items | length')
  [[ "$total" -lt 0 ]] && total=$(echo "$page" | jq -r '.TotalRecordCount // -1')
  [[ "$count" -eq 0 ]] && break

  for ((i=0;i<count;i++)); do
    itemId=$(echo "$page" | jq -r ".Items[$i].Id")
    name=$(echo "$page" | jq -r ".Items[$i].Name // \"(no name)\"")
    processed=$((processed+1))
    printf "[%d/%d] %s (%s)\n" "$processed" "$total" "$name" "$itemId"

    # Fetch full DTO
    full=$(get_item_full "$itemId") || { echo "  ! fetch failed"; failed=$((failed+1)); continue; }

    # Current tags (unique)
    mapfile -t current < <(echo "$full" | jq -r '.Tags[]? // empty' | awk 'NF' | sort -u)

    # Build new tags
    new_tags=("${current[@]}")
    if [[ "$ACTION" == "Add" ]]; then
      if ! printf '%s\n' "${current[@]}" | grep -Fxq -- "$TAG"; then
        new_tags+=("$TAG")
      fi
    else
      # Remove
      tmp=()
      for t in "${new_tags[@]}"; do
        [[ "$t" == "$TAG" ]] || tmp+=("$t")
      done
      new_tags=("${tmp[@]}")
    fi

    # Compare
    if diff -q <(printf '%s\n' "${current[@]}" | sort) <(printf '%s\n' "${new_tags[@]}" | sort) >/dev/null 2>&1; then
      echo "  - no change"
      continue
    fi

    updated=$(echo "$full" | jq --argjson arr "$(printf '%s\n' "${new_tags[@]}" | jq -R . | jq -s .)" '.Tags = $arr')

    if post_item_update "$itemId" "$updated"; then
      echo "  ✓ updated -> $(printf '%s\n' "${new_tags[@]}" | paste -sd ', ' -)"
      changed=$((changed+1))
    else
      echo "  ✗ update failed"
      failed=$((failed+1))
    fi
  done

  start=$((start + count))
  [[ "$count" -lt "$PAGE_SIZE" ]] && break
done

echo
echo "Done."
echo "Processed: $processed"
echo "Changed:   $changed"
echo "Failed:    $failed"
