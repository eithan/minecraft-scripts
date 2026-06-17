#!/bin/bash
# Installs and enables the mcbedrock and playit-bedrock systemd services.
# Run once after cloning on a new machine. Requires sudo.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing systemd service files..."
sudo cp "$SCRIPT_DIR/systemd/mcbedrock.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/playit-bedrock.service" /etc/systemd/system/

echo "Reloading systemd..."
sudo systemctl daemon-reload

echo "Enabling services (auto-start on boot)..."
sudo systemctl enable mcbedrock
sudo systemctl enable playit-bedrock

echo ""
echo "Done. Services are enabled but not started."
echo "Start them with:"
echo "  sudo systemctl start mcbedrock"
echo "  sudo systemctl start playit-bedrock"
