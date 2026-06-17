//! Native Rust reimplementation of the dashboard data collector.
//!
//! An **additive** second provider: it writes `/www/data2.json`, never the
//! shell daemon's `/www/data.json`, and keeps its own `/tmp/dash2_state.json`,
//! so it runs side-by-side for validation without disturbing anything. It does
//! not replicate the reboot forensics (heartbeat / boot log / `reboots.json` /
//! syslog tail) — that stays in the shell daemon.
//!
//! Design principles:
//! - **Structured interfaces only.** Every probe deserializes a typed value
//!   from `ubus` JSON, a std HTTP response, or a TCP connect time. No
//!   unstructured CLI text is parsed; serde handles all JSON escaping. The only
//!   external CLI is `ubus` (the sole interface to `ubusd`).
//! - **Degrade, never guess.** Any failed/surprising call returns a sentinel
//!   that the schema's defaults fill, so output is always valid.
//! - **In-memory history, snapshotted once per cycle** so it survives a restart.
//!
//! Module map:
//! - [`schema`]   — the published document types (`DataDoc` + sections).
//! - [`io`]       — all outside-world I/O: `ubus`, std HTTP, TCP RTT.
//! - [`classify`] — uplink ISP/ASN classification (+ field-editable data file).
//! - [`probes`]   — one function per metric.
//! - [`state`]    — rolling histories + carry-over, persisted to one file.

mod classify;
mod forensics;
mod io;
mod probes;
mod schema;
mod state;

use schema::*;
use state::{peak, push_cap, vec_or_zero, State};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// === config ===
/// Seconds between collection cycles.
pub(crate) const INTERVAL: u64 = 5;
/// Samples retained per history ring (120 × 5 s = 10 min).
pub(crate) const MAX_HISTORY: usize = 120;
/// Re-run uplink ISP/ASN detection at most every N cycles (unless forced).
pub(crate) const UPLINK_DETECT_INTERVAL: u64 = 60;
/// Republish reboots.json every N cycles (~30 s; boot history changes rarely).
const REBOOTS_PUBLISH_INTERVAL: u64 = 6;

const JSON_OUT_DEFAULT: &str = "/www/data2.json";

/// Output path (override with `DASH2_JSON_OUT`).
fn json_out() -> String {
    std::env::var("DASH2_JSON_OUT").unwrap_or_else(|_| JSON_OUT_DEFAULT.to_string())
}

/// Seconds since the Unix epoch (0 if the clock predates 1970).
pub(crate) fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// Timestamped stdout line, mirroring the shell daemon's `log()`.
pub(crate) fn log(msg: &str) {
    let s = now_secs().rem_euclid(86400);
    println!("{:02}:{:02}:{:02} {}", s / 3600, (s % 3600) / 60, s % 60, msg);
}

/// Run one cycle: probe every metric, fold into history, publish `data2.json`,
/// and snapshot state.
fn collect_data(state: &mut State) {
    let now = now_secs();

    let ssid = probes::probe_uplink_ssid();
    probes::detect_uplink(state, &ssid, state.last_avail_state);
    let uplink = state.uplink.clone().unwrap_or_else(Uplink::unknown);

    let (web_code, web_ms) = probes::probe_web(now);
    let ping = probes::probe_ping();
    let (rx_kbps, tx_kbps, source) = probes::probe_throughput();
    let (online, total_tx, total_rx, list) = probes::probe_clients();

    let avail = probes::compute_avail(web_code, web_ms, ping.is_some());
    if avail == 1 {
        state.last_success = now;
    }

    // Fold this cycle's values into the in-memory histories.
    push_cap(&mut state.hist.web, web_ms);
    push_cap(&mut state.hist.ping, ping.map(|f| f.round() as i64).unwrap_or(-1));
    push_cap(&mut state.hist.avail, avail);
    push_cap(&mut state.hist.clients, online);
    push_cap(&mut state.hist.thru_tx, tx_kbps);
    push_cap(&mut state.hist.thru_rx, rx_kbps);

    // ping.current passes the float RTT through unrounded (or -1 on failure).
    let ping_current = ping
        .and_then(serde_json::Number::from_f64)
        .unwrap_or_else(|| serde_json::Number::from(-1));

    let doc = DataDoc {
        ts: now,
        interval: INTERVAL,
        uplink_ssid: ssid,
        uplink,
        web: WebSection { code: web_code, ms: web_ms, history: vec_or_zero(&state.hist.web) },
        ping: PingSection { current: ping_current, history: vec_or_zero(&state.hist.ping) },
        throughput: ThroughputSection {
            rx_kbps,
            tx_kbps,
            rx_peak: peak(&state.hist.thru_rx),
            tx_peak: peak(&state.hist.thru_tx),
            rx_history: vec_or_zero(&state.hist.thru_rx),
            tx_history: vec_or_zero(&state.hist.thru_tx),
            source,
        },
        avail: AvailSection {
            current: avail,
            last_success: state.last_success,
            history: vec_or_zero(&state.hist.avail),
        },
        clients: ClientsSection {
            online,
            total_tx,
            total_rx,
            history: vec_or_zero(&state.hist.clients),
            list,
        },
    };

    write_atomic(&json_out(), &doc);
    log(&format!(
        "Web:{}ms Ping:{}ms DL:{}K UL:{}K Clients:{}",
        web_ms,
        ping.map(|f| f.to_string()).unwrap_or_else(|| "-1".into()),
        tx_kbps,
        rx_kbps,
        online
    ));
    state.last_avail_state = avail;
    state.save();
}

/// Serialize `doc` and atomically replace `path` (write `.tmp`, then rename) so
/// a reader never sees a half-written file.
fn write_atomic(path: &str, doc: &DataDoc) {
    if let Ok(json) = serde_json::to_string_pretty(doc) {
        let tmp = format!("{}.tmp", path);
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
}

fn main() {
    let once = std::env::args().any(|a| a == "--once");
    let mut state = State::load();
    if once {
        // One data.json cycle, no forensics loop — used for validation.
        collect_data(&mut state);
        return;
    }

    // Graceful shutdown: catching SIGTERM/INT/HUP lets us write a shutdown
    // record, which is how the next boot tells an orderly reboot from an abrupt
    // one. The handler just sets a flag; the loop does the I/O.
    let term = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for sig in [
        signal_hook::consts::SIGTERM,
        signal_hook::consts::SIGINT,
        signal_hook::consts::SIGHUP,
    ] {
        let _ = signal_hook::flag::register(sig, std::sync::Arc::clone(&term));
    }

    // Forensics startup: begin capturing syslog, record this boot (gap→verdict),
    // and publish reboots.json once so dash3 isn't empty before the first tick.
    forensics::start_syslog_tail();
    forensics::record_boot(now_secs());
    forensics::publish_reboots(now_secs());

    log(&format!(
        "Dashboard Rust collector starting (interval: {}s, history: {}) -> {}",
        INTERVAL,
        MAX_HISTORY,
        json_out()
    ));

    let mut cycle: u64 = 0;
    loop {
        collect_data(&mut state);
        cycle += 1;
        forensics::record_heartbeat(now_secs(), cycle);
        if cycle % REBOOTS_PUBLISH_INTERVAL == 0 {
            forensics::publish_reboots(now_secs());
        }
        forensics::rotate_syslog_tail(cycle);

        // Sleep the interval in 1 s steps so a stop signal is handled within ~1 s.
        for _ in 0..INTERVAL {
            if term.load(std::sync::atomic::Ordering::Relaxed) {
                forensics::record_shutdown(now_secs(), "TERM");
                std::process::exit(0);
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }
}
