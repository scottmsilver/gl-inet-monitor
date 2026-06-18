# AGENTS.md

Context for AI agents working on this project.

## Project Overview

A network monitoring dashboard for a GL.iNet Beryl AX (MT3000) travel router in
repeater mode. A daemon collects metrics every 5 s and writes JSON that
browser dashboards render.

**Firmware:** GL.iNet vendor OpenWrt 4.8.1 (kernel 5.4.211, MediaTek SDK driver).
Switched from vanilla OpenWrt 24.10.4 because the upstream `mt7915e` driver
caused random reboots (OpenWrt issue #18285). The vendor build uses MediaTek
interface names and the proprietary driver. (Note: the reboots still recur
intermittently and appear to be hardware/power-class — no in-SoC cause recorded.)

## Router Access

```bash
ssh -i ~/.ssh/beryl_ax root@192.168.8.1   # always this key; router at 192.168.8.1
```

## Architecture

The data collector is **`collector-rs/`** — a native Rust daemon (full
replacement of the old shell `dash_daemon.sh`, which is retired; see git history
if ever needed). It owns both the live metrics **and** the reboot forensics. The
detailed design lives in **`collector-rs/README.md`** — read it first.

```
dash_collector (Rust, runs every 5s, procd service)
    ├── std HTTP GET google /generate_204   → web reachability + latency
    ├── raw-socket ICMP echo                → ping RTT (own impl; no `ping` binary)
    ├── ubus call gl-clients get_speed      → throughput (offload-aware)
    ├── ubus call gl-clients list           → per-client tx/rx
    ├── ubus call iwinfo info               → uplink SSID
    ├── /dev/mem + /proc + dmesg/pstore     → reboot forensics
    ├── writes /www/data.json               → live dashboard
    └── writes /www/reboots.json + /overlay/upper/root/dash_* → forensics

dash2.html (browser) → fetches /data.json   → live graphs
dash3.html (browser) → fetches /reboots.json → reboot history + telemetry
```

## File Locations

| Local | Router | Purpose |
|-------|--------|---------|
| `collector-rs/` (→ `dash_collector` binary) | `/root/dash_collector` | Data collector + forensics |
| `collector-rs/dash_collector.init` | `/etc/init.d/dash_collector` | procd service |
| `dash2.html` | `/www/dash2.html` | Live dashboard UI |
| `dash3.html` | `/www/dash3.html` | Reboot-forensics UI |
| (on device only) | `/root/dash_net_persist.sh` | Re-asserts tailscale DNS/routes + dnsmasq/firewall after reboot (boot hook + 5-min cron) |

## Deployment

```bash
# Collector: build static aarch64-musl, then pipe over ssh (no scp on device)
cd collector-rs && cargo zigbuild --release --target aarch64-unknown-linux-musl
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 '/etc/init.d/dash_collector stop; killall dash_collector 2>/dev/null'
cat target/aarch64-unknown-linux-musl/release/dash_collector \
  | ssh -i ~/.ssh/beryl_ax root@192.168.8.1 'cat > /root/dash_collector && chmod +x /root/dash_collector && /etc/init.d/dash_collector start'

# Dashboard
cat dash2.html | ssh -i ~/.ssh/beryl_ax root@192.168.8.1 'cat > /www/dash2.html'
```
(Can't overwrite the running binary — stop it first, hence the `killall`.)

## Key Technical Constraints

1. **busybox ash** — POSIX sh only (no `<<<`, arrays, `[[`).
2. **No sftp/scp** — use `cat file | ssh … 'cat > dest'`.
3. **Hardware flow offload (WED)** — `/proc/net/dev` counters MISS offloaded
   traffic (uplink RX reads 0 during a multi-Mbps download). Use
   `ubus call gl-clients get_speed` (`speed_rx`=download, `speed_tx`=upload, B/s).
4. **Transparent proxy on captive/resort wifi** — fakes TCP-connect latency low
   (~3 ms over a real ~750 ms link). Measure latency with ICMP, not TCP connect.
5. **Storage** — `/tmp` is tmpfs (cap history ~120 samples). Forensic logs write
   to `/overlay/upper/root` (== `/root` via overlayfs; UBIFS flash, survives reboot).
6. **procd** for services (not systemd). `/dev/mem` is usable (no `STRICT_DEVMEM`).
7. **Only external CLI the collector uses is `ubus`** — everything else is std +
   kernel (sockets, `/proc`, `/dev/mem` via libc).

## Common Tasks

- **Add a metric:** add a field to the schema struct in `collector-rs/src/schema.rs`,
  a `probe_*` in `src/probes.rs`, wire it in `collect_data` (`src/main.rs`), then
  render it in `dash2.html`. `cargo test` + cross-compile + deploy.
- **Debug:** `ssh … 'logread | grep dash_collector | tail'`, `cat /www/data.json`,
  `cat /www/reboots.json`, boot records in `/root/dash_boot.log`.
- **WiFi interfaces:** `ssh … iwinfo` — vendor: `apclix0`/`apcli0` = uplink (5G/2.4G
  client), `rax0`/`rax1`/`ra0`/`ra1` = local AP. Vanilla: `sta0`/`sta1`, `wlan0`/`wlan1`.
- **Tailscale DNS/routing:** the Beryl forwards tailnet + home split-DNS domains
  to MagicDNS/the home firewall via dnsmasq, and masquerades LAN→tailnet. These
  reset on reboot (GL re-runs `tailscale up`); `dash_net_persist.sh` re-asserts them.

## Gotchas

- Browser caches aggressively — Cmd+Shift+R.
- Can't overwrite a running binary (`Text file busy`) — stop the service first.
- Reboots wipe `/tmp` and reset Tailscale prefs; persistent config lives in uci +
  `/overlay`, and `dash_net_persist.sh` restores the Tailscale bits.
