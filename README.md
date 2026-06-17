# Minecraft Bedrock Server Scripts

Custom scripts and systemd services for running a Minecraft Bedrock Dedicated Server on Ubuntu.

Server lives at: `~/mcbedrock-server/`

---

## Scripts

| File | Purpose |
|---|---|
| `start.sh` | Starts the server, watchdog, and log monitor |
| `stop.sh` | Gracefully stops the server via the command FIFO |
| `watchdog.sh` | Shuts server down after 5min idle; wakes it on client connection |
| `log_monitor.sh` | Sends Discord notifications on player join/leave |
| `install-mcaddon.sh` | Installs a `.mcaddon` file into the server's pack directories |
| `update-server.sh` | Downloads the latest Bedrock server binary from Mojang and upgrades in-place |
| `setup-services.sh` | Installs and enables the systemd services (run once on a new machine) |

---

## First-time Setup

### 1. Install the Bedrock server

Download the latest Linux zip from https://www.minecraft.net/en-us/download/server/bedrock, extract to `~/mcbedrock-server/`, then copy these scripts there:

```bash
cp *.sh ~/mcbedrock-server/
chmod +x ~/mcbedrock-server/*.sh
```

### 2. Set up credentials

```bash
cp .env.example ~/mcbedrock-server/.env
# Edit .env and fill in your Discord webhook URL
nano ~/mcbedrock-server/.env
```

### 3. Download the playit binary

Download the latest `playit` binary from https://playit.gg, place it at `~/mcbedrock-server/playit`, and make it executable:

```bash
chmod +x ~/mcbedrock-server/playit
```

### 4. Install systemd services

```bash
sudo bash setup-services.sh
```

Then start them:

```bash
sudo systemctl start mcbedrock
sudo systemctl start playit-bedrock
```

On first run you may need to authenticate playit via the playit.gg website — check the output with:

```bash
sudo journalctl -u playit-bedrock -f
```

---

## How It Works

**Starting the server:**
```bash
sudo systemctl start mcbedrock   # via systemd (auto-starts on boot)
# or manually:
bash ~/mcbedrock-server/start.sh
```

`start.sh` also auto-launches `watchdog.sh` and `log_monitor.sh` in the background if they are present and not already running.

**Stopping the server:**
```bash
sudo systemctl stop mcbedrock
# or manually:
bash ~/mcbedrock-server/stop.sh
```

**Sending commands to the running server:**
```bash
echo "say Hello!" > /tmp/mcbedrock.stdin
echo "list" > /tmp/mcbedrock.stdin
```

**Watching the server log:**
```bash
tail -f /tmp/mcbedrock.log
```

**Watchdog behavior:**
- Monitors player count in real-time
- Shuts the server down after 5 minutes with 0 players
- Listens on UDP 19132 while stopped; wakes the server when a client connects
- Also acts as basic crash recovery

**Updating the server:**
```bash
bash ~/mcbedrock-server/update-server.sh
```
Backs up everything to `~/minecraft-worlds-backup/YYYY-MM-DD_HH-MM-SS/` before upgrading.

---

## Key File Locations

| Path | Description |
|---|---|
| `~/mcbedrock-server/` | Server root |
| `~/mcbedrock-server/.env` | Secret credentials (not in git) |
| `~/mcbedrock-server/worlds/` | World save data |
| `~/mcbedrock-server/server.properties` | Server configuration |
| `~/minecraft-worlds-backup/` | Rolling update backups |
| `/tmp/mcbedrock.log` | Live server log |
| `/tmp/mcbedrock.stdin` | FIFO for sending commands to the server |
| `/tmp/mcbedrock.pid` | Server process PID |
| `/tmp/mcbedrock-watchdog.pid` | Watchdog process PID |
