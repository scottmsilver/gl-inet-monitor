# dash_collector (Rust) — additive native data provider

A native Rust reimplementation of `dash_daemon.sh` — the **full replacement**:
both the live-metrics hot path (`/www/data.json`) **and** the reboot forensics
(heartbeat, boot record, `reboots.json`, syslog tail). Runs under procd via
`dash_collector.init`.

It can also run **additively** for validation: with `DASH2_JSON_OUT`,
`DASH2_PERSIST_DIR` and `DASH2_REBOOTS_OUT` pointed at parallel paths it writes
alongside the shell daemon without touching its files — which is how every part
was validated side-by-side before cutover.

## Design — structured interfaces, no text scraping

Brittleness comes from parsing unstructured CLI text. This collector avoids it:

- **ubus JSON** for wifi SSID (`iwinfo info`), throughput (`gl-clients get_speed`)
  and clients (`gl-clients list`) — deserialized into typed structs with serde.
- **std-only HTTP/1.0 GET** (`TcpStream`, ~25 lines, no TLS, no `curl`) for the
  `generate_204` reachability check and the ip-api ISP/ASN lookup. Both endpoints
  are plain HTTP; `ip-api.com` with no IP returns the requester's own IP + ISP,
  so one call covers external-IP + classification.
- **TCP connect-time RTT** (`TcpStream::connect_timeout` + `Instant`) for latency,
  in place of ICMP/`ping`. TCP reaches where ICMP is often dropped
  (captive/airplane/satellite), so it's both dependency-free and a better signal.
- **No `json_escape`** — serde escapes strings on serialize.
- **One `run → parse → Option<T> → sentinel` pipeline**; any external-call
  surprise (spawn fail, non-zero exit, malformed JSON, connect fail) degrades to
  a sentinel that the schema-with-defaults fills. A format change yields
  "unknown", never wrong data or a crash. The subprocess/socket boundary also
  isolates crashes from the collector.

**External CLI dependency: only `ubus`** (the sole interface to `ubusd`; there
is no `libgl-clients`, so this is unavoidable). Everything else is std + kernel
(TCP sockets, `/proc`).

### Source layout
```
src/main.rs      crate docs, config, the collect_data orchestrator, main loop
src/schema.rs    output document types (DataDoc + sections) — pure data, no logic
src/io.rs        all outside-world I/O: ubus_call, std HTTP GET, TCP RTT + input contracts
src/classify.rs  ISP/ASN -> connection class + the field-editable ASN data file
src/probes.rs    one function per metric (+ detect_uplink, name resolution)
src/state.rs     rolling histories + carry-over, snapshotted to one file
src/forensics.rs heartbeat/snapshot/boot-record/shutdown/syslog-tail + reboots.json
dash_collector.init   procd service script (install as /etc/init.d/dash_collector)
```
Each module carries `//!`/`///` doc comments (run `cargo doc --open`). Unit
tests live beside the code they cover.

### Why shell out to `ubus` instead of linking `libubus`?
The CLI/JSON contract is the *more* stable, lower-risk interface here: `libubus`/
`libubox` are versioned sonames with no dev headers on the device (linking needs
the matching OpenWrt SDK and breaks on a soname bump), the `ubus` CLI is
guaranteed present and version-matched by the firmware, `gl-clients` has no C
library at all, and the subprocess boundary keeps "degrade to sentinel" robust.
At a 5 s cadence the fork/exec cost is irrelevant.

### Classification data file (field-updatable)
ASN→class is **data that grows in the field** (new airlines, cruise ISPs), so it
lives in an optional JSON file you can edit over SSH and that reloads each
detection cycle (~60 s) with no restart:

```
/root/dash2_asn.json   (override via DASH2_ASN_FILE)
{ "14593": "starlink", "21928": "airplane", "64500": "airplane", ... }
```

Entries **merge over** an embedded baseline (see `dash2_asn.example.json`); a
missing/invalid file just leaves the baseline, so classification never fails.
The fuzzy keyword/regex heuristics (e.g. `PANASONIC…AVIONIC`) stay in code —
they're logic, not data.

### History
120-sample histories live in memory (`VecDeque`) and are snapshotted to the one
state file each cycle, so they survive a collector restart.

## Build

Static `aarch64-unknown-linux-musl`, no Docker:

```sh
brew install zig
cargo install cargo-zigbuild
rustup target add aarch64-unknown-linux-musl
cargo zigbuild --release --target aarch64-unknown-linux-musl
```

(or `cross build --release --target aarch64-unknown-linux-musl` with Docker.)
Result: `target/aarch64-unknown-linux-musl/release/dash_collector` —
**~557 KB, ELF aarch64, statically linked, stripped**, no TLS stack.

## Test

```sh
cargo test     # 13 tests: classification (+ data-file overlay/fallback),
               # thresholds, avail, typed parsing of real device JSON fixtures,
               # client cross-map, name resolution, history cap/peak
```

## Deploy (parallel to the shell daemon — does NOT disturb it)

```sh
cat target/aarch64-unknown-linux-musl/release/dash_collector \
  | ssh -i ~/.ssh/beryl_ax root@192.168.8.1 \
    "cat > /root/dash_collector && chmod +x /root/dash_collector"

ssh -i ~/.ssh/beryl_ax root@192.168.8.1 "/root/dash_collector --once"   # one-shot
# or run the 5s loop:  /root/dash_collector >/tmp/dash2.out 2>&1 &
```

Overrides: `DASH2_JSON_OUT`, `DASH2_STATE_FILE`, `DASH2_ASN_FILE`,
`WIFI_IFACES`, `PROC_NET_DEV`.

## Validation status

**Device-validated (side-by-side vs the live shell daemon):** identical
top-level + nested key order; deterministic fields match exactly (uplink_ssid,
connection_type, isp, thresholds, web.code, avail, throughput.source,
clients.online, and per-client mac/name/ip/iface). Time-varying fields (ts,
web.ms, latency, throughput, histories) are correct in kind and track within the
sampling gap — including throughput via the offload-aware `gl-clients` source.
`cargo test` 13/13. Note `ping.current` is now TCP-connect latency, not ICMP
(intentional — see Design).
