//! One function per metric. Each consumes a structured interface from
//! [`crate::io`] and returns a typed value or its sentinel, so a failed or
//! surprising response degrades gracefully rather than producing wrong data.

use crate::classify::{classify_connection, load_asn_map, thresholds_for};
use crate::io::{self, ClientRaw, ClientsList, GetSpeed, IpApi, IwInfo};
use crate::log;
use crate::schema::{ClientEntry, Uplink};
use crate::state::State;
use crate::UPLINK_DETECT_INTERVAL;
use std::time::Duration;

/// dnsmasq lease file, read for client hostname resolution (best-effort).
const DHCP_LEASES: &str = "/tmp/dhcp.leases";

/// SSID of the uplink, via the `ubus iwinfo` JSON interface. Tries vendor iface
/// names (apclix0/apcli0) then vanilla (sta0/sta1); `"Not connected"` sentinel.
pub(crate) fn probe_uplink_ssid() -> String {
    for iface in ["apclix0", "apcli0", "sta0", "sta1"] {
        let arg = format!("{{\"device\":\"{}\"}}", iface);
        if let Some(info) = io::ubus_call::<IwInfo>("iwinfo", "info", &arg) {
            if !info.ssid.is_empty() && info.ssid != "unknown" {
                return info.ssid;
            }
        }
    }
    "Not connected".to_string()
}

/// Web reachability + round-trip latency via the std HTTP GET. A 204 to
/// `generate_204` is the success contract. Sentinels: code 0, ms -1.
pub(crate) fn probe_web(now: i64) -> (i64, i64) {
    let path = format!("/generate_204?{}", now);
    match io::http_get("www.google.com", 80, &path, Duration::from_secs(5)) {
        Some((204, _, elapsed)) => (204, elapsed.as_millis() as i64),
        Some((code, _, _)) => (code as i64, -1),
        None => (0, -1),
    }
}

/// Latency as a TCP connect-time RTT (no ICMP / `ping`). `None` on failure.
pub(crate) fn probe_ping() -> Option<f64> {
    io::tcp_connect_rtt_ms("www.google.com", 443, Duration::from_secs(2))
}

/// Throughput in kbps from GL's offload-aware `gl-clients get_speed`
/// (`speed_rx` = download → `tx_kbps`, `speed_tx` = upload → `rx_kbps`,
/// bytes/sec ×8/1000). If the bus call fails, returns zeros tagged
/// `"unavailable"` (no `/proc/net/dev` fallback — this targets the vendor
/// firmware where gl-clients always exists, and netdev counters miss the WED
/// hardware-offloaded traffic anyway).
pub(crate) fn probe_throughput() -> (i64, i64, String) {
    match io::ubus_call::<GetSpeed>("gl-clients", "get_speed", "{}") {
        Some(sp) => {
            let dl = sp.speed_rx.max(0);
            let ul = sp.speed_tx.max(0);
            (ul * 8 / 1000, dl * 8 / 1000, "gl-clients".into())
        }
        None => (0, 0, "unavailable".into()),
    }
}

/// Connected clients from `gl-clients list`. gl-clients is client-centric, so
/// cross-map to the router-centric output: gl `.rx` (download) → `tx`, gl `.tx`
/// (upload) → `rx`. Returns `(online, total_tx, total_rx, list)`.
pub(crate) fn probe_clients() -> (i64, i64, i64, Vec<ClientEntry>) {
    let list: ClientsList =
        io::ubus_call("gl-clients", "list", "{}").unwrap_or(ClientsList { clients: serde_json::Map::new() });
    let leases = std::fs::read_to_string(DHCP_LEASES).unwrap_or_default();

    let (mut online, mut total_tx, mut total_rx) = (0i64, 0i64, 0i64);
    let mut entries = Vec::new();
    for (mac, val) in &list.clients {
        let c: ClientRaw = match serde_json::from_value(val.clone()) {
            Ok(c) => c,
            Err(_) => continue,
        };
        if !c.online {
            continue;
        }
        let tx = c.rx * 8 / 1000; // download
        let rx = c.tx * 8 / 1000; // upload
        online += 1;
        total_tx += tx;
        total_rx += rx;
        entries.push(ClientEntry {
            mac: mac.clone(),
            name: resolve_name(mac, &c.name, &leases),
            ip: c.ip,
            iface: c.iface,
            tx,
            rx,
        });
    }
    (online, total_tx, total_rx, entries)
}

