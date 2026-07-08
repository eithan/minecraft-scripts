#!/usr/bin/env bash
set -euo pipefail

# --- Argument parsing ---
MCADDON_PATH=""
PRETTY_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      MCADDON_PATH="$2"
      shift 2
      ;;
    -n|--name)
      PRETTY_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 -f <path_to_mcaddon> -n <pretty_name>"
      exit 1
      ;;
  esac
done

if [[ -z "$MCADDON_PATH" || -z "$PRETTY_NAME" ]]; then
  echo "Usage: $0 -f <path_to_mcaddon> -n <pretty_name>"
  exit 1
fi

# --- Validate addon path ---
echo "[INFO] Validating addon path..."
if [[ ! -e "$MCADDON_PATH" ]]; then
  echo "[ERROR] File does not exist: $MCADDON_PATH"
  exit 1
fi

if [[ ! -f "$MCADDON_PATH" ]]; then
  echo "[ERROR] Not a file: $MCADDON_PATH"
  exit 1
fi

if [[ "${MCADDON_PATH##*.}" != "mcaddon" ]]; then
  echo "[WARN] File does not have .mcaddon extension (continuing)"
fi

SERVER_DIR="$HOME/mcbedrock-server"
BP_DEST="$SERVER_DIR/behavior_packs"
RP_DEST="$SERVER_DIR/resource_packs"

command -v unzip >/dev/null || { echo "[ERROR] unzip is required"; exit 1; }
command -v jq >/dev/null || { echo "[ERROR] jq is required"; exit 1; }

# 1. Extract
TMP_DIR=$(mktemp -d /tmp/mcaddon_XXXXXX)
echo "[INFO] Extracting addon to: $TMP_DIR"
unzip -q "$MCADDON_PATH" -d "$TMP_DIR"

echo "[DEBUG] Extracted contents:"
ls -la "$TMP_DIR"

# Some .mcaddon files are wrappers around separate BP/RP .mcpack archives.
# Expand those nested packs before searching for manifests.
echo "[INFO] Expanding embedded .mcpack files if present..."
while IFS= read -r -d '' mcpack; do
  pack_name=$(basename "$mcpack" .mcpack)
  pack_dir="$TMP_DIR/$pack_name"

  echo "[INFO] Extracting embedded pack: $mcpack -> $pack_dir"
  rm -rf "$pack_dir"
  mkdir -p "$pack_dir"
  unzip -q "$mcpack" -d "$pack_dir"
done < <(find "$TMP_DIR" -type f -iname "*.mcpack" -print0)

# Read a JSON file, handling UTF-8 BOM and // line comments (JSONC format)
read_json() {
  local f="$1"
  local first3
  first3=$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')
  if [[ "$first3" == "efbbbf" ]]; then
    tail -c +4 "$f"
  else
    cat "$f"
  fi | grep -v '^[[:space:]]*//'
}

# 2 & 3. Find BP and RP via manifest.json
echo "[INFO] Searching for manifest.json files..."

BP_SRC=""
RP_SRC=""

while IFS= read -r manifest; do
  dir=$(dirname "$manifest")
  echo "[DEBUG] Found manifest: $manifest"

  # Determine module type
  if read_json "$manifest" | jq -e '.modules[] | select(.type=="data" or .type=="script")' >/dev/null 2>&1; then
    echo "[INFO] Identified Behavior Pack at: $dir"
    BP_SRC="$dir"
  fi

  if read_json "$manifest" | jq -e '.modules[] | select(.type=="resources")' >/dev/null 2>&1; then
    echo "[INFO] Identified Resource Pack at: $dir"
    RP_SRC="$dir"
  fi

done < <(find "$TMP_DIR" -type f -name "manifest.json")

# Fallback: if manifest scan missed BP or RP, try matching folder names
# Matches "BP" or "RP" as a whole token (not buried inside a longer word)
if [[ -z "$BP_SRC" ]]; then
  echo "[INFO] Manifest scan did not identify a BP. Falling back to folder name matching..."
  while IFS= read -r -d '' dir; do
    name=$(basename "$dir")
    if [[ "$name" =~ (^|[^A-Za-z])[Bb][Pp]([^A-Za-z]|$) ]]; then
      echo "[INFO] Found likely BP folder by name: $dir"
      BP_SRC="$dir"
      break
    fi
  done < <(find "$TMP_DIR" -mindepth 1 -maxdepth 2 -type d -print0)
