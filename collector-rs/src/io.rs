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

/// Internet checksum (RFC 1071): one's-complement sum of 16-bit big-endian words.
fn icmp_checksum(data: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    let mut i = 0;
    while i + 1 < data.len() {
        sum += ((data[i] as u32) << 8) | data[i + 1] as u32;
        i += 2;
    }
    if i < data.len() {
        sum += (data[i] as u32) << 8;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

/// Real ICMP echo RTT to `host` (IPv4), in ms — our own raw-socket
/// implementation (no `ping` binary, no text scraping). Unlike a TCP connect,
/// ICMP can't be short-circuited by a transparent proxy, so it reports the true
/// path latency. Needs CAP_NET_RAW (we run as root). `None` on resolve/socket
/// failure or timeout (→ avail sentinel). IPv6 hosts return `None`.
pub(crate) fn icmp_rtt_ms(host: &str, timeout: Duration) -> Option<f64> {
    let v4 = (host, 0u16).to_socket_addrs().ok()?.find_map(|a| match a {
        std::net::SocketAddr::V4(s) => Some(*s.ip()),
        _ => None,
    })?;
    let id: u16 = (std::process::id() & 0xffff) as u16;
    let seq: u16 = 1;
    // ICMP echo request: type8 code0 cksum id seq + 8-byte payload.
    let mut pkt = [0u8; 16];
    pkt[0] = 8;
    pkt[4..6].copy_from_slice(&id.to_be_bytes());
    pkt[6..8].copy_from_slice(&seq.to_be_bytes());
    let ck = icmp_checksum(&pkt);
    pkt[2..4].copy_from_slice(&ck.to_be_bytes());

    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_RAW, libc::IPPROTO_ICMP);
        if fd < 0 {
            return None;
        }
        // `as _` infers each field's type (avoids naming libc::time_t /
        // suseconds_t, which musl is migrating to 64-bit).
        let mut tv: libc::timeval = std::mem::zeroed();
        tv.tv_sec = timeout.as_secs() as _;
        tv.tv_usec = timeout.subsec_micros() as _;
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVTIMEO,
            &tv as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::timeval>() as libc::socklen_t,
        );
        let mut dest: libc::sockaddr_in = std::mem::zeroed();
        dest.sin_family = libc::AF_INET as libc::sa_family_t;
        dest.sin_addr.s_addr = u32::from_ne_bytes(v4.octets());

        let start = Instant::now();
        let sent = libc::sendto(
            fd,
            pkt.as_ptr() as *const libc::c_void,
            pkt.len(),
            0,
            &dest as *const libc::sockaddr_in as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
        );
        if sent < 0 {
            libc::close(fd);
            return None;
        }
        // Raw ICMP sockets receive ALL icmp; loop until our reply or timeout.
        let mut buf = [0u8; 1500];
        let result = loop {
            if start.elapsed() > timeout {
                break None;
            }
            let n = libc::recv(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0);
            if n < 0 {
                break None; // timeout (SO_RCVTIMEO) or error
            }
            let n = n as usize;
            let ihl = ((buf[0] & 0x0f) as usize) * 4; // IPv4 header length
            if n < ihl + 8 {
                continue;
            }
            let icmp = &buf[ihl..];
            // type 0 = echo reply; match our id+seq
            if icmp[0] == 0
                && u16::from_be_bytes([icmp[4], icmp[5]]) == id
                && u16::from_be_bytes([icmp[6], icmp[7]]) == seq
            {
                break Some(start.elapsed().as_secs_f64() * 1000.0);
            }
        };
        libc::close(fd);
        result
    }
}

/// Read `count` 32-bit words of physical memory starting at `addr` via
/// `/dev/mem` (mmap the containing page, volatile-read). Used to peek SoC
/// registers like the MT7981 reset-cause block. `None` if `/dev/mem` is
/// unreadable or mmap fails. Needs root + `CONFIG_STRICT_DEVMEM` off.
pub(crate) fn read_mmio(addr: u64, count: usize) -> Option<Vec<u32>> {
    unsafe {
        let fd = libc::open(b"/dev/mem\0".as_ptr() as *const libc::c_char, libc::O_RDONLY | libc::O_SYNC);
        if fd < 0 {
            return None;
        }
        let ps = libc::sysconf(libc::_SC_PAGESIZE) as u64;
        let base = addr & !(ps - 1);
        let off = (addr - base) as usize;
        let len = off + count * 4;
        let m = libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ, libc::MAP_SHARED, fd, base as libc::off_t);
        if m == libc::MAP_FAILED {
            libc::close(fd);
            return None;
        }
        let p = (m as *const u8).add(off) as *const u32;
        let words = (0..count).map(|i| std::ptr::read_volatile(p.add(i))).collect();
        libc::munmap(m, len);
        libc::close(fd);
        Some(words)
    }
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
    fn icmp_checksum_rfc1071() {
        // echo request, type 8, id/seq = 1, checksum field zeroed
        let mut pkt = [8u8, 0, 0, 0, 0x00, 0x01, 0x00, 0x01];
        let ck = icmp_checksum(&pkt);
        pkt[2..4].copy_from_slice(&ck.to_be_bytes());
        // a correctly-checksummed message re-sums to 0 (RFC 1071 property)
        assert_eq!(icmp_checksum(&pkt), 0);
    }

    #[test]
    fn clients_map_preserves_order() {
        let raw = r#"{"clients":{"AA:01":{"online":true},"BB:02":{"online":false},"CC:03":{"online":true}}}"#;
        let list: ClientsList = serde_json::from_str(raw).unwrap();
        let order: Vec<&String> = list.clients.keys().collect();
        assert_eq!(order, vec!["AA:01", "BB:02", "CC:03"]);
    }
}
