//! Uplink classification: turn an ISP/ASN into a connection class
//! (`starlink` / `airplane` / `geo_satellite` / `maritime` / `cellular` /
//! `landline`) and the latency thresholds that follow.
//!
//! ASN→class is **data that grows in the field** (a new airline, a cruise-ship
//! ISP), so it lives in an optional JSON file you can edit over SSH and that
//! reloads each detection cycle — no Rust toolchain needed. The embedded
//! baseline is always present; the file is overlaid on top (adds/overrides). A
//! missing or malformed file just leaves the baseline, so classification never
//! fails. The keyword/regex heuristics stay in code: they're fuzzy logic, not
//! data.

use crate::schema::{Thr, Thresholds};
use std::collections::HashMap;

const ASN_FILE_DEFAULT: &str = "/root/dash2_asn.json";

/// Path to the optional ASN data file (override with `DASH2_ASN_FILE`).
fn asn_file() -> String {
    std::env::var("DASH2_ASN_FILE").unwrap_or_else(|_| ASN_FILE_DEFAULT.to_string())
}

/// The embedded baseline ASN→class map, always available.
fn default_asn_map() -> HashMap<String, String> {
    let table: &[(&str, &[&str])] = &[
        ("starlink", &["14593"]),
        ("airplane", &["21928", "393960", "18747", "64294", "50973", "22351"]),
        ("geo_satellite", &["7155", "16491", "40306", "40311", "46536", "1358", "6621", "63062", "35228"]),
        ("maritime", &["15146", "26415"]),
    ];
    let mut m = HashMap::new();
    for (class, asns) in table {
        for a in *asns {
            m.insert((*a).to_string(), (*class).to_string());
        }
    }
    m
}

/// The baseline overlaid with the on-device JSON file (`{ "<asn>": "<class>" }`).
/// File entries add to or override the baseline; a bad/missing file yields just
/// the baseline.
pub(crate) fn load_asn_map() -> HashMap<String, String> {
    let mut m = default_asn_map();
    if let Ok(s) = std::fs::read_to_string(asn_file()) {
        if let Ok(file_map) = serde_json::from_str::<HashMap<String, String>>(&s) {
            for (k, v) in file_map {
                m.insert(k, v);
            }
        }
    }
    m
}

/// Map the first `AS<digits>` token in an `as` field to a class via `map`.
/// `None` if there's no AS number or it isn't in the map.
fn classify_by_asn(as_field: &str, map: &HashMap<String, String>) -> Option<String> {
    let digits: String = as_field
        .split_once("AS")
        .map(|(_, rest)| rest.chars().take_while(|c| c.is_ascii_digit()).collect())
        .unwrap_or_default();
    if digits.is_empty() {
        return None;
    }
    map.get(&digits).cloned()
}

/// Classify a connection. A precise ASN match wins; otherwise fall back to
/// keyword-matching the combined ISP / org / AS text.
pub(crate) fn classify_connection(
    isp: &str,
    org: &str,
    as_field: &str,
    asn_map: &HashMap<String, String>,
) -> String {
    if let Some(c) = classify_by_asn(as_field, asn_map) {
        return c;
    }
    let up = format!("{} {} {}", isp, org, as_field).to_uppercase();
    let any = |words: &[&str]| words.iter().any(|w| up.contains(w));
    // emulate a `.*` regex between two literals: A, then B somewhere after it
    let between = |a: &str, b: &str| up.split_once(a).map_or(false, |(_, r)| r.contains(b));

    if any(&["STARLINK", "SPACEX"]) {
        "starlink"
    } else if any(&["GOGO", "GO-GO", "INMARSAT", "ANUVU", "THALES", "SMARTSKY", "GLOBAL EAGLE"])
        || between("PANASONIC", "AVIONIC")
        || between("VIASAT", "AIRLINE")
    {
        "airplane"
    } else if any(&["VIASAT", "HUGHESNET", "ECHOSTAR", "EUTELSAT", "SES S.A", "TELESAT", "SKYTERRA"]) {
        "geo_satellite"
    } else if any(&["MARITIME", "MARLINK", "KVH", "SPEEDCAST"]) {
        "maritime"
    } else if any(&["T-MOBILE", "VERIZON WIRELESS", "AT&T MOBILITY", "CELLULAR", "LTE", "5G"]) {
        "cellular"
    } else {
        "landline"
    }
    .to_string()
}

