#!/bin/bash
# Updates Minecraft Bedrock Dedicated Server to the latest version.
# Preserves: worlds, server.properties, allowlist.json, permissions.json,
#            behavior/resource packs, config, and custom scripts.

set -euo pipefail
cd "$(dirname "$0")"
SERVER_DIR="$(pwd)"

PRESERVE=(
    worlds
    server.properties
    allowlist.json
    permissions.json
    behavior_packs
    resource_packs
    development_behavior_packs
    development_resource_packs
    development_skin_packs
    config
    start-server.sh
    stop-server.sh
    watchdog-server-idle.sh
    log-monitor-discord.sh
    install-mcaddon.sh
    playit
)

API_URL="https://net-secondary.web.minecraft-services.net/api/v1.0/download/links"
BACKUP_ROOT="$HOME/minecraft-worlds-backup"

echo "=== Minecraft Bedrock Server Updater ==="
echo ""

# 1. Fetch download links from Mojang API
echo "[1/6] Fetching latest version info from Mojang..."
API_RESPONSE=$(curl -sf -A "Mozilla/5.0" "$API_URL" 2>&1) || {
    echo "ERROR: Failed to reach Mojang API ($API_URL)"
    echo "       Check your internet connection and try again."
    exit 1
}

DOWNLOAD_URL=$(echo "$API_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
links = data['result']['links']
match = next((l['downloadUrl'] for l in links if l['downloadType'] == 'serverBedrockLinux'), None)
print(match or '')
" 2>/dev/null)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "ERROR: Could not parse Linux download URL from API response."
    echo "       Raw response: $API_RESPONSE"
    exit 1
fi

NEW_VERSION=$(echo "$DOWNLOAD_URL" | grep -oP '\d+\.\d+\.\d+\.\d+')
echo "       Latest version : $NEW_VERSION"
echo "       Download URL   : $DOWNLOAD_URL"

# 2. Check current version
echo ""
echo "[2/6] Checking current installed version..."
CURRENT_VERSION=""
if [ -f bedrock_server ]; then
    CURRENT_VERSION=$(strings bedrock_server 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
fi
echo "       Current version: ${CURRENT_VERSION:-unknown}"

if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
    echo ""
    echo "Already on the latest version ($CURRENT_VERSION). Nothing to do."
    exit 0
fi

echo "       --> Will update: ${CURRENT_VERSION:-unknown} -> $NEW_VERSION"

# 3. Stop server if running
echo ""
echo "[3/6] Checking if server is running..."
if [ -f /tmp/mcbedrock.pid ] && kill -0 "$(cat /tmp/mcbedrock.pid)" 2>/dev/null; then
    echo "       Server is running (PID $(cat /tmp/mcbedrock.pid)). Stopping it..."
    bash stop-server.sh
    echo "       Server stopped."
else
    echo "       Server is not running. Continuing."
fi

# 4. Back up preserved items
echo ""
echo "[4/6] Backing up your data..."
BACKUP_DIR="$BACKUP_ROOT/$(date '+%Y-%m-%d_%H-%M-%S')"
mkdir -p "$BACKUP_DIR"
echo "       Backup location: $BACKUP_DIR"
BACKED_UP=()
for item in "${PRESERVE[@]}"; do
    if [ -e "$SERVER_DIR/$item" ]; then
        cp -a "$SERVER_DIR/$item" "$BACKUP_DIR/"
        BACKED_UP+=("$item")
    fi
done
echo "       Backed up: ${BACKED_UP[*]}"

# 5. Download new server zip
echo ""
echo "[5/6] Downloading bedrock-server-${NEW_VERSION}.zip..."
ZIP_FILE=$(mktemp --suffix=.zip)
curl -L --progress-bar -A "Mozilla/5.0" -o "$ZIP_FILE" "$DOWNLOAD_URL"
echo "       Download complete: $(du -h "$ZIP_FILE" | cut -f1)"

echo "       Extracting..."
STAGING_DIR=$(mktemp -d)
unzip -q "$ZIP_FILE" -d "$STAGING_DIR"
rm -f "$ZIP_FILE"
echo "       Copying new server files..."
cp -a "$STAGING_DIR"/. "$SERVER_DIR/"
rm -rf "$STAGING_DIR"

# 6. Restore preserved items
echo ""
echo "[6/6] Restoring your data..."
for item in "${BACKED_UP[@]}"; do
    rm -rf "$SERVER_DIR/$item"
    cp -a "$BACKUP_DIR/$item" "$SERVER_DIR/$item"
    echo "       Restored: $item"
done
chmod +x "$SERVER_DIR/bedrock_server"

echo ""
echo "=== Update complete: $NEW_VERSION ==="
echo "Backup saved to: $BACKUP_DIR"
echo "Run ./start-server.sh to start the server."
