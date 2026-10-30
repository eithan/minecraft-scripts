#!/bin/bash
# watchdog-server-idle.sh — sleep Bedrock server when empty, wake on connection attempt
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
# Bedrock Dedicated Server (BDS) has no built-in idle/sleep mode. It runs
# AutoCompaction and other housekeeping tasks on a fixed timer regardless of
# whether anyone is online. This script adds that behavior externally.
#
# ── HOW IT WORKS ─────────────────────────────────────────────────────────────
# ACTIVE PHASE (server is running):
#   - Follows ~/mcbedrock-server/logs/server.log in real-time for "Player connected/disconnected"
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
#   nohup bash ~/mcbedrock-server/watchdog-server-idle.sh >> /tmp/mcbedrock-watchdog.log 2>&1 &
#
# Stop the watchdog (does NOT stop the Minecraft server):
#   bash ~/mcbedrock-server/watchdog-server-idle.sh stop
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
LOG_FILE="$HOME/mcbedrock-server/logs/server.log"
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
    # Go through systemd (mcbedrock.service, Restart=on-failure): stopping/starting behind its back made systemd see
    # a failure and restart the server right after every sleep (10/30, restart counter 8).
    sudo -n systemctl start mcbedrock 2>/dev/null || bash start-server.sh
    for _ in $(seq 1 30); do
        sleep 1
        server_running && break
    done
    log "Server started (PID: $(cat "$PID_FILE" 2>/dev/null || echo '?'))"
}

stop_server() {
    log "Idle timeout reached (${IDLE_TIMEOUT}s with 0 players) — stopping server."
    cd "$SERVER_DIR"
    # Only when running outside mcbedrock.service's cgroup: `systemctl stop` kills everything in that cgroup, and a
    # watchdog started by start-server.sh at boot lives there (it would kill itself and nothing would wake the server).
    if grep -q "mcbedrock.service" /proc/self/cgroup 2>/dev/null; then
        bash stop-server.sh || true
    else
        sudo -n systemctl stop mcbedrock 2>/dev/null || bash stop-server.sh || true
    fi
    log "Server is now sleeping."
}

wait_for_client() {
    # Block until a client opens a TCP connection to PORT, then return. NetherNet clients (BDS 1.26.6x+, the only
    # transport this server accepts) knock on TCP first. Don't wake on UDP: Minecraft apps sitting on a menu
    # anywhere on the LAN broadcast UDP discovery pings on 19132 every few seconds, which woke the server right after
    # every sleep (10/30) and kept it cycling at 100% CPU through restarts.
    log "Sleeping. Listening on TCP :${PORT} for a client connection..."
    # Run nc in background so SIGTERM to this script can kill it via cleanup().
    # Only a real inbound connection wakes the server. If nc can't bind (e.g. "Address already in use" while the
    # stopped server's socket is still closing; 10/30 this woke the server 2 s after every sleep), retry.
    while true; do
        NC_ERR=$(mktemp /tmp/mcbedrock-nc-XXXX)
        nc -v -l -p "$PORT" < /dev/null > /dev/null 2> "$NC_ERR" &
        NC_TCP_PID=$!
        wait "$NC_TCP_PID" || true
        NC_TCP_PID=""
        KNOCK=$(tr '\n' ' ' < "$NC_ERR"); rm -f "$NC_ERR"
        case "$KNOCK" in *[Cc]onnection*received*|*[Cc]onnection*from*) log "Knock: $KNOCK"; break ;; esac
        sleep 5
    done
    sleep 1   # let the port free up before the server binds it
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

NC_PID=""
NC_TCP_PID=""

cleanup() {
    trap - EXIT TERM INT
    log "Watchdog exiting."
    kill "$NC_PID"     2>/dev/null || true
    kill "$NC_TCP_PID" 2>/dev/null || true
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
    # Start the idle clock now: a server that comes up (or a watchdog that starts) with nobody on would otherwise
    # never sleep until someone joins and leaves, e.g. after a wake from a LAN-discovery probe.
    IDLE_SINCE=$(date +%s)
    log "Server is up. Monitoring players... (sleeps in ${IDLE_TIMEOUT}s if nobody joins)"

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