/// Resolve a display name: gl-clients name → DHCP lease hostname →
/// `"Private Device"` (locally-administered MAC) → MAC OUI prefix.
pub(crate) fn resolve_name(mac: &str, gl_name: &str, leases: &str) -> String {
    if !gl_name.is_empty() {
        return gl_name.to_string();
    }
    let mac_l = mac.to_lowercase();
    for line in leases.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() >= 4 && f[1].to_lowercase() == mac_l && f[3] != "*" {
            return f[3].to_string();
        }
    }
    if let Some(first) = mac.split(':').next() {
        if let Ok(b) = i64::from_str_radix(first, 16) {
            if b & 2 != 0 {
                return "Private Device".to_string();
            }
        }
    }
    mac.split(':').take(3).collect::<Vec<_>>().join(":")
}

/// Internet is "available" when the web check returned 204 with a real latency
/// and the latency probe connected.
pub(crate) fn compute_avail(web_code: i64, web_ms: i64, ping_ok: bool) -> i64 {
    if web_code == 204 && web_ms > 0 && ping_ok {
        1
    } else {
        0
    }
}

/// Refresh `state.uplink` when the SSID changes, the connection is restored, or
/// every [`UPLINK_DETECT_INTERVAL`] cycles. One ip-api call (no IP in the path)
/// yields both the external IP and the ISP/ASN; a failed lookup falls back to
/// the unknown sentinel.
pub(crate) fn detect_uplink(state: &mut State, ssid: &str, avail_prev: i64) {
    let mut force = false;
    if !state.last_ssid.is_empty() && ssid != state.last_ssid {
        log(&format!("SSID changed ({} -> {}), re-detecting uplink...", state.last_ssid, ssid));
        force = true;
    }
    state.last_ssid = ssid.to_string();
    if state.last_avail_state == 0 && avail_prev == 1 {
        log("Connection restored, re-detecting uplink...");
        force = true;
    }
    if !force && state.uplink.is_some() && state.uplink_sample_count < UPLINK_DETECT_INTERVAL {
        state.uplink_sample_count += 1;
        return;
    }

    log("Detecting uplink type...");
    state.uplink_sample_count = 0;

    let info: Option<IpApi> =
        io::http_get("ip-api.com", 80, "/json/?fields=status,isp,org,as,query", Duration::from_secs(5))
            .and_then(|(_, body, _)| serde_json::from_str(&body).ok());
    let info = match info {
        Some(i) => i,
        None => {
            log("Could not look up uplink ISP/ASN, using defaults");
            state.uplink = Some(Uplink::unknown());
            return;
        }
    };
    if !info.query.is_empty() {
        if !state.last_external_ip.is_empty() && info.query != state.last_external_ip {
            log(&format!("External IP changed ({} -> {})", state.last_external_ip, info.query));
        }
        state.last_external_ip = info.query.clone();
    }

    let conn = classify_connection(&info.isp, &info.org, &info.as_field, &load_asn_map());
    let isp = if info.isp.is_empty() { "Unknown".to_string() } else { info.isp.clone() };
    log(&format!("Uplink detected: {} ({})", conn, isp));
    state.uplink = Some(Uplink {
        thresholds: thresholds_for(&conn),
        connection_type: conn,
        isp,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn avail_logic() {
        assert_eq!(compute_avail(204, 50, true), 1);
        assert_eq!(compute_avail(204, 50, false), 0);
        assert_eq!(compute_avail(0, -1, true), 0);
        assert_eq!(compute_avail(204, 0, true), 0);
    }

    #[test]
    fn client_cross_map_arithmetic() {
        // gl .rx (download) -> tx ; gl .tx (upload) -> rx ; ×8/1000
        let (gl_rx, gl_tx) = (1_000_000i64, 50_000i64);
        assert_eq!(gl_rx * 8 / 1000, 8000); // tx (download)
        assert_eq!(gl_tx * 8 / 1000, 400); // rx (upload)
    }

    #[test]
    fn resolve_name_precedence() {
        let leases = "1700000000 00:11:22:33:44:55 192.168.8.5 my-laptop *\n";
        assert_eq!(resolve_name("00:11:22:33:44:55", "GLName", leases), "GLName"); // gl name wins
        assert_eq!(resolve_name("00:11:22:33:44:55", "", leases), "my-laptop"); // dhcp lease
        assert_eq!(resolve_name("F2:A6:CB:CD:14:55", "", ""), "Private Device"); // locally-administered
        assert_eq!(resolve_name("00:11:22:33:44:55", "", ""), "00:11:22"); // OUI prefix
    }
}
