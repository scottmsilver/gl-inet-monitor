//! All communication with the outside world lives here: the `ubus` CLI (the
//! sole external dependency — there is no `libgl-clients` to link), a tiny
//! std-only HTTP/1.0 client, and a TCP connect-time latency probe.
//!
//! Every function returns `Option`/`None` on any failure so callers degrade to
//! a sentinel rather than crash. The structs below are the *input* contracts
//! (what the device sends us), distinct from the output [`crate::schema`].

use serde::Deserialize;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::process::Command;
use std::time::{Duration, Instant};

const UBUS_TIMEOUT: &str = "3";

// === ubus input contracts (#[serde(default)] => a missing field is a sentinel,
// never a deserialize error) ===

/// `ubus call iwinfo info {"device":...}` — we only need the SSID.
#[derive(Deserialize)]
pub(crate) struct IwInfo {
    #[serde(default)]
    pub ssid: String,
}

/// `ubus call gl-clients get_speed` — aggregate offload-aware speed, bytes/sec.
/// `speed_rx` is download, `speed_tx` is upload.
#[derive(Deserialize)]
pub(crate) struct GetSpeed {
    #[serde(default)]
    pub speed_rx: i64,
    #[serde(default)]
    pub speed_tx: i64,
}

/// One entry from `ubus call gl-clients list`. gl-clients is client-centric:
/// `rx` = bytes the client received (download), `tx` = bytes it sent (upload).
#[derive(Deserialize)]
pub(crate) struct ClientRaw {
    #[serde(default)]
    pub ip: String,
    #[serde(default)]
    pub iface: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub tx: i64,
    #[serde(default)]
    pub rx: i64,
}

/// `ubus call gl-clients list`. The `clients` map preserves device key order
/// (serde_json `preserve_order`), so the published list matches the UI's.
#[derive(Deserialize)]
pub(crate) struct ClientsList {
    #[serde(default)]
    pub clients: serde_json::Map<String, serde_json::Value>,
}

/// ip-api.com response. With no IP in the path it geolocates the requester's
/// own public address, so one call yields both the external IP (`query`) and
/// the ISP/ASN used for classification.
#[derive(Deserialize)]
pub(crate) struct IpApi {
    #[serde(default)]
    pub isp: String,
    #[serde(default)]
    pub org: String,
    #[serde(default, rename = "as")]
    pub as_field: String,
    #[serde(default)]
    pub query: String,
}

/// Call `ubus -t 3 call <obj> <method> <arg>` and deserialize its JSON stdout
/// into `T`. `None` on spawn failure, non-zero exit, or malformed JSON.
pub(crate) fn ubus_call<T: serde::de::DeserializeOwned>(obj: &str, method: &str, arg: &str) -> Option<T> {
    let out = Command::new("ubus")
        .args(["-t", UBUS_TIMEOUT, "call", obj, method, arg])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

/// Minimal std-only HTTP/1.0 GET — no `curl`, no TLS (both endpoints we hit are
/// plain HTTP). Returns `(status, body, elapsed)`; `None` on any failure.
///
/// `HTTP/1.0` + `Connection: close` makes the server close after the response,
/// so `read_to_end` returns promptly with no chunked-encoding handling needed.
/// musl static binaries resolve DNS fine via `getaddrinfo`.
pub(crate) fn http_get(host: &str, port: u16, path: &str, timeout: Duration) -> Option<(u16, String, Duration)> {
    let start = Instant::now();
    let addr = (host, port).to_socket_addrs().ok()?.next()?;
    let mut stream = TcpStream::connect_timeout(&addr, timeout).ok()?;
    stream.set_read_timeout(Some(timeout)).ok()?;
    stream.set_write_timeout(Some(timeout)).ok()?;
    let req = format!(
        "GET {} HTTP/1.0\r\nHost: {}\r\nUser-Agent: dash_collector\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        path, host
    );
    stream.write_all(req.as_bytes()).ok()?;
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).ok()?;
    let elapsed = start.elapsed();
    let text = String::from_utf8_lossy(&buf);
    let status = text.lines().next()?.split_whitespace().nth(1)?.parse::<u16>().ok()?;
    let body = text.split_once("\r\n\r\n").map(|(_, b)| b.to_string()).unwrap_or_default();
    Some((status, body, elapsed))
}

/// Measure one TCP connect round trip (SYN→SYN-ACK) to `host:port`, in ms.
/// DNS is resolved before the clock starts so it isn't counted. Used as the
/// latency metric in place of ICMP `ping`: TCP reaches where ICMP is often
/// dropped (captive / airplane / satellite networks). `None` on connect failure.
pub(crate) fn tcp_connect_rtt_ms(host: &str, port: u16, timeout: Duration) -> Option<f64> {
    let addr = (host, port).to_socket_addrs().ok()?.next()?;
    let start = Instant::now();
    let _stream = TcpStream::connect_timeout(&addr, timeout).ok()?;
    Some(start.elapsed().as_secs_f64() * 1000.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_speed_parses_and_defaults() {
        let sp: GetSpeed = serde_json::from_str(r#"{"speed_rx":11190619,"speed_tx":65838}"#).unwrap();
        assert_eq!(sp.speed_rx, 11190619);
        assert_eq!(sp.speed_tx, 65838);
        // missing fields default to 0 (no error)
        let z: GetSpeed = serde_json::from_str("{}").unwrap();
        assert_eq!((z.speed_rx, z.speed_tx), (0, 0));
    }

    #[test]
    fn iwinfo_ssid_optional() {
        let i: IwInfo = serde_json::from_str(r#"{"phy":"rax0","ssid":"VilaVita_Wi-Fi"}"#).unwrap();
        assert_eq!(i.ssid, "VilaVita_Wi-Fi");
        let i2: IwInfo = serde_json::from_str(r#"{"phy":"rax0"}"#).unwrap();
        assert_eq!(i2.ssid, "");
    }

    #[test]
    fn client_fields_parse() {
        let raw = r#"{"ip":"192.168.8.171","iface":"5G","tx":50000,"online":true,"rx":1000000,"name":"MacBookPro"}"#;
        let c: ClientRaw = serde_json::from_str(raw).unwrap();
        assert!(c.online);
        assert_eq!((c.rx, c.tx), (1000000, 50000));
        assert_eq!(c.name, "MacBookPro");
    }

    #[test]
    fn clients_map_preserves_order() {
        let raw = r#"{"clients":{"AA:01":{"online":true},"BB:02":{"online":false},"CC:03":{"online":true}}}"#;
        let list: ClientsList = serde_json::from_str(raw).unwrap();
        let order: Vec<&String> = list.clients.keys().collect();
        assert_eq!(order, vec!["AA:01", "BB:02", "CC:03"]);
    }
}
