# Beryl AX Network Dashboard

Real-time network monitoring dashboard for GL.iNet Beryl AX (MT3000) router in repeater mode.

## What It Does

Monitors your internet connection through the Beryl AX repeater with 5-second resolution:

- **Web Verify**: HTTP 204 latency to Google (measures full TCP + HTTP round-trip)
- **Ping Latency**: ICMP ping to 8.8.8.8
- **Throughput**: Upload/download speeds via WiFi station byte counters
- **Availability**: Success/failure tracking with uptime percentage and last-success time

The dashboard shows:
- Current values, 1-minute trailing average, and p99 for each metric
- Color-coded graphs (green/yellow/red based on thresholds)
- Overall status indicator (Online/Degraded/Offline)
- Uplink WiFi network name

## Why This Approach

### The Hardware Offload Problem

The Beryl AX uses MediaTek MT7981 with hardware flow offloading (PPE - Packet Processing Engine). This means:
- Traffic bypasses the Linux kernel for performance
- Standard counters (`/proc/net/dev`, `iptables`) miss offloaded traffic
- GL.iNet's `gl-clients` API captures download but NOT upload

### The Solution

We use `iw dev wlanX station dump` which gets byte counters directly from the WiFi driver. These counters include ALL traffic regardless of offloading because the WiFi hardware must track bytes for 802.11 acknowledgments.

### Why a Daemon Instead of Cron

- Cron minimum resolution is 1 minute
- We wanted 5-second updates for responsive monitoring
- procd manages the daemon with automatic restart on failure

### Why /tmp for Storage

- `/tmp` is RAM-based tmpfs on OpenWrt
- Won't wear out flash storage
- Files cleared on reboot (intentional - we only need recent history)
- History capped at 120 samples (10 minutes) to prevent memory issues

## Installation

### Prerequisites

- GL.iNet Beryl AX (MT3000) or similar OpenWrt router
- SSH access with key authentication
- Router accessible at 192.168.8.1

### Install Steps

```bash
# Copy the daemon script
scp -i ~/.ssh/your_router_key dash_daemon.sh root@192.168.8.1:/root/

# Copy the init script
scp -i ~/.ssh/your_router_key dash_init.sh root@192.168.8.1:/etc/init.d/dash_daemon

# Copy the dashboard
scp -i ~/.ssh/your_router_key dash.html root@192.168.8.1:/www/

# SSH in and set permissions
ssh -i ~/.ssh/your_router_key root@192.168.8.1

chmod +x /root/dash_daemon.sh
chmod +x /etc/init.d/dash_daemon

# Enable and start the service
/etc/init.d/dash_daemon enable
/etc/init.d/dash_daemon start
```

### Verify Installation

```bash
# Check daemon is running
ps | grep dash_daemon

# Check data is being generated
cat /www/data.json

# View dashboard
open http://192.168.8.1/dash.html
```

## Files

| File | Location on Router | Purpose |
|------|-------------------|---------|
| `dash_daemon.sh` | `/root/dash_daemon.sh` | Data collection daemon |
| `dash_init.sh` | `/etc/init.d/dash_daemon` | procd service script |
| `dash.html` | `/www/dash.html` | Dashboard UI |

### Generated Files (in /tmp)

| File | Purpose |
|------|---------|
| `/www/data.json` | Current metrics (read by dashboard) |
| `/tmp/fetch_history.log` | Web verify latency history |
| `/tmp/thru_history.log` | Throughput history |
| `/tmp/avail_history.log` | Availability history |
| `/tmp/last_success.txt` | Timestamp of last successful check |
| `/tmp/iw_stats_cache` | Previous WiFi station byte counts |
| `/tmp/dash_daemon.pid` | Daemon PID file |

## Development

### Remote Development with Claude Code

The router is accessible via SSH with key auth. Claude Code can run commands directly:

```bash
# Run command on router
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "command here"

# Copy file to router
cat localfile | ssh -i ~/.ssh/your_router_key root@192.168.8.1 "cat > /path/on/router"

# Copy file from router
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "cat /path/on/router" > localfile
```

When working with Claude, remind it:
> "I have a GL.iNet Beryl AX router at root@192.168.8.1 accessible via SSH (key: ~/.ssh/your_router_key). Run commands on it using ssh."

### Editing the Dashboard

1. Edit `~/beryl-dashboard/dash.html` locally
2. Deploy: `cat dash.html | ssh -i ~/.ssh/your_router_key root@192.168.8.1 "cat > /www/dash.html"`
3. Hard refresh browser (Cmd+Shift+R) to bypass cache

### Editing the Daemon

1. Edit `~/beryl-dashboard/dash_daemon.sh` locally
2. Deploy and restart:
```bash
cat dash_daemon.sh | ssh -i ~/.ssh/your_router_key root@192.168.8.1 "cat > /root/dash_daemon.sh && chmod +x /root/dash_daemon.sh"
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "killall dash_daemon.sh; /etc/init.d/dash_daemon start"
```

### Debugging

```bash
# Watch daemon output
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "logread -f | grep dash"

# Check current data
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "cat /www/data.json | jq ."

# Manual test of web verify
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://www.google.com/generate_204"

# Check WiFi station stats
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "iw dev wlan0 station dump"
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "iw dev wlan1 station dump"

# Check uplink interface
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "iwinfo"
```

### Data Format

`/www/data.json` structure:
```json
{
  "ts": 1234567890,
  "interval": 5,
  "uplink_ssid": "NetworkName",
  "web": {
    "code": 204,
    "ms": 42,
    "history": [40, 38, 45, ...]
  },
  "ping": {
    "current": 9.5,
    "history": [{"t": 1234567890, "v": 9.5}, ...]
  },
  "throughput": {
    "rx_kbps": 150,
    "tx_kbps": 5200,
    "rx_history": [100, 150, ...],
    "tx_history": [5000, 5200, ...]
  },
  "avail": {
    "current": 1,
    "last_success": 1234567890,
    "history": [1, 1, 1, 0, 1, ...]
  }
}
```

## Thresholds

| Metric | Good | Warning | Bad |
|--------|------|---------|-----|
| Web Verify | < 100ms | < 300ms | >= 300ms |
| Ping | < 30ms | < 80ms | >= 80ms |
| Availability | >= 99% | >= 90% | < 90% |

## Troubleshooting

### Dashboard shows "Loading..."
- Check daemon is running: `ps | grep dash_daemon`
- Check data.json exists: `ls -la /www/data.json`
- Check for JS errors in browser console

### No throughput data
- Verify clients are connected: `iw dev wlan0 station dump`
- Check cache file: `cat /tmp/iw_stats_cache`

### Wrong uplink SSID
- Check which interface is the uplink: `iwinfo`
- The daemon checks `sta0` and `sta1` for the uplink SSID

### High memory usage
- History is capped at 120 samples per metric
- Total storage in /tmp should be < 10KB
- Check with: `ls -la /tmp/*.log /tmp/iw_*`
