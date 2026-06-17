#!/bin/bash
# Move to the script's directory so relative paths work
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

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
if [ -f "$SCRIPT_DIR/watchdog.sh" ] && ! pgrep -f "watchdog.sh" > /dev/null 2>&1; then
    nohup bash "$SCRIPT_DIR/watchdog.sh" >> /tmp/mcbedrock-watchdog.log 2>&1 &
    echo "Watchdog started (PID: $!)"
fi

# Start log monitor if it exists and isn't already running
if [ -f "$SCRIPT_DIR/log_monitor.sh" ] && ! pgrep -f "log_monitor.sh" > /dev/null 2>&1; then
    nohup bash "$SCRIPT_DIR/log_monitor.sh" >> /tmp/mcbedrock-logmonitor.log 2>&1 &
    echo "Log monitor started (PID: $!)"
fi
