#!/bin/bash

# --- CONFIGURATION ---
SERVER_DIR="$HOME/mcbedrock-server"
SERVICE_NAME="mcbedrock.service"
WORLD_NAME="Bedrock level"

# --- VALIDATION ---
if [ -z "$1" ]; then
    echo "❌ Error: Please provide the pretty name of the addon."
    echo "Usage: $0 <prettyname>"
    exit 1
fi

PRETTY_NAME="$1"
BP_FOLDER="${PRETTY_NAME}_bp"
RP_FOLDER="${PRETTY_NAME}_rp"

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: Please run this script with sudo."
    exit 1
fi

cd "$SERVER_DIR" || { echo "❌ Error: Server directory not found."; exit 1; }

# Helper function to extract UUID from manifest.json
get_uuid() {
    local manifest_path="$1"
    if [ -f "$manifest_path" ]; then
        # Extracts the UUID under the "header" object
        jq -r '.header.uuid' "$manifest_path" 2>/dev/null
    else
        echo ""
    fi
}

# Helper function to remove a specific UUID from world pack JSONs
remove_uuid_from_json() {
    local json_path="$1"
    local target_uuid="$2"
    if [ -f "$json_path" ] && [ -n "$target_uuid" ] && [ "$target_uuid" != "null" ]; then
        # Creates a temp file, filters out the target UUID object, and overwrites the original
        jq --arg uuid "$target_uuid" 'map(select(.pack_id != $uuid))' "$json_path" > "${json_path}.tmp" && mv "${json_path}.tmp" "$json_path"
        echo "✅ Cleared UUID $target_uuid from $(basename "$json_path")"
    fi
}

# --- STEP 1: STOP SERVER ---
echo "🛑 Stopping $SERVICE_NAME..."
systemctl stop "$SERVICE_NAME"

# --- STEP 2: EXTRACT UUIDS & DELETE PACKS ---
BP_UUID=""
RP_UUID=""
WORLD_DIR="worlds/$WORLD_NAME"

# Process Behavior Pack
if [ -d "behavior_packs/$BP_FOLDER" ]; then
    BP_UUID=$(get_uuid "behavior_packs/$BP_FOLDER/manifest.json")
    echo "🔍 Found Behavior Pack UUID: $BP_UUID"
    rm -rf "behavior_packs/$BP_FOLDER"
    echo "🗑️  Deleted behavior_packs/$BP_FOLDER"
else
    echo "⚠️  Behavior pack folder '$BP_FOLDER' not found. Skipping."
fi

# Process Resource Pack
if [ -d "resource_packs/$RP_FOLDER" ]; then
    RP_UUID=$(get_uuid "resource_packs/$RP_FOLDER/manifest.json")
    echo "🔍 Found Resource Pack UUID: $RP_UUID"
    rm -rf "resource_packs/$RP_FOLDER"
    echo "🗑️  Deleted resource_packs/$RP_FOLDER"
else
    echo "⚠️  Resource pack folder '$RP_FOLDER' not found. Skipping."
fi

# --- STEP 3: CLEAN WORLD CONFIGURATIONS ---
if [ -d "$WORLD_DIR" ]; then
    echo "⚙️  Selectively removing addon entries from world JSONs..."
    remove_uuid_from_json "$WORLD_DIR/world_behavior_packs.json" "$BP_UUID"
    remove_uuid_from_json "$WORLD_DIR/world_resource_packs.json" "$RP_UUID"
else
    echo "⚠️  Warning: World directory '$WORLD_DIR' not found. Skipping JSON cleanup."
fi

# --- STEP 4: RESTART SERVER ---
echo "🚀 Restarting $SERVICE_NAME..."
systemctl start "$SERVICE_NAME"
echo "🎉 Done!"
