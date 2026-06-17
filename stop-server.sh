#!/bin/bash
# Move to the script's directory
cd "$(dirname "$0")"

# File paths (must match start-server.sh)
PID_FILE="/tmp/mcbedrock.pid"
KEEPALIVE_PID_FILE="/tmp/mcbedrock-keepalive.pid"
FIFO_FILE="/tmp/mcbedrock.stdin"

if [ ! -f "$PID_FILE" ]; then
    echo "Error: $PID_FILE not found. Is the server running?"
    exit 1
fi

MC_PID=$(cat "$PID_FILE")
KEEPALIVE_PID=$(cat "$KEEPALIVE_PID_FILE")

echo "Sending 'stop' command to Bedrock server (PID: $MC_PID)..."

# 1. Send the stop command through the pipe
if [ -p "$FIFO_FILE" ]; then
    echo "stop" > "$FIFO_FILE"
else
    echo "Warning: FIFO not found. Attempting to kill process $MC_PID instead."
    kill "$MC_PID"
fi

# 2. Wait for the server to actually shut down
echo -n "Waiting for server to save world and exit..."
while kill -0 "$MC_PID" 2>/dev/null; do
    echo -n "."
    sleep 1
done
echo -e "\nServer stopped."

# 3. Clean up the keepalive process (the 'tail' command)
if kill -0 "$KEEPALIVE_PID" 2>/dev/null; then
    kill "$KEEPALIVE_PID"
    echo "Keepalive process terminated."
fi

# 4. Clean up files
rm -f "$PID_FILE" "$KEEPALIVE_PID_FILE" "$FIFO_FILE"
echo "Cleanup complete."
