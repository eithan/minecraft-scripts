#!/bin/bash
# Convenience wrapper: stops the mcbedrock service, runs update-server.sh,
# then starts it back up.

set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x ./update-server.sh ]; then
    echo "ERROR: update-server.sh not found or not executable in $(pwd)"
    exit 1
fi

echo "=== ez-update-server ==="
echo ""

echo "[1/3] Stopping mcbedrock service..."
sudo systemctl stop mcbedrock

echo ""
echo "[2/3] Running update-server.sh..."
bash ./update-server.sh

echo ""
echo "[3/3] Starting mcbedrock service..."
sudo systemctl start mcbedrock

echo ""
echo "=== Done. Check status with: sudo systemctl status mcbedrock ==="
