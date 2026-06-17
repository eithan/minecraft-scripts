#!/bin/bash

# Config
LOG_FILE="/tmp/mcbedrock.log"

# Load .env from server directory if present
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"

if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    echo "ERROR: DISCORD_WEBHOOK_URL is not set."
    echo "       Add it to $SCRIPT_DIR/.env or export it before running this script."
    echo "       Example .env line:  DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/..."
    exit 1
fi

WEBHOOK_URL="$DISCORD_WEBHOOK_URL"

# Ensure the log file exists so tail doesn't idle-loop on a missing file after reboots
touch "$LOG_FILE"

# Watch log file live for connections efficiently using kernel-level line buffering
tail -n 0 -F "$LOG_FILE" | grep --line-buffered -E "Player connected:|Player disconnected:" | while read -r LINE; do
    # Check for Joins
    if echo "$LINE" | grep -q "Player connected:"; then
        PLAYER_NAME=$(echo "$LINE" | awk -F "Player connected: " '{print $2}' | awk -F "," '{print $1}')
        
        # Extract timestamp and swap the last colon before milliseconds to a period
        RAW_TIME=$(echo "$LINE" | awk -F "]" '{print $1}' | tr -d '[' | sed 's/\([0-9]\{2\}\):\([0-9]\{3\}\)/\1.\2/')
        FORMATTED_TIME=$(date -d "${RAW_TIME%.*}" +"%I:%M%P on %m/%d/%y" 2>/dev/null || date +"%I:%M%P on %m/%d/%y")
        
        PAYLOAD="{\"content\": \"🎮 **${PLAYER_NAME}** joined the server at ${FORMATTED_TIME}!\"}"
        curl -s -H "Content-Type: application/json" -X POST -d "$PAYLOAD" "$WEBHOOK_URL"
    fi

    # Check for Leaves
    if echo "$LINE" | grep -q "Player disconnected:"; then
        PLAYER_NAME=$(echo "$LINE" | awk -F "Player disconnected: " '{print $2}' | awk -F "," '{print $1}')
        
        # Extract timestamp and swap the last colon to a period
        RAW_TIME=$(echo "$LINE" | awk -F "]" '{print $1}' | tr -d '[' | sed 's/\([0-9]\{2\}\):\([0-9]\{3\}\)/\1.\2/')
        FORMATTED_TIME=$(date -d "${RAW_TIME%.*}" +"%I:%M%P on %m/%d/%y" 2>/dev/null || date +"%I:%M%P on %m/%d/%y")
        
        PAYLOAD="{\"content\": \"🚪 **${PLAYER_NAME}** left the server at ${FORMATTED_TIME}!\"}"
        curl -s -H "Content-Type: application/json" -X POST -d "$PAYLOAD" "$WEBHOOK_URL"
    fi
done
