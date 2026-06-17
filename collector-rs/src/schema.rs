//! Output schema — the single source of truth for the shape of `data2.json`.
//!
//! These are pure data types with no logic. `serde` renders the exact key
//! order, nesting and types of the shell daemon's `emit_data_json`. Numbers the
//! shell prints as integers are `i64`/`u64`; `ping.current` is a
//! [`serde_json::Number`] so a float RTT passes through unrounded.

use serde::{Deserialize, Serialize};

/// A good/warn threshold pair (milliseconds) for one latency metric.
#[derive(Serialize, Deserialize, Clone)]
pub(crate) struct Thr {
    pub good: i64,
    pub warn: i64,
}

/// Latency thresholds for the current uplink class, used by the UI to colour
/// the ping and web charts.
#[derive(Serialize, Deserialize, Clone)]
pub(crate) struct Thresholds {
    pub ping: Thr,
    pub web: Thr,
}

/// The classified uplink: connection type, ISP name, and the thresholds that
/// follow from the type. Persisted in state and echoed into `data2.json`.
#[derive(Serialize, Deserialize, Clone)]
pub(crate) struct Uplink {
    pub connection_type: String,
    pub isp: String,
    pub thresholds: Thresholds,
}

impl Uplink {
    /// The sentinel uplink used before the first successful detection or when
    /// the ISP/ASN lookup fails — `unknown`/`Unknown` with landline thresholds.
    pub(crate) fn unknown() -> Self {
        Uplink {
            connection_type: "unknown".into(),
            isp: "Unknown".into(),
            thresholds: Thresholds {
                ping: Thr { good: 30, warn: 80 },
                web: Thr { good: 100, warn: 300 },
            },
        }
    }
}

/// Web reachability probe: HTTP status `code`, round-trip `ms` (or `-1`), and
/// the recent history of `ms` values.
#[derive(Serialize)]
pub(crate) struct WebSection {
    pub code: i64,
    pub ms: i64,
    pub history: Vec<i64>,
}

/// Latency probe: `current` RTT in ms (float, or `-1` on failure) plus history
/// of rounded values.
#[derive(Serialize)]
pub(crate) struct PingSection {
    pub current: serde_json::Number,
    pub history: Vec<i64>,
}

/// Throughput in kbps. `tx` = download, `rx` = upload (router-centric, matching
/// the shell + dashboard). `source` records which measurement path produced the
/// values (`gl-clients` normally, `unavailable` if the bus call failed).
#[derive(Serialize)]
pub(crate) struct ThroughputSection {
    pub rx_kbps: i64,
    pub tx_kbps: i64,
    pub rx_peak: i64,
    pub tx_peak: i64,
    pub rx_history: Vec<i64>,
    pub tx_history: Vec<i64>,
    pub source: String,
}

/// Internet availability: `current` (1/0), the epoch of the last success, and
/// the recent 1/0 history.
#[derive(Serialize)]
pub(crate) struct AvailSection {
    pub current: i64,
    pub last_success: i64,
    pub history: Vec<i64>,
}

/// One connected client. `tx` = its download, `rx` = its upload (kbps).
#[derive(Serialize)]
pub(crate) struct ClientEntry {
    pub mac: String,
    pub name: String,
    pub ip: String,
    pub iface: String,
    pub tx: i64,
    pub rx: i64,
}

/// Connected-client summary plus the per-client list.
#[derive(Serialize)]
pub(crate) struct ClientsSection {
    pub online: i64,
    pub total_tx: i64,
    pub total_rx: i64,
    pub history: Vec<i64>,
    pub list: Vec<ClientEntry>,
}

/// The complete published document. Field order here is the JSON key order.
#[derive(Serialize)]
pub(crate) struct DataDoc {
    pub ts: i64,
    pub interval: u64,
    pub uplink_ssid: String,
    pub uplink: Uplink,
    pub web: WebSection,
    pub ping: PingSection,
    pub throughput: ThroughputSection,
    pub avail: AvailSection,
    pub clients: ClientsSection,
}
