#!/usr/bin/env bash
set -euo pipefail

# Jellyfin bulk user policy editor (interactive)
# - Read policy via GET /Users/{id} (.Policy), then POST /Users/{id}/Policy
# - Add/Remove AllowedTags and BlockedTags
# - Set library access (EnableAllFolders or specific EnabledFolders)
# - Fallback: if a user's policy can't be read, do safe "merge-only" adds + library toggle
#
# Dependencies: bash (4+), curl, jq
# Optional .env in same dir:
#   SERVER=https://your.host[:port][/basepath]
#   API_KEY=your-admin-api-key

# ---------- config / .env ----------
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1090
  . ./.env
  set +a
fi

SERVER="${SERVER:-}"
API_KEY="${API_KEY:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq

die() { echo "Error: $*" >&2; exit 1; }

read_prompt() {
  local prompt="$1" var="$2" secret="${3:-false}" value
  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$prompt: " value; echo
  else
    read -r -p "$prompt: " value
  fi
  printf -v "$var" '%s' "$value"
}

[[ -n "$SERVER" ]]  || read_prompt "Enter Jellyfin server URL (e.g., https://tv.example.com/jellyfin)" SERVER
[[ -n "$API_KEY" ]] || read_prompt "Enter ADMIN API key" API_KEY true

auth_headers=(
  -H "X-Emby-Token: ${API_KEY}"
  -H "Accept: application/json"
  -H "Content-Type: application/json"
)

url_join() { local a="${1%/}" b="${2#/}"; printf '%s/%s' "$a" "$b"; }

# ---------- API helpers ----------
get_users() {
  curl -fsSL "${auth_headers[@]}" "$(url_join "$SERVER" "Users")"
}
get_user() {
  local id="$1"
  curl -fsSL "${auth_headers[@]}" "$(url_join "$SERVER" "Users/$id")"
}
get_libraries() {
  curl -fsSL "${auth_headers[@]}" "$(url_join "$SERVER" "Library/VirtualFolders")"
}
post_user_policy() {
  local id="$1" json="$2"
  curl -fsS "${auth_headers[@]}" -X POST -d "$json" "$(url_join "$SERVER" "Users/$id/Policy")" -o /dev/null
}

# If reading policy fails for some user, do a safe "merge-only" update:
# - ADD AllowedTags/BlockedTags
# - Toggle library mode
# (Skip tag removals; we can't know current state.)
post_user_policy_merge() {
  # args: <userId> <allowedAddNL> <blockedAddNL> <libMode> [selectedLibIds...]
  local id="$1"; shift
  local aAdd="$1"; shift
  local bAdd="$1"; shift
  local libmode="$1"; shift
  local payload='{}'

  if [[ -n "$aAdd" ]]; then
    payload=$(jq -cn --argjson add "$(printf '%s\n' "$aAdd" | jq -R . | jq -s .)" '{AllowedTags:$add}')
  fi
  if [[ -n "$bAdd" ]]; then
    payload=$(jq -c --argjson add "$(printf '%s\n' "$bAdd" | jq -R . | jq -s .)" "$payload + {BlockedTags:$add}")
  fi
  if [[ "$libmode" == "enableAll" ]]; then
    payload=$(jq -c '. + {EnableAllFolders:true, EnabledFolders:[]}' <<< "$payload")
  elif [[ "$libmode" == "selected" ]]; then
    local ids; ids=$(printf '%s\n' "$@" | awk 'NF' | sort -u | jq -R . | jq -s .)
    payload=$(jq -c --argjson ids "$ids" '. + {EnableAllFolders:false, EnabledFolders:$ids}' <<< "$payload")
  fi

  curl -fsS "${auth_headers[@]}" -X POST -d "$payload" "$(url_join "$SERVER" "Users/$id/Policy")" -o /dev/null
}

