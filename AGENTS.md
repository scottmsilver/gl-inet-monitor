# AGENTS.md

Context for AI agents working on this project.

## Project Overview

This is a network monitoring dashboard for a GL.iNet Beryl AX (MT3000) router running in repeater mode. It collects metrics every 5 seconds and displays them in a browser-based dashboard.

**Firmware:** GL.iNet vendor OpenWrt 4.8.1 (kernel 5.4.211, MediaTek SDK driver). Switched from vanilla OpenWrt 24.10.4 because the upstream `mt7915e` driver caused random reboots (OpenWrt issue #18285). The vendor build uses MediaTek interface names and the proprietary driver — see notes below; some tooling differs from vanilla.

## Router Access

```bash
ssh -i ~/.ssh/beryl_ax root@192.168.8.1
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
cat dash.html | ssh -i ~/.ssh/beryl_ax root@192.168.8.1 "cat > /www/dash.html"

# Deploy daemon and restart
cat dash_daemon.sh | ssh -i ~/.ssh/beryl_ax root@192.168.8.1 "cat > /root/dash_daemon.sh && chmod +x /root/dash_daemon.sh"
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 "killall dash_daemon.sh 2>/dev/null; /etc/init.d/dash_daemon start"
```

## Key Technical Constraints

1. **Shell is busybox ash** - No bash features like `<<<`, arrays, or `[[`. Use POSIX sh.

2. **No sftp-server** - Use `cat file | ssh ... "cat > dest"` instead of scp.

3. **Hardware flow offload (WED)** - Standard Linux counters (`/proc/net/dev`) MISS offloaded traffic: the uplink RX counter reads 0 during a multi-Mbps download. For throughput, use GL's own per-client accounting: `ubus call gl-clients get_speed` (returns `speed_rx`=download, `speed_tx`=upload, bytes/sec). On vanilla OpenWrt the equivalent was `iw dev wlanX station dump` (the `iw` binary is absent on vendor firmware). `probe_throughput` falls back to `/proc/net/dev` only when `gl-clients` is unavailable.

4. **Storage** - `/tmp` is RAM-based tmpfs; cap live history at 120 samples there. Persistent reboot-forensic logs (heartbeat, boot record, snapshots) intentionally write to `/overlay/upper/root` (UBIFS flash) so they survive a reboot — writes are tiny and rate-limited to stay well under flash wear limits.

5. **procd for services** - OpenWrt uses procd, not systemd. See `dash_init.sh` for format.

## Architecture

```
dash_daemon.sh (runs every 5s)
    │
    ├── curl google.com/generate_204    → web verify latency
    ├── ping www.google.com             → ping latency (anycast IPs blocked on some networks)
    ├── ubus call gl-clients get_speed  → throughput (offload-aware)
    ├── iwinfo apclix0/apcli0 info      → uplink SSID (vendor names; sta0/sta1 on vanilla)
    ├── ubus call gl-clients list       → per-client tx/rx
    └── writes /www/data.json (+ reboot forensics to /overlay/upper/root)

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
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 "cat /www/data.json"
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 "ps | grep dash"
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 "logread | grep dash | tail -20"
```

### Check WiFi interfaces

```bash
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 "iwinfo"
# Vendor firmware (current): apclix0/apcli0 = uplink (5G/2.4G repeater client),
#                            rax0/rax1/ra0/ra1 = local AP
# Vanilla OpenWrt:           sta0/sta1 = uplink, wlan0/wlan1 = local AP
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
