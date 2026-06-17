#!/bin/bash
# watchdog.sh — sleep Bedrock server when empty, wake on connection attempt
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
# Bedrock Dedicated Server (BDS) has no built-in idle/sleep mode. It runs
# AutoCompaction and other housekeeping tasks on a fixed timer regardless of
# whether anyone is online. This script adds that behavior externally.
#
# ── HOW IT WORKS ─────────────────────────────────────────────────────────────
# ACTIVE PHASE (server is running):
#   - Follows /tmp/mcbedrock.log in real-time for "Player connected/disconnected"
#   - Tracks online count; starts an idle timer when count reaches 0
#   - After IDLE_TIMEOUT seconds of 0 players, runs stop-server.sh to shut down BDS
#
# SLEEP PHASE (server is stopped):
#   - Uses `nc -u -l` to hold UDP port 19132 open and listen for packets
#   - When a Bedrock client tries to connect, it sends a UDP probe; nc catches
#     it and exits, which wakes this script and triggers start-server.sh
#   - The client will see a brief "connection failed, retrying" — Bedrock
#     retries aggressively so it typically connects on the 2nd or 3rd attempt
#     (~5–10 second delay while the server starts up)
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
# Start the watchdog (runs in background, logs to /tmp/mcbedrock-watchdog.log):
#   nohup bash ~/mcbedrock-server/watchdog.sh >> /tmp/mcbedrock-watchdog.log 2>&1 &
#
# Stop the watchdog (does NOT stop the Minecraft server):
#   bash ~/mcbedrock-server/watchdog.sh stop
#
# Watch the watchdog logs:
#   tail -f /tmp/mcbedrock-watchdog.log
#
# ── TUNING ────────────────────────────────────────────────────────────────────
# IDLE_TIMEOUT — how long (seconds) to wait after the last player leaves before
#   stopping the server. Default: 300 (5 minutes). Increase if players tend to
#   rejoin quickly after dropping.
#
# TICK_INTERVAL — how often the idle countdown is checked. Default: 15s.
#   Lowering this makes the shutdown more punctual but isn't usually necessary.
#
# PORT — must match `server-port` in server.properties. Default: 19132.
#
# ── CAVEATS ───────────────────────────────────────────────────────────────────
# - The watchdog is NOT wired into start-server.sh — run it separately if you want
#   the sleep behavior. The server runs normally without it.
# - If the watchdog is stopped while the server is running, the server keeps
#   running unaffected.
# - If the server crashes, the watchdog will enter sleep phase and restart it
#   on the next client connection (acts as a basic crash recovery too).
# - The nc trick squats on UDP 19132 while BDS is down. Nothing else should
#   bind that port while the server is stopped, so this is safe.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/tmp/mcbedrock.log"
PID_FILE="/tmp/mcbedrock.pid"
WATCHDOG_PID_FILE="/tmp/mcbedrock-watchdog.pid"
PORT=19132        # Bedrock default UDP port
IDLE_TIMEOUT=300  # seconds of 0-player idle before sleeping (5 min)
TICK_INTERVAL=15  # seconds between idle-timeout checks