# ---------- UI helpers ----------
add_to_set() {
  local prompt="$1" outvar="$2"
  local csv
  read -r -p "$prompt (comma-separated, leave blank to skip): " csv
  csv="${csv:-}"
  if [[ -z "$csv" ]]; then
    printf -v "$outvar" ''
    return
  fi
  local list
  list=$(echo "$csv" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF' | sort -u)
  printf -v "$outvar" '%s' "$list"
}

apply_set_changes() {
  # $1: policy JSON, $2: jq path (.AllowedTags or .BlockedTags)
  # uses globals ADD_LIST REMOVE_LIST (newline lists or empty)
  local json="$1" path="$2" arr
  mapfile -t cur < <(echo "$json" | jq -r "$path[]? // empty" | sort -u)

  if [[ -n "${REMOVE_LIST:-}" ]]; then
    while IFS= read -r t; do
      # remove exact match
      cur=("${cur[@]/$t}")
    done <<< "$REMOVE_LIST"
    cur=($(printf '%s\n' "${cur[@]}" | awk 'NF' | sort -u))
  fi
  if [[ -n "${ADD_LIST:-}" ]]; then
    while IFS= read -r t; do
      if ! printf '%s\n' "${cur[@]}" | grep -Fxq -- "$t"; then
        cur+=("$t")
      fi
    done <<< "$ADD_LIST"
  fi
  arr=$(printf '%s\n' "${cur[@]}" | jq -R . | jq -s .)
  echo "$arr"
}

# ---------- Select users ----------
echo "Fetching users..."
users_json=$(get_users) || die "Could not fetch users (check SERVER/API_KEY)."
mapfile -t U_IDS   < <(echo "$users_json" | jq -r '.[].Id')
mapfile -t U_NAMES < <(echo "$users_json" | jq -r '.[].Name')
[[ ${#U_IDS[@]} -gt 0 ]] || die "No users returned."

echo
echo "Select users to modify (comma-separated list, or 'all'):"
for i in "${!U_IDS[@]}"; do
  printf "  %2d) %s\n" "$((i+1))" "${U_NAMES[$i]}"
done

selection=""
while :; do
  read -r -p "Enter numbers (e.g., 1,3,5) or 'all': " selection
  selection="${selection//[[:space:]]/}"
  if [[ "$selection" == "all" ]]; then
    SELECTED_IDS=("${U_IDS[@]}")
    SELECTED_NAMES=("${U_NAMES[@]}")
    break
  fi
  if [[ "$selection" =~ ^[0-9,]+$ ]]; then
    IFS=, read -r -a idxs <<< "$selection"
    SELECTED_IDS=()
    SELECTED_NAMES=()
    valid=true
    for idx in "${idxs[@]}"; do
      if (( idx>=1 && idx<=${#U_IDS[@]} )); then
        SELECTED_IDS+=("${U_IDS[$((idx-1))]}")
        SELECTED_NAMES+=("${U_NAMES[$((idx-1))]}")
      else
        valid=false; break
      fi
    done
    $valid && break
  fi
  echo "Invalid selection."
done

# ---------- Choose what to change ----------
echo
echo "What would you like to change?"
echo "  1) AllowedTags (add/remove)"
echo "  2) BlockedTags (add/remove)"
echo "  3) Library access (all libraries vs selected libraries)"
echo "  4) Multiple of the above"
choice=""
while :; do
  read -r -p "Select 1-4: " choice
  [[ "$choice" =~ ^[1-4]$ ]] && break
done

wants_allowed=false
wants_blocked=false
wants_libs=false
case "$choice" in
  1) wants_allowed=true ;;
  2) wants_blocked=true ;;
  3) wants_libs=true ;;
  4) wants_allowed=true; wants_blocked=true; wants_libs=true ;;
esac

if $wants_allowed; then
  echo
  echo "AllowedTags:"
  add_to_set "Tags to ADD to AllowedTags" ALLOWED_ADD
  add_to_set "Tags to REMOVE from AllowedTags" ALLOWED_REMOVE
fi
if $wants_blocked; then
  echo
  echo "BlockedTags:"
  add_to_set "Tags to ADD to BlockedTags" BLOCKED_ADD
  add_to_set "Tags to REMOVE from BlockedTags" BLOCKED_REMOVE
fi

SELECT_ALL_LIBS=""
SELECTED_LIB_IDS=()
SELECTED_LIB_NAMES=()

if $wants_libs; then
  echo
  echo "Library access:"
  echo "  1) Enable ALL libraries"
  echo "  2) Restrict to SELECTED libraries"
  libmode=""
  while :; do
    read -r -p "Select 1 or 2: " libmode
    [[ "$libmode" == "1" || "$libmode" == "2" ]] && break
  done
  if [[ "$libmode" == "1" ]]; then
    SELECT_ALL_LIBS="true"
  else
    SELECT_ALL_LIBS="false"
    echo "Fetching libraries..."
    libs_json=$(get_libraries) || die "Could not fetch libraries."
    # Typical fields: Name, ItemId
    mapfile -t L_IDS   < <(echo "$libs_json" | jq -r '.[] | (.ItemId // .Id // empty)' | awk 'NF')
    mapfile -t L_NAMES < <(echo "$libs_json" | jq -r '.[] | .Name' | awk 'NF')
    [[ ${#L_IDS[@]} -gt 0 ]] || die "No libraries found."

    echo
    echo "Select libraries (comma-separated indices):"
    for i in "${!L_IDS[@]}"; do
      printf "  %2d) %s\n" "$((i+1))" "${L_NAMES[$i]}"
    done
    libsel=""
    while :; do
      read -r -p "Enter numbers: " libsel
      libsel="${libsel//[[:space:]]/}"
      if [[ "$libsel" =~ ^[0-9,]+$ ]]; then
        IFS=, read -r -a idxs <<< "$libsel"
        valid=true
        for idx in "${idxs[@]}"; do
          if (( idx>=1 && idx<=${#L_IDS[@]} )); then
            SELECTED_LIB_IDS+=("${L_IDS[$((idx-1))]}")
            SELECTED_LIB_NAMES+=("${L_NAMES[$((idx-1))]}")
          else
            valid=false; break
          fi
        done
        $valid && break
      fi
      echo "Invalid selection."
    done
  fi
fi

# ---------- Confirm ----------
echo
echo "Summary:"
echo "Users to modify: ${#SELECTED_IDS[@]}"
printf '  %s\n' "${SELECTED_NAMES[@]}"

if $wants_allowed; then
  echo "AllowedTags:"
  [[ -n "${ALLOWED_ADD:-}" ]]    && echo "  ADD:    $(echo "$ALLOWED_ADD" | paste -sd ', ' -)"    || echo "  ADD:    (none)"
  [[ -n "${ALLOWED_REMOVE:-}" ]] && echo "  REMOVE: $(echo "$ALLOWED_REMOVE" | paste -sd ', ' -)" || echo "  REMOVE: (none)"
fi
if $wants_blocked; then
  echo "BlockedTags:"
  [[ -n "${BLOCKED_ADD:-}" ]]    && echo "  ADD:    $(echo "$BLOCKED_ADD" | paste -sd ', ' -)"    || echo "  ADD:    (none)"
  [[ -n "${BLOCKED_REMOVE:-}" ]] && echo "  REMOVE: $(echo "$BLOCKED_REMOVE" | paste -sd ', ' -)" || echo "  REMOVE: (none)"
fi
if $wants_libs; then
  if [[ "$SELECT_ALL_LIBS" == "true" ]]; then
    echo "Library access: ALL libraries"
  else
    echo "Library access: SELECTED only"
    printf '  %s\n' "${SELECTED_LIB_NAMES[@]}"
  fi
fi

read -r -p "Proceed with these changes? (y/N): " yn
[[ "$yn" == [Yy]* ]] || { echo "Cancelled."; exit 0; }

# ---------- Execute ----------
processed=0
changed=0
failed=0

for idx in "${!SELECTED_IDS[@]}"; do
  uid="${SELECTED_IDS[$idx]}"
  uname="${SELECTED_NAMES[$idx]}"
  processed=$((processed+1))
  echo
  echo "[$processed/${#SELECTED_IDS[@]}] Updating user: $uname ($uid)"

  # Read policy from /Users/{id}
  user_json=""
  if ! user_json=$(get_user "$uid"); then
    echo "  ! GET /Users/$uid failed; falling back to merge-only"
    # Merge-only (adds + library toggle)
    aAdd="${ALLOWED_ADD:-}"
    bAdd="${BLOCKED_ADD:-}"
    libmode="none"
    if $wants_libs; then
      if [[ "$SELECT_ALL_LIBS" == "true" ]]; then libmode="enableAll"; else libmode="selected"; fi
    fi
    if post_user_policy_merge "$uid" "$aAdd" "$bAdd" "$libmode" "${SELECTED_LIB_IDS[@]}"; then
      echo "  ✓ updated (fallback merge)"
      changed=$((changed+1))
    else
      echo "  ✗ update failed (fallback)"
      failed=$((failed+1))
    fi
    continue
  fi

  policy=$(echo "$user_json" | jq -c '.Policy // {}')
  # Ensure expected fields exist (defaults)
  updated=$(echo "$policy" | jq \
    '.AllowedTags = (.AllowedTags // []) |
     .BlockedTags = (.BlockedTags // []) |
     .EnableAllFolders = (.EnableAllFolders // false) |
     .EnabledFolders = (.EnabledFolders // [])')

  # AllowedTags
  if $wants_allowed; then
    ADD_LIST="${ALLOWED_ADD:-}"
    REMOVE_LIST="${ALLOWED_REMOVE:-}"
    new_arr=$(apply_set_changes "$updated" '.AllowedTags')
    updated=$(jq --argjson arr "$new_arr" '.AllowedTags = $arr' <<< "$updated")
  fi

  # BlockedTags
  if $wants_blocked; then
    ADD_LIST="${BLOCKED_ADD:-}"
    REMOVE_LIST="${BLOCKED_REMOVE:-}"
    new_arr=$(apply_set_changes "$updated" '.BlockedTags')
    updated=$(jq --argjson arr "$new_arr" '.BlockedTags = $arr' <<< "$updated")
  fi

  # Library access
  if $wants_libs; then
    if [[ "$SELECT_ALL_LIBS" == "true" ]]; then
      updated=$(jq '.EnableAllFolders = true | .EnabledFolders = []' <<< "$updated")
    else
      unique_ids=$(printf '%s\n' "${SELECTED_LIB_IDS[@]}" | awk 'NF' | sort -u | jq -R . | jq -s .)
      updated=$(jq --argjson ids "$unique_ids" '.EnableAllFolders=false | .EnabledFolders=$ids' <<< "$updated")
    fi
  fi

  before=$(echo "$policy"  | jq -c '{AllowedTags,BlockedTags,EnableAllFolders,EnabledFolders}')
  after=$( echo "$updated" | jq -c '{AllowedTags,BlockedTags,EnableAllFolders,EnabledFolders}')
  if [[ "$before" == "$after" ]]; then
    echo "  - no change"
    continue
  fi

  if post_user_policy "$uid" "$updated"; then
    echo "  ✓ updated"
    changed=$((changed+1))
  else
    echo "  ✗ update failed"
    failed=$((failed+1))
  fi
done

echo
echo "Done."
echo "Processed: $processed"
echo "Changed:   $changed"
echo "Failed:    $failed"