fi

if [[ -z "$RP_SRC" ]]; then
  echo "[INFO] Manifest scan did not identify an RP. Falling back to folder name matching..."
  while IFS= read -r -d '' dir; do
    name=$(basename "$dir")
    if [[ "$name" =~ (^|[^A-Za-z])[Rr][Pp]([^A-Za-z]|$) ]]; then
      echo "[INFO] Found likely RP folder by name: $dir"
      RP_SRC="$dir"
      break
    fi
  done < <(find "$TMP_DIR" -mindepth 1 -maxdepth 2 -type d -print0)
fi

if [[ -z "$BP_SRC" || -z "$RP_SRC" ]]; then
  echo "[ERROR] Could not reliably find BP or RP folders."
  echo "[DEBUG] Contents of $TMP_DIR:"
  find "$TMP_DIR"
  exit 1
fi

# New names
BP_NAME="${PRETTY_NAME}_bp"
RP_NAME="${PRETTY_NAME}_rp"

BP_TARGET="$BP_DEST/$BP_NAME"
RP_TARGET="$RP_DEST/$RP_NAME"

# 4. Extract BP manifest info
echo "[INFO] Reading BP manifest..."
BP_MANIFEST="$BP_SRC/manifest.json"
BP_UUID=$(read_json "$BP_MANIFEST" | jq -r '.header.uuid')
BP_VERSION=$(read_json "$BP_MANIFEST" | jq '.header.version')
ADDON_NAME=$(read_json "$BP_MANIFEST" | jq -r '.header.name')

# 5. Extract RP manifest info
echo "[INFO] Reading RP manifest..."
RP_MANIFEST="$RP_SRC/manifest.json"
RP_UUID=$(read_json "$RP_MANIFEST" | jq -r '.header.uuid')
RP_VERSION=$(read_json "$RP_MANIFEST" | jq '.header.version')

# Move and rename
echo "[INFO] Installing packs..."
rm -rf "$BP_TARGET" "$RP_TARGET"
mv "$BP_SRC" "$BP_TARGET"
mv "$RP_SRC" "$RP_TARGET"

echo "[INFO] BP installed to: $BP_TARGET"
echo "[INFO] RP installed to: $RP_TARGET"

# Function to safely append if UUID not present
append_if_missing() {
  local file="$1"
  local uuid="$2"
  local version="$3"
  local name="$4"

  [[ -f "$file" ]] || return

  if jq -e --arg uuid "$uuid" '.[] | select(.pack_id == $uuid)' "$file" >/dev/null; then
    echo "[INFO] Skipping $file (UUID already present)"
    return
  fi

  echo "[INFO] Updating $file"

  TMP_FILE=$(mktemp)

  jq ". += [{
    \"pack_id\": \"$uuid\",
    \"version\": $version,
    \"_comment\": \"$name\"
  }]" "$file" > "$TMP_FILE"

  mv "$TMP_FILE" "$file"
}

# 6. Update behavior packs
for file in "$SERVER_DIR"/worlds/*/world_behavior_packs.json; do
  append_if_missing "$file" "$BP_UUID" "$BP_VERSION" "$ADDON_NAME"
done

# 7. Update resource packs
for file in "$SERVER_DIR"/worlds/*/world_resource_packs.json; do
  append_if_missing "$file" "$RP_UUID" "$RP_VERSION" "$ADDON_NAME"
done

# 8. Summary
echo ""
echo "[SUCCESS] Addon installed successfully!"
echo "----------------------------------------"
echo "Addon Name: $ADDON_NAME"
echo "Behavior Pack UUID: $BP_UUID"
echo "Resource Pack UUID: $RP_UUID"
echo ""
echo "👉 Restart your Bedrock server for changes to take effect."