/// Latency thresholds (ms) for a connection class: satellite/airplane links get
/// generous budgets, wired/cellular tight ones.
pub(crate) fn thresholds_for(conn: &str) -> Thresholds {
    let (pg, pw, wg, ww) = match conn {
        "starlink" => (60, 120, 200, 400),
        "airplane" | "geo_satellite" | "maritime" => (775, 1100, 2000, 3500),
        "cellular" => (80, 150, 250, 500),
        _ => (30, 80, 100, 300),
    };
    Thresholds {
        ping: Thr { good: pg, warn: pw },
        web: Thr { good: wg, warn: ww },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::io::IpApi;

    #[test]
    fn asn_number_classification() {
        let m = default_asn_map();
        assert_eq!(classify_by_asn("AS14593 SpaceX", &m).as_deref(), Some("starlink"));
        assert_eq!(classify_by_asn("AS21928 Gogo", &m).as_deref(), Some("airplane"));
        assert_eq!(classify_by_asn("AS40306 ViaSat", &m).as_deref(), Some("geo_satellite"));
        assert_eq!(classify_by_asn("AS15146 Marlink", &m).as_deref(), Some("maritime"));
        assert_eq!(classify_by_asn("AS7922 Comcast", &m), None);
        assert_eq!(classify_by_asn("no asn", &m), None);
    }

    #[test]
    fn connection_classification() {
        let m = default_asn_map();
        assert_eq!(classify_connection("STARLINK", "", "AS9999", &m), "starlink");
        assert_eq!(classify_connection("Gogo LLC", "", "AS9999", &m), "airplane");
        assert_eq!(classify_connection("Panasonic Avionics", "", "AS9999", &m), "airplane");
        assert_eq!(classify_connection("ViaSat", "", "AS9999", &m), "geo_satellite");
        assert_eq!(classify_connection("T-Mobile USA", "", "AS9999", &m), "cellular");
        assert_eq!(classify_connection("Comcast Cable", "", "AS7922", &m), "landline");
        assert_eq!(classify_connection("Whatever", "", "AS14593", &m), "starlink"); // ASN wins
    }

    #[test]
    fn asn_map_file_overlay_and_fallback() {
        // set_var is process-global, so both cases live in one test to avoid a
        // parallel race with other env-touching tests.
        let dir = std::env::temp_dir();
        let p = dir.join(format!("dash2_asn_test_{}.json", std::process::id()));
        std::fs::write(&p, r#"{"64500":"airplane","14593":"maritime"}"#).unwrap();
        std::env::set_var("DASH2_ASN_FILE", &p);
        let m = load_asn_map();
        assert_eq!(m.get("64500").map(String::as_str), Some("airplane")); // newly taught
        assert_eq!(m.get("14593").map(String::as_str), Some("maritime")); // overridden
        assert_eq!(m.get("21928").map(String::as_str), Some("airplane")); // baseline remains
        std::fs::remove_file(&p).ok();

        std::env::set_var("DASH2_ASN_FILE", "/nonexistent/dash2_asn.json");
        let m2 = load_asn_map();
        assert_eq!(m2.get("14593").map(String::as_str), Some("starlink")); // baseline intact
        std::env::remove_var("DASH2_ASN_FILE");
    }

    #[test]
    fn thresholds_per_class() {
        assert_eq!((thresholds_for("starlink").ping.good, thresholds_for("starlink").web.warn), (60, 400));
        assert_eq!((thresholds_for("airplane").ping.good, thresholds_for("airplane").web.warn), (775, 3500));
        assert_eq!((thresholds_for("cellular").ping.good, thresholds_for("cellular").web.warn), (80, 500));
        assert_eq!((thresholds_for("landline").ping.good, thresholds_for("landline").web.warn), (30, 300));
    }

    #[test]
    fn classifies_real_ip_api_fixture() {
        let info: IpApi = serde_json::from_str(
            r#"{"status":"success","isp":"NOS COMUNICACOES S.A.","org":"NOS","as":"AS2860 NOS"}"#,
        )
        .unwrap();
        assert_eq!(info.isp, "NOS COMUNICACOES S.A.");
        assert_eq!(info.as_field, "AS2860 NOS");
        assert_eq!(classify_connection(&info.isp, &info.org, &info.as_field, &default_asn_map()), "landline");
    }
}
