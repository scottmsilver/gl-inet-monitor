//! Collector state: the rolling metric histories plus the carry-over fields the
//! detection logic needs between cycles.
//!
//! History lives in memory ([`VecDeque`]) and is snapshotted to one JSON file
//! each cycle, so a collector restart keeps ~10 min of chart history instead of
//! starting blank.

use crate::schema::Uplink;
use crate::MAX_HISTORY;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

const STATE_FILE_DEFAULT: &str = "/tmp/dash2_state.json";

/// Path to the state snapshot (override with `DASH2_STATE_FILE`).
fn state_file() -> String {
    std::env::var("DASH2_STATE_FILE").unwrap_or_else(|_| STATE_FILE_DEFAULT.to_string())
}

/// Rolling per-metric histories, each capped at [`MAX_HISTORY`] samples.
/// Per-field `#[serde(default)]` keeps an older snapshot loadable if a new
/// history is added later (missing field → empty, not a parse failure).
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct History {
    #[serde(default)]
    pub web: VecDeque<i64>,
    #[serde(default)]
    pub ping: VecDeque<i64>,
    #[serde(default)]
    pub avail: VecDeque<i64>,
    #[serde(default)]
    pub clients: VecDeque<i64>,
    #[serde(default)]
    pub thru_tx: VecDeque<i64>,
    #[serde(default)]
    pub thru_rx: VecDeque<i64>,
}

/// Everything carried between cycles and persisted across restarts. Per-field
/// `#[serde(default)]` means adding a field in a future version still loads an
/// existing snapshot (the new field defaults) instead of resetting all history.
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct State {
    #[serde(default)]
    pub hist: History,
    #[serde(default)]
    pub last_success: i64,
    #[serde(default)]
    pub last_ssid: String,
    #[serde(default)]
    pub last_external_ip: String,
    #[serde(default)]
    pub last_avail_state: i64,
    #[serde(default)]
    pub uplink_sample_count: u64,
    #[serde(default)]
    pub uplink: Option<Uplink>,
}

impl State {
    /// Load the snapshot, or a fresh default (assume "available" so the first
    /// drop is detectable) if it's missing or unreadable.
    pub(crate) fn load() -> Self {
        std::fs::read_to_string(state_file())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| State { last_avail_state: 1, ..Default::default() })
    }

    /// Atomically snapshot to disk (write tmp, rename). Best-effort: a failed
    /// save just means the next restart loses recent history.
    pub(crate) fn save(&self) {
        if let Ok(json) = serde_json::to_string(self) {
            let tmp = format!("{}.tmp", state_file());
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(&tmp, state_file());
            }
        }
    }
}

/// Append `v`, dropping the oldest so the ring never exceeds [`MAX_HISTORY`].
pub(crate) fn push_cap(q: &mut VecDeque<i64>, v: i64) {
    q.push_back(v);
    while q.len() > MAX_HISTORY {
        q.pop_front();
    }
}

/// History as a `Vec`, or `[0]` when empty so the UI always has a value to plot.
pub(crate) fn vec_or_zero(q: &VecDeque<i64>) -> Vec<i64> {
    if q.is_empty() {
        vec![0]
    } else {
        q.iter().copied().collect()
    }
}

/// The maximum value in a history (0 if empty) — used for the throughput peaks.
pub(crate) fn peak(q: &VecDeque<i64>) -> i64 {
    q.iter().copied().max().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn history_cap_peak_default() {
        let mut q = VecDeque::new();
        for i in 0..(MAX_HISTORY as i64 + 50) {
            push_cap(&mut q, i);
        }
        assert_eq!(q.len(), MAX_HISTORY);
        assert_eq!(*q.front().unwrap(), 50); // oldest dropped
        assert_eq!(*q.back().unwrap(), MAX_HISTORY as i64 + 49);
        assert_eq!(peak(&q), MAX_HISTORY as i64 + 49);
        assert_eq!(vec_or_zero(&VecDeque::new()), vec![0]);
    }
}
