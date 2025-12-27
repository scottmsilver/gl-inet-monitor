# AGENTS.md

Context for AI agents working on this project.

## Project Overview

This is a network monitoring dashboard for a GL.iNet Beryl AX (MT3000) router running OpenWrt in repeater mode. It collects metrics every 5 seconds and displays them in a browser-based dashboard.

## Router Access

```bash
ssh -i ~/.ssh/your_router_key root@192.168.8.1
```

Always use this SSH key. The router is at 192.168.8.1.

## File Locations

| Local | Router | Purpose |
|-------|--------|---------|
| `dash.html` | `/www/dash.html` | Dashboard UI |
| `dash_daemon.sh` | `/root/dash_daemon.sh` | Data collector (runs continuously) |
| `dash_init.sh` | `/etc/init.d/dash_daemon` | procd service script |

## Deployment Commands

```bash
# Deploy dashboard
cat dash.html | ssh -i ~/.ssh/your_router_key root@192.168.8.1 "cat > /www/dash.html"

# Deploy daemon and restart
cat dash_daemon.sh | ssh -i ~/.ssh/your_router_key root@192.168.8.1 "cat > /root/dash_daemon.sh && chmod +x /root/dash_daemon.sh"
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "killall dash_daemon.sh 2>/dev/null; /etc/init.d/dash_daemon start"
```

## Key Technical Constraints

1. **Shell is busybox ash** - No bash features like `<<<`, arrays, or `[[`. Use POSIX sh.

2. **No sftp-server** - Use `cat file | ssh ... "cat > dest"` instead of scp.

3. **Hardware flow offload** - Standard Linux counters miss traffic. Use `iw dev wlanX station dump` for accurate byte counts.

4. **Storage in /tmp only** - It's RAM-based tmpfs. Don't write to flash. Cap history at 120 samples.

5. **procd for services** - OpenWrt uses procd, not systemd. See `dash_init.sh` for format.

## Architecture

```
dash_daemon.sh (runs every 5s)
    │
    ├── curl google.com/generate_204  → web verify latency
    ├── ping 8.8.8.8                  → ping latency
    ├── iw dev wlan0/1 station dump   → throughput (byte deltas)
    ├── iwinfo sta0 info              → uplink SSID
    │
    └── writes /www/data.json

dash.html (browser)
    │
    └── fetches /data.json every 5s → renders graphs
```

## Common Tasks

### Add a new metric

1. Add collection logic in `dash_daemon.sh` `collect_data()` function
2. Add to JSON output in the heredoc
3. Add HTML elements in `dash.html`
4. Add JS processing in `fetchData()` function
5. Add graph drawing if needed

### Debug data collection

```bash
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "cat /www/data.json"
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "ps | grep dash"
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "logread | grep dash | tail -20"
```

### Check WiFi interfaces

```bash
ssh -i ~/.ssh/your_router_key root@192.168.8.1 "iwinfo"
# sta0/sta1 = uplink (repeater client)
# wlan0/wlan1 = local AP
```

## Code Style

- **Shell**: POSIX sh, no bashisms, use awk for math
- **HTML/JS**: Vanilla JS, no frameworks, inline styles/script
- **Keep it minimal**: Router has limited resources

## Gotchas

- Browser caches aggressively - use Cmd+Shift+R to refresh
- Old daemon may keep running - always `killall dash_daemon.sh` before restart
- JSON syntax errors crash the dashboard - validate output manually if issues
- The `iw` rx/tx are from the AP's perspective (rx = upload from client)
