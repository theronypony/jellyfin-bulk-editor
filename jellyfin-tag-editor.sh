#!/usr/bin/env bash
set -euo pipefail

# Interactive Jellyfin bulk tag editor
# - Adds/removes ONE tag across a selected library
# - For TV libraries, ONLY updates parent Series (never individual Episodes)
# - For other libraries (e.g., Movies), updates the items themselves
#
# Dependencies: bash (4+), curl, jq
#
# Optional .env in same dir:
#   SERVER=http://localhost:8096
#   API_KEY=your-api-key
#   USER_ID=your-user-id
#   PAGE_SIZE=200

# ---------- config ----------
SERVER="${SERVER:-}"
API_KEY="${API_KEY:-}"
USER_ID="${USER_ID:-}"
PAGE_SIZE="${PAGE_SIZE:-200}"

# ---------- helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq

# Load .env if present
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
  SERVER="${SERVER:-}"
  API_KEY="${API_KEY:-}"
  USER_ID="${USER_ID:-}"
  PAGE_SIZE="${PAGE_SIZE:-200}"
fi

read_prompt() {
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

# API calls
get_views() {
  curl -fsSL "${auth_headers[@]}" "$(url_join "$SERVER" "Users/$USER_ID/Views")"
}
list_items_page() {
  local library_id="$1" start="$2" include_types="$3"
  local base; base=$(url_join "$SERVER" "Users/$USER_ID/Items")
  local url="${base}?ParentId=$(urlenc "$library_id")&Recursive=true&StartIndex=${start}&Limit=${PAGE_SIZE}&Fields=Tags,Name,Type,SeriesId,SeriesName&EnableTotalRecordCount=true"
  [[ -n "$include_types" ]] && url="${url}&IncludeItemTypes=$(urlenc "$include_types")"
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

# ---------- Step 1: Select Library ----------
echo "Fetching libraries..."
views_json=$(get_views) || die "Could not fetch libraries (check server/API key/user id)."

mapfile -t LIB_IDS   < <(echo "$views_json" | jq -r '.Items[]?.Id')
mapfile -t LIB_NAMES < <(echo "$views_json" | jq -r '.Items[]?.Name')
mapfile -t LIB_TYPES < <(echo "$views_json" | jq -r '.Items[]?.CollectionType // ""')

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
LIBRARY_TYPE="${LIB_TYPES[$((lib_sel-1))]}"

# Determine if we should force Series-only targeting
# If CollectionType is tvshows, we will target Series only.
TARGET_SERIES_ONLY="false"
if [[ "$LIBRARY_TYPE" == "tvshows" ]]; then
  TARGET_SERIES_ONLY="true"
fi

# ---------- Step 2: Add or Remove ----------
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

# ---------- Step 3: Tag value ----------
TAG=""
while :; do
  read_prompt "Which tag would you like to ${ACTION,,}?" TAG
  TAG="${TAG#"${TAG%%[![:space:]]*}"}"; TAG="${TAG%"${TAG##*[![:space:]]}"}" # trim
  [[ -n "$TAG" ]] && break
  echo "Tag cannot be empty."
done

# ---------- Step 4: Confirm ----------
echo
if [[ "$ACTION" == "Add" ]]; then
  echo "Are you sure you want to add the tag \"$TAG\" to all items in \"$LIBRARY_NAME\"? (y/N)"
else
  echo "Are you sure you want to remove the tag \"$TAG\" from all items in \"$LIBRARY_NAME\"? (y/N)"
fi
read -r -p "> " yn
[[ "$yn" == [Yy]* ]] || { echo "Cancelled."; exit 0; }

# ---------- Collect target item IDs ----------
# For tvshows: ONLY Series. We’ll page through the library,
# and map Episodes/Seasons to their SeriesId, dedupe, then update Series.
declare -A TARGET_IDS=()    # id -> name (filled later)
declare -A NAME_CACHE=()    # id -> name (to avoid extra GETs when possible)

start=0
total=-1

# If tvshows, restrict listing to Series to reduce API work.
INCLUDE_TYPES=""
if [[ "$TARGET_SERIES_ONLY" == "true" ]]; then
  INCLUDE_TYPES="Series"
fi

echo
echo "Scanning \"$LIBRARY_NAME\" (this just collects targets)…"

while :; do
  page=$(list_items_page "$LIBRARY_ID" "$start" "$INCLUDE_TYPES") || die "Failed to list items."
  count=$(echo "$page" | jq -r '.Items | length')
  [[ "$total" -lt 0 ]] && total=$(echo "$page" | jq -r '.TotalRecordCount // -1')
  [[ "$count" -eq 0 ]] && break

  for ((i=0;i<count;i++)); do
    type=$(echo "$page" | jq -r ".Items[$i].Type // \"\"")
    id=$(echo "$page" | jq -r ".Items[$i].Id")
    name=$(echo "$page" | jq -r ".Items[$i].Name // \"(no name)\"")

    target_id="$id"  # default (movies etc.)
    target_name="$name"

    if [[ "$TARGET_SERIES_ONLY" == "true" ]]; then
      case "$type" in
        Series)
          target_id="$id"
          target_name="$name"
          ;;
        Season|Episode)
          # Map to parent SeriesId
          sid=$(echo "$page" | jq -r ".Items[$i].SeriesId // empty")
          sname=$(echo "$page" | jq -r ".Items[$i].SeriesName // empty")
          [[ -n "$sid" ]] && target_id="$sid"
          [[ -n "$sname" ]] && target_name="$sname"
          ;;
        *)
          # Non-TV types are ignored in a TV library
          continue
          ;;
      esac
    fi

    # Deduplicate
    TARGET_IDS["$target_id"]="$target_name"
  done

  start=$((start + count))
  [[ "$count" -lt "$PAGE_SIZE" ]] && break
done

targets_count=${#TARGET_IDS[@]}
[[ "$targets_count" -gt 0 ]] || { echo "No target Series/items found. Nothing to do."; exit 0; }

echo "Found $targets_count target item(s) to update."

# ---------- Execute updates on targets ----------
processed=0
changed=0
failed=0

for id in "${!TARGET_IDS[@]}"; do
  processed=$((processed+1))
  tname="${TARGET_IDS[$id]:-(unknown)}"
  printf "[%d/%d] %s (%s)\n" "$processed" "$targets_count" "$tname" "$id"

  full=$(get_item_full "$id") || { echo "  ! fetch failed"; failed=$((failed+1)); continue; }

  # Current tags (unique)
  mapfile -t current < <(echo "$full" | jq -r '.Tags[]? // empty' | awk 'NF' | sort -u)

  new_tags=("${current[@]}")
  if [[ "$ACTION" == "Add" ]]; then
    if ! printf '%s\n' "${current[@]}" | grep -Fxq -- "$TAG"; then
      new_tags+=("$TAG")
    fi
  else
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

  if post_item_update "$id" "$updated"; then
    echo "  ✓ updated -> $(printf '%s\n' "${new_tags[@]}" | paste -sd ', ' -)"
    changed=$((changed+1))
  else
    echo "  ✗ update failed"
    failed=$((failed+1))
  fi
done

echo
echo "Done."
echo "Processed targets: $processed"
echo "Changed:           $changed"
echo "Failed:            $failed"
