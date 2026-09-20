#!/bin/bash
# Move to the script's directory so relative paths work
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

# Guard against duplicate server instances
if [ -f /tmp/mcbedrock.pid ] && kill -0 "$(cat /tmp/mcbedrock.pid)" 2>/dev/null; then
    echo "Server is already running (PID: $(cat /tmp/mcbedrock.pid)). Aborting."
    exit 1
fi

# Set up the command FIFO
rm -f /tmp/mcbedrock.stdin
mkfifo /tmp/mcbedrock.stdin

# Keep the write-end of the FIFO open
tail -f /dev/null > /tmp/mcbedrock.stdin &
KEEPALIVE_PID=$!

echo "Started FIFO keepalive (PID: $KEEPALIVE_PID)"
echo "Send commands with: echo \"say hello\" > /tmp/mcbedrock.stdin"

# Start the server
export LD_LIBRARY_PATH=.
# Fixed the 2>&1 syntax here
nohup ./bedrock_server < /tmp/mcbedrock.stdin > /tmp/mcbedrock.log 2>&1 &

MC_PID=$!
echo "Minecraft Bedrock server PID: $MC_PID"

# Write PIDs for easy management
echo "$MC_PID" > /tmp/mcbedrock.pid
echo "$KEEPALIVE_PID" > /tmp/mcbedrock-keepalive.pid

# Start watchdog if it exists and isn't already running
if [ -f "$SCRIPT_DIR/watchdog-server-idle.sh" ] && ! pgrep -f "watchdog-server-idle.sh" > /dev/null 2>&1; then
    nohup bash "$SCRIPT_DIR/watchdog-server-idle.sh" >> /tmp/mcbedrock-watchdog.log 2>&1 &
    echo "Watchdog started (PID: $!)"
fi

# The Discord log monitor is managed by mc-log-monitor.service
# (WantedBy=mcbedrock.service), so systemd starts and stops it with mcbedrock.