log() { echo "[watchdog $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

server_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start_server() {
    log "Starting Bedrock server..."
    cd "$SERVER_DIR"
    bash start-server.sh
    for _ in $(seq 1 30); do
        sleep 1
        server_running && break
    done
    log "Server started (PID: $(cat "$PID_FILE" 2>/dev/null || echo '?'))"
}

stop_server() {
    log "Idle timeout reached (${IDLE_TIMEOUT}s with 0 players) — stopping server."
    cd "$SERVER_DIR"
    bash stop-server.sh || true
    log "Server is now sleeping."
}

wait_for_client() {
    # Block until a UDP packet arrives on PORT, then return.
    # The connecting Bedrock client retries aggressively, so missing one packet is fine.
    log "Sleeping. Listening on UDP :${PORT} for a client connection..."
    nc -u -l -p "$PORT" > /dev/null 2>&1 || true
}

# ── stop argument ─────────────────────────────────────────────────────────────
if [ "${1-}" = "stop" ]; then
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        WD_PID=$(cat "$WATCHDOG_PID_FILE")
        kill "$WD_PID" 2>/dev/null \
            && log "Watchdog (PID $WD_PID) stopped." \
            || log "Watchdog already gone."
        rm -f "$WATCHDOG_PID_FILE"
    else
        echo "No watchdog PID file found."
    fi
    exit 0
fi

# ── startup ───────────────────────────────────────────────────────────────────
echo $$ > "$WATCHDOG_PID_FILE"
log "Watchdog started (PID $$). Idle timeout: ${IDLE_TIMEOUT}s, tick: ${TICK_INTERVAL}s."

cleanup() {
    log "Watchdog exiting."
    kill "$TICKER_PID" 2>/dev/null || true
    kill "$TAIL_PID"   2>/dev/null || true
    rm -f "$WATCHDOG_PID_FILE"
}
trap cleanup EXIT TERM INT

# ── outer loop: sleep ↔ active ────────────────────────────────────────────────
while true; do

    # ── SLEEP PHASE ────────────────────────────────────────────────────────────
    while ! server_running; do
        wait_for_client
        log "Client probe detected — waking server."
        start_server
    done

    # ── ACTIVE PHASE ───────────────────────────────────────────────────────────
    ONLINE_COUNT=0
    IDLE_SINCE=0
    log "Server is up. Monitoring players..."

    # Background tick generator — writes a sentinel every TICK_INTERVAL seconds
    # so our read loop wakes up even when the log has no new lines.
    TICK_FIFO=$(mktemp -u /tmp/mcbedrock-tick-XXXX)
    mkfifo "$TICK_FIFO"

    { while true; do sleep "$TICK_INTERVAL"; echo "__TICK__"; done; } > "$TICK_FIFO" &
    TICKER_PID=$!

    # Merge tail -F (log) and the tick FIFO into one stream via process substitution.
    # Both run in the SAME shell so variables are shared — no subshell scoping issues.
    tail -F -n 0 "$LOG_FILE" > "$TICK_FIFO" &
    TAIL_PID=$!

    while IFS= read -r line; do

        case "$line" in

            __TICK__)
                # Periodic idle check
                if ! server_running; then
                    log "Server process gone — exiting monitor loop."
                    break
                fi
                if [ "$ONLINE_COUNT" -eq 0 ] && [ "$IDLE_SINCE" -gt 0 ]; then
                    NOW=$(date +%s)
                    IDLE_SECS=$(( NOW - IDLE_SINCE ))
                    REMAINING=$(( IDLE_TIMEOUT - IDLE_SECS ))
                    if [ "$IDLE_SECS" -ge "$IDLE_TIMEOUT" ]; then
                        stop_server
                        break
                    else
                        log "Still idle... sleeping in ${REMAINING}s if no players join."
                    fi
                fi
                ;;

            *"Player connected:"*)
                ONLINE_COUNT=$(( ONLINE_COUNT + 1 ))
                IDLE_SINCE=0
                PLAYER=$(echo "$line" | grep -oP "Player connected: \K[^,]+")
                log "Player joined: ${PLAYER:-unknown} → online: $ONLINE_COUNT"
                ;;

            *"Player disconnected:"*)
                ONLINE_COUNT=$(( ONLINE_COUNT > 0 ? ONLINE_COUNT - 1 : 0 ))
                PLAYER=$(echo "$line" | grep -oP "Player disconnected: \K[^,]+")
                log "Player left: ${PLAYER:-unknown} → online: $ONLINE_COUNT"
                if [ "$ONLINE_COUNT" -eq 0 ]; then
                    IDLE_SINCE=$(date +%s)
                    log "Server empty. Will sleep in ${IDLE_TIMEOUT}s if no one joins."
                fi
                ;;

        esac

    done < "$TICK_FIFO"

    # Clean up ticker and tail for this active phase
    kill "$TICKER_PID" 2>/dev/null || true
    kill "$TAIL_PID"   2>/dev/null || true
    wait "$TICKER_PID" "$TAIL_PID" 2>/dev/null || true
    rm -f "$TICK_FIFO"
    TICKER_PID=0
    TAIL_PID=0

done
