//! Reboot forensics — the persistent diagnostics that let us tell, after the
//! fact, whether the router rebooted cleanly or died abruptly.
//!
//! Faithful port of dash_daemon.sh's forensics. Writes to `/overlay/upper/root`
//! (UBIFS flash, survives reboots) and publishes `reboots.json` for dash3:
//! - **heartbeat** — a one-line hardware snapshot every cycle, `sync`'d to flash,
//!   so the next boot can measure the gap since the last-known-good moment.
//! - **snapshot log** — the same 21 fields appended over time (telemetry trend).
//! - **boot record** — at startup, a gap→verdict (CLEAN / ABRUPT / FIRST_RUN)
//!   plus dmesg / pstore / watchdog / interrupts dumps for postmortem.
//! - **shutdown record** — written from the SIGTERM handler so an orderly reboot
//!   is distinguishable from an abrupt one (no record ⇒ abrupt).
//! - **syslog tail** — a background `logread -f` to flash for last-moments logs.
//!
//! All paths are env-overridable (`DASH2_PERSIST_DIR`, `DASH2_REBOOTS_OUT`) so
//! the collector can run to *parallel* files for side-by-side validation before
//! taking over the real ones.

use serde::Serialize;
use std::fs;
use std::process::Command;

const HEARTBEAT_INTERVAL_CYCLES: u64 = 1; // every 5s
const SNAPSHOT_MAX_LINES: usize = 4000;
const BOOT_LOG_MAX_BYTES: u64 = 512 * 1024;
const SYSLOG_TAIL_MAX_BYTES: u64 = 512 * 1024;
const ROTATE_EVERY_CYCLES: u64 = 240;

const PERSIST_DIR_DEFAULT: &str = "/overlay/upper/root";
const REBOOTS_OUT_DEFAULT: &str = "/www/reboots.json";
const SYSLOG_TAIL_PID: &str = "/tmp/dash2_syslog_tail.pid";

fn persist_dir() -> String {
    std::env::var("DASH2_PERSIST_DIR").unwrap_or_else(|_| PERSIST_DIR_DEFAULT.to_string())
}
fn pfile(name: &str) -> String {
    format!("{}/{}", persist_dir(), name)
}
fn heartbeat_file() -> String { pfile("dash_heartbeat.txt") }
fn boot_log() -> String { pfile("dash_boot.log") }
fn snapshot_log() -> String { pfile("dash_snapshot.log") }
fn shutdown_log() -> String { pfile("dash_shutdown.log") }
fn syslog_tail_log() -> String { pfile("dash_syslog_tail.log") }
fn reboots_out() -> String {
    std::env::var("DASH2_REBOOTS_OUT").unwrap_or_else(|_| REBOOTS_OUT_DEFAULT.to_string())
}

// === small /proc & /sys readers (all default to "0"/empty, never panic) ===

fn read_trim(path: &str) -> String {
    fs::read_to_string(path).map(|s| s.trim().to_string()).unwrap_or_default()
}
fn read_or0(path: &str) -> String {
    let s = read_trim(path);
    if s.is_empty() { "0".into() } else { s }
}
/// First whitespace token of a file (e.g. /proc/uptime, /proc/loadavg), or "0".
fn first_field(path: &str) -> String {
    read_trim(path).split_whitespace().next().map(String::from).unwrap_or_else(|| "0".into())
}
/// The Nth (1-based, like awk $col) whitespace token of the first line whose
/// first token matches `key` (handles "MemAvailable:" / "VmRSS:").
fn keyed_field(path: &str, key: &str, col: usize) -> String {
    for line in read_trim(path).lines() {
        let mut it = line.split_whitespace();
        if let Some(first) = it.next() {
            if first.trim_end_matches(':') == key {
                return it.nth(col - 2).map(String::from).unwrap_or_else(|| "0".into());
            }
        }
    }
    "0".into()
}

/// nr_running from /proc/loadavg's 4th field ("1/234" → "1").
fn nr_running() -> String {
    read_trim("/proc/loadavg")
        .split_whitespace()
        .nth(3)
        .and_then(|f| f.split('/').next())
        .map(String::from)
        .unwrap_or_else(|| "0".into())
}

/// Live process count = number of numeric dirs in /proc (no `ps` shell-out).
fn proc_count() -> String {
    let n = fs::read_dir("/proc")
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_str().map_or(false, |s| s.bytes().all(|b| b.is_ascii_digit())))
                .count()
        })
        .unwrap_or(0);
    n.to_string()
}

/// Sum the two per-CPU columns of /proc/interrupts lines matching each probe.
/// Returns (wdt_bark, wifi_irq, pwmfan_irq, err_irq) as strings.
fn interrupts() -> (String, String, String, String) {
    let (mut wdt, mut wifi, mut pwm, mut err) = (0i64, 0i64, 0i64, 0i64);
    for line in read_trim("/proc/interrupts").lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        let cpu_sum = |f: &[&str]| -> i64 {
            f.get(1).and_then(|s| s.parse::<i64>().ok()).unwrap_or(0)
                + f.get(2).and_then(|s| s.parse::<i64>().ok()).unwrap_or(0)
        };
        if line.contains("wdt_bark") {
            wdt += cpu_sum(&f);
        }
        // wifi IRQ name differs by firmware: vanilla "mt7915e"; GL vendor exposes
        // the MT7915 as PCIe "0000:00:00.0" + WED coprocessor "ccif_wo_isr".
        if line.contains("mt7915e") || line.contains("0000:00:00.0") || line.contains("ccif_wo_isr") {
            wifi += cpu_sum(&f);
        }
        if line.contains("pwm-fan") {
            pwm += cpu_sum(&f);
        }
        if line.starts_with("Err:") {
            err += f.get(1).and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
        }
    }
    (wdt.to_string(), wifi.to_string(), pwm.to_string(), err.to_string())
}

fn sync() {
    let _ = Command::new("sync").status();
}

/// A single hardware/system telemetry sample, fields kept as raw strings so the
/// emitted lines are byte-identical to the shell daemon's.
struct Snapshot {
    up: String,
    load: String,
    mem: String,
    temp: String,
    rss: String,
    taint: String,
    nr: String,
    wdt: String,
    wifi: String,
    pwm: String,
    err: String,
    e0r: String,
    e0t: String,
    e0c: String,
    e1r: String,
    e1t: String,
    e1c: String,
    ec: String,
    entropy: String,
    proc_count: String,
}

fn sample() -> Snapshot {
    let (wdt, wifi, pwm, err) = interrupts();
    let nstat = |iface: &str, ctr: &str| read_or0(&format!("/sys/class/net/{}/statistics/{}", iface, ctr));
    Snapshot {
        up: first_field("/proc/uptime"),
        load: first_field("/proc/loadavg"),
        mem: keyed_field("/proc/meminfo", "MemAvailable", 2),
        temp: read_or0("/sys/class/thermal/thermal_zone0/temp"),
        rss: keyed_field("/proc/self/status", "VmRSS", 2),
        taint: read_or0("/proc/sys/kernel/tainted"),
        nr: nr_running(),
        wdt,
        wifi,
        pwm,
        err,
        e0r: nstat("eth0", "rx_errors"),
        e0t: nstat("eth0", "tx_errors"),
        e0c: nstat("eth0", "rx_crc_errors"),
        e1r: nstat("eth1", "rx_errors"),
        e1t: nstat("eth1", "tx_errors"),
        e1c: nstat("eth1", "rx_crc_errors"),
        ec: read_or0("/sys/class/ubi/ubi0/max_ec"),
        entropy: read_or0("/proc/sys/kernel/random/entropy_avail"),
        proc_count: proc_count(),
    }
}

/// Atomically write `content` to `path` (write `.tmp`, rename).
fn write_atomic(path: &str, content: &str) {
    let tmp = format!("{}.tmp", path);
    if fs::write(&tmp, content).is_ok() {
        let _ = fs::rename(&tmp, path);
    }
}
fn append(path: &str, content: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path) {
        use std::io::Write;
        let _ = f.write_all(content.as_bytes());
    }
}

/// Update the heartbeat file + append the snapshot line, `sync` to flash, and
/// rotate the snapshot log periodically. `cycle` is the 1-based loop counter.
pub(crate) fn record_heartbeat(now: i64, cycle: u64) {
    if cycle % HEARTBEAT_INTERVAL_CYCLES != 0 {
        return;
    }
    let s = sample();
    let hb = format!(
        "ts={} uptime={} load={} mem_avail_kb={} temp_milli={} rss_kb={} \
taint={} nr_running={} wdt_bark={} wifi_irq={} pwmfan_irq={} err_irq={} \
eth0_rx_err={} eth0_tx_err={} eth0_crc_err={} eth1_rx_err={} eth1_tx_err={} eth1_crc_err={} \
ubi_max_ec={} entropy={} proc_count={}\n",
        now, s.up, s.load, s.mem, s.temp, s.rss,
        s.taint, s.nr, s.wdt, s.wifi, s.pwm, s.err,
        s.e0r, s.e0t, s.e0c, s.e1r, s.e1t, s.e1c, s.ec, s.entropy, s.proc_count,
    );
    write_atomic(&heartbeat_file(), &hb);

    // 21 positional fields, matching the shell's snapshot line order.
    let snap = format!(
        "{} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {}\n",
        now, s.up, s.load, s.mem, s.temp, s.rss,
        s.taint, s.nr, s.wdt, s.wifi, s.pwm, s.err,
        s.e0r, s.e0t, s.e0c, s.e1r, s.e1t, s.e1c, s.ec, s.entropy, s.proc_count,
    );
    append(&snapshot_log(), &snap);
    sync();

    if cycle % ROTATE_EVERY_CYCLES == 0 {
        tail_lines_inplace(&snapshot_log(), SNAPSHOT_MAX_LINES);
    }
}

/// Seconds since the last heartbeat. `None` only when there is genuinely no
/// prior heartbeat (a true first run). A negative value is possible when the
/// clock hasn't NTP-synced yet at early boot (the heartbeat's timestamp looks
/// "in the future" vs the unsynced wall clock) — that's still a reboot, not a
/// first run, so callers must distinguish `None` from `Some(negative)`.
fn heartbeat_gap(now: i64) -> Option<i64> {
    for line in read_trim(&heartbeat_file()).lines() {
        if let Some(rest) = line.strip_prefix("ts=") {
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(last) = digits.parse::<i64>() {
                return Some(now - last);
            }
        }
    }
    None
}

/// Write a shutdown record from the signal handler path, then `sync`. A recent
/// entry here on the next boot means the reboot was orderly.
pub(crate) fn record_shutdown(now: i64, sig: &str) {
    let up = first_field("/proc/uptime");
    append(&shutdown_log(), &format!("ts={} signal={} uptime={}\n", now, sig, up));
    sync();
    crate::log(&format!("SHUTDOWN signal={} at ts={} uptime={}s — logged to flash", sig, now, up));
}

/// Start a background `logread -f` appending to the syslog-tail file, unless one
/// is already running (tracked via a PID file).
pub(crate) fn start_syslog_tail() {
    if let Ok(pid) = fs::read_to_string(SYSLOG_TAIL_PID) {
        let pid = pid.trim();
        if !pid.is_empty() && std::path::Path::new(&format!("/proc/{}", pid)).exists() {
            return; // already running
        }
    }
    let log_path = syslog_tail_log();
    let file = match fs::OpenOptions::new().create(true).append(true).open(&log_path) {
        Ok(f) => f,
        Err(_) => return,
    };
    match Command::new("logread").arg("-f").stdout(file).stderr(std::process::Stdio::null()).spawn() {
        Ok(child) => {
            let _ = fs::write(SYSLOG_TAIL_PID, child.id().to_string());
            crate::log(&format!("syslog tail started (pid {}) -> {}", child.id(), log_path));
        }
        Err(_) => {}
    }
}

/// Rotate the syslog-tail log if it exceeds the byte cap (keep newest bytes).
pub(crate) fn rotate_syslog_tail(cycle: u64) {
    if cycle % ROTATE_EVERY_CYCLES != 1 {
        return;
    }
    if file_size(&syslog_tail_log()) > SYSLOG_TAIL_MAX_BYTES {
        tail_bytes_inplace(&syslog_tail_log(), SYSLOG_TAIL_MAX_BYTES as usize);
    }
}

/// Append the startup forensic record: gap→verdict plus dmesg / pstore /
/// watchdog / interrupts dumps. Call once at boot, before the first heartbeat.
pub(crate) fn record_boot(now: i64) {
    let _ = fs::create_dir_all(persist_dir());
    let gap = heartbeat_gap(now);
    let verdict = match gap {
        None => "FIRST_RUN (no previous heartbeat)".to_string(),
        // A prior heartbeat exists ⇒ this is a reboot, never a first run. A
        // negative gap means the clock wasn't NTP-synced at boot, so downtime
        // is indeterminate — but it's still a reboot, so flag it abrupt rather
        // than mislabel it FIRST_RUN.
        Some(g) if g < 0 => {
            format!("ABRUPT (downtime indeterminate — clock unsynced at boot; raw {}s)", g)
        }
        Some(g) if g <= 90 => format!("CLEAN (gap={}s — within heartbeat interval)", g),
        Some(g) => format!("ABRUPT (gap={}s — exceeds 90s; system died without warning)", g),
    };

    let mut out = String::new();
    let indent = |s: &str| s.lines().map(|l| format!("  {}\n", l)).collect::<String>();
    out.push('\n');
    out.push_str(&format!("==================== BOOT {} ====================\n", date_string()));
    out.push_str(&format!("ts={} uptime_now={} verdict: {}\n", now, first_field("/proc/uptime"), verdict));
    if gap.is_some() {
        out.push_str("last heartbeat raw:\n");
        out.push_str(&indent(&read_trim(&heartbeat_file())));
    }
    out.push_str("--- last 10 snapshots before boot ---\n");
    out.push_str(&indent(&last_lines(&snapshot_log(), 10)));
    out.push_str("--- shutdown log (presence of recent SHUTDOWN entry = orderly reboot) ---\n");
    out.push_str(&indent(&last_lines(&shutdown_log(), 5)));
    out.push_str("--- last 50 lines of system logread (captured continuously to flash) ---\n");
    out.push_str(&indent(&last_lines(&syslog_tail_log(), 50)));
    out.push_str("--- pstore (kernel oops/panic if any) ---\n");
    if let Ok(rd) = fs::read_dir("/sys/fs/pstore") {
        for e in rd.filter_map(|e| e.ok()) {
            let p = e.path();
            out.push_str(&indent(&p.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string()));
            out.push_str(&format!("--- {} (first 30 lines) ---\n", p.display()));
            out.push_str(&indent(&last_lines_head(&p.to_string_lossy(), 30)));
        }
    }
    out.push_str("--- hardware state at boot ---\n");
    out.push_str(&format!(
        "  taint={}  (baseline: 1=vendor proprietary mod, 4096=vanilla OOT mod; other bits = NEW)\n",
        read_trim("/proc/sys/kernel/tainted")
    ));
    out.push_str("  /proc/interrupts:\n");
    out.push_str(&read_trim("/proc/interrupts").lines().map(|l| format!("    {}\n", l)).collect::<String>());
    out.push_str("  /proc/softirqs (top):\n");
    out.push_str(&read_trim("/proc/softirqs").lines().take(8).map(|l| format!("    {}\n", l)).collect::<String>());
    out.push_str(&format!(
        "  flash health: max_ec={} bad_peb={}\n",
        read_trim("/sys/class/ubi/ubi0/max_ec"),
        read_trim("/sys/class/ubi/ubi0/bad_peb_count")
    ));
    out.push_str(&format!("  entropy_avail={}\n", read_trim("/proc/sys/kernel/random/entropy_avail")));
    out.push_str(&format!(
        "  watchdog: bootstatus={} timeout={}\n",
        read_trim("/sys/class/watchdog/watchdog0/bootstatus"),
        read_trim("/sys/class/watchdog/watchdog0/timeout")
    ));
    // Low-level SoC reset-cause registers, read natively from /dev/mem (no
    // STRICT_DEVMEM on this kernel). 0x1001c000 = WDT/TOPRGU block; the word at
    // +0x0c (WDT_STATUS) encodes the FULL last-reset cause, beyond the single
    // bit `bootstatus` exposes. Captured every boot so a future reset that DOES
    // set a cause bit is recorded.
    out.push_str("  SoC reset registers (/dev/mem 0x1001c000; +0x0c=WDT_STATUS reset-cause):\n");
    const RGU_BASE: u64 = 0x1001c000;
    if let Some(words) = crate::io::read_mmio(RGU_BASE, 16) {
        for (i, w) in words.iter().enumerate() {
            out.push_str(&format!("    0x{:08x}: 0x{:08x}\n", RGU_BASE + (i as u64) * 4, w));
        }
    }
    out.push_str("  mtketh reset events (FE faults / warm-cold counts):\n");
    out.push_str(&read_trim("/proc/mtketh/reset_event").lines().map(|l| format!("    {}\n", l)).collect::<String>());
    let dmesg = Command::new("dmesg").output().map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
    out.push_str("--- dmesg first 50 lines ---\n");
    out.push_str(&dmesg.lines().take(50).map(|l| format!("  {}\n", l)).collect::<String>());
    out.push_str("--- dmesg: ANY mention of reset/reboot/panic/oops ---\n");
    let re = ["reset", "reboot", "panic", "oops", "fault", "warning", "error"];
    out.push_str(
        &dmesg
            .lines()
            .filter(|l| { let ll = l.to_lowercase(); re.iter().any(|k| ll.contains(k)) })
            .take(20)
            .map(|l| format!("  {}\n", l))
            .collect::<String>(),
    );

    append(&boot_log(), &out);
    if file_size(&boot_log()) > BOOT_LOG_MAX_BYTES {
        tail_bytes_inplace(&boot_log(), BOOT_LOG_MAX_BYTES as usize);
    }
    sync();
    crate::log(&format!("boot recorded: {}", verdict));
}

fn date_string() -> String {
    Command::new("date").output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
}

// === reboots.json (consumed by dash3.html) ===

#[derive(Serialize)]
struct Boot {
    ts: i64,
    uptime: i64,
    verdict: String,
    gap: i64,
}
#[derive(Serialize)]
struct Telemetry {
    ts: Vec<i64>,
    load: Vec<f64>,
    mem_mb: Vec<i64>,
    temp_c: Vec<f64>,
    wifi_irq: Vec<i64>,
    #[serde(rename = "proc")]
    proc_count: Vec<i64>,
}
#[derive(Serialize)]
struct Reboots {
    generated: i64,
    uptime: i64,
    current: serde_json::Value,
    boots: Vec<Boot>,
    telemetry: Telemetry,
}

/// Publish `reboots.json`: boot history (parsed from the boot log), current
/// heartbeat fields, and the recent telemetry trend (last 120 snapshots).
pub(crate) fn publish_reboots(now: i64) {
    let uptime: i64 = first_field("/proc/uptime").split('.').next().and_then(|s| s.parse().ok()).unwrap_or(0);

    let boots = parse_boots(&read_trim(&boot_log()));
    let telemetry = parse_telemetry(&last_lines(&snapshot_log(), 120));
    let current = heartbeat_to_json(&read_trim(&heartbeat_file()));

    let doc = Reboots { generated: now, uptime, current, boots, telemetry };
    if let Ok(json) = serde_json::to_string(&doc) {
        write_atomic(&reboots_out(), &json);
    }
}

/// Parse boot-record header lines: `ts=N uptime_now=F verdict: WORD (gap=Ns …)`.
fn parse_boots(boot_log: &str) -> Vec<Boot> {
    let mut boots = Vec::new();
    for line in boot_log.lines() {
        if !line.starts_with("ts=") || !line.contains("uptime_now=") || !line.contains("verdict:") {
            continue;
        }
        let field = |key: &str| -> Option<String> {
            line.split_whitespace()
                .find_map(|t| t.strip_prefix(key).map(String::from))
        };
        let ts: i64 = match field("ts=").and_then(|s| s.parse().ok()) {
            Some(v) => v,
            None => continue,
        };
        let uptime: i64 =
            field("uptime_now=").and_then(|s| s.split('.').next().and_then(|x| x.parse().ok())).unwrap_or(0);
        let verdict = line
            .split("verdict:")
            .nth(1)
            .and_then(|r| r.split_whitespace().next())
            .unwrap_or("")
            .to_string();
        let gap = line
            .split_once("gap=")
            .and_then(|(_, r)| {
                let d: String = r.chars().take_while(|c| c.is_ascii_digit()).collect();
                d.parse().ok()
            })
            .unwrap_or(-1);
        boots.push(Boot { ts, uptime, verdict, gap });
    }
    boots
}

/// Parse the last snapshot lines into parallel telemetry arrays for charting.
fn parse_telemetry(snapshots: &str) -> Telemetry {
    let (mut ts, mut load, mut mem_mb, mut temp_c, mut wifi_irq, mut proc_count) =
        (vec![], vec![], vec![], vec![], vec![], vec![]);
    for line in snapshots.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 21 {
            continue;
        }
        let i = |n: usize| f[n].parse::<i64>().unwrap_or(0);
        let fl = |n: usize| f[n].parse::<f64>().unwrap_or(0.0);
        ts.push(i(0));
        load.push(fl(2));
        mem_mb.push(i(3) / 1024);
        temp_c.push((i(4) as f64) / 1000.0);
        wifi_irq.push(i(9));
        proc_count.push(i(20));
    }
    Telemetry { ts, load, mem_mb, temp_c, wifi_irq, proc_count }
}

/// Turn the heartbeat `k=v k=v …` line into a JSON object of numeric fields.
fn heartbeat_to_json(hb: &str) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    for tok in hb.split_whitespace() {
        if let Some((k, v)) = tok.split_once('=') {
            if let Ok(n) = v.parse::<i64>() {
                map.insert(k.to_string(), serde_json::json!(n));
            } else if let Ok(fl) = v.parse::<f64>() {
                if let Some(num) = serde_json::Number::from_f64(fl) {
                    map.insert(k.to_string(), serde_json::Value::Number(num));
                }
            }
        }
    }
    serde_json::Value::Object(map)
}

// === file utilities ===

fn file_size(path: &str) -> u64 {
    fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}
/// Last `n` lines of a file (whole-file read; these logs are small/capped).
fn last_lines(path: &str, n: usize) -> String {
    let content = read_trim(path);
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(n);
    lines[start..].join("\n")
}
/// First `n` lines of a file (for pstore dumps).
fn last_lines_head(path: &str, n: usize) -> String {
    read_trim(path).lines().take(n).collect::<Vec<_>>().join("\n")
}
fn tail_lines_inplace(path: &str, n: usize) {
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return,
    };
    let lines: Vec<&str> = content.lines().collect();
    if lines.len() > n {
        let start = lines.len() - n;
        write_atomic(path, &format!("{}\n", lines[start..].join("\n")));
    }
}
fn tail_bytes_inplace(path: &str, max: usize) {
    let bytes = match fs::read(path) {
        Ok(b) => b,
        Err(_) => return,
    };
    if bytes.len() > max {
        let start = bytes.len() - max;
        let tail = String::from_utf8_lossy(&bytes[start..]).to_string();
        write_atomic(path, &tail);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_boot_verdicts() {
        let log = "\
==================== BOOT x ====================
ts=1000 uptime_now=50.12 verdict: FIRST_RUN (no previous heartbeat)
==================== BOOT x ====================
ts=2000 uptime_now=700.50 verdict: CLEAN (gap=6s — within heartbeat interval)
==================== BOOT x ====================
ts=3000 uptime_now=55.00 verdict: ABRUPT (gap=240s — exceeds 90s)";
        let b = parse_boots(log);
        assert_eq!(b.len(), 3);
        assert_eq!((b[0].ts, b[0].verdict.as_str(), b[0].gap), (1000, "FIRST_RUN", -1));
        assert_eq!((b[1].ts, b[1].uptime, b[1].verdict.as_str(), b[1].gap), (2000, 700, "CLEAN", 6));
        assert_eq!((b[2].verdict.as_str(), b[2].gap), ("ABRUPT", 240));
    }

    #[test]
    fn telemetry_from_snapshots() {
        let snaps = "\
100 10 0.20 250000 45000 1200 1 2 0 111 0 0 0 0 0 0 0 0 44 256 90
105 15 0.30 248000 46000 1200 1 1 0 222 0 0 0 0 0 0 0 0 44 256 92";
        let t = parse_telemetry(snaps);
        assert_eq!(t.ts, vec![100, 105]);
        assert_eq!(t.load, vec![0.20, 0.30]);
        assert_eq!(t.mem_mb, vec![244, 242]); // 250000/1024, 248000/1024
        assert_eq!(t.temp_c, vec![45.0, 46.0]);
        assert_eq!(t.wifi_irq, vec![111, 222]);
        assert_eq!(t.proc_count, vec![90, 92]);
    }

    #[test]
    fn heartbeat_json_typed() {
        let hb = "ts=3500 uptime=120.00 load=0.10 temp_milli=47000 wifi_irq=333 proc_count=95";
        let v = heartbeat_to_json(hb);
        assert_eq!(v["ts"], 3500);
        assert_eq!(v["wifi_irq"], 333);
        assert_eq!(v["proc_count"], 95);
        assert!(v["load"].as_f64().is_some());
    }

    #[test]
    fn gap_verdict_boundaries() {
        // Mirrors record_boot's match: None = genuine first run; a prior
        // heartbeat (Some) is always a reboot — a negative gap (clock unsynced
        // at boot) is ABRUPT, NOT FIRST_RUN (the old bug).
        let verdict = |gap: Option<i64>| match gap {
            None => "FIRST_RUN",
            Some(g) if g < 0 => "ABRUPT",
            Some(g) if g <= 90 => "CLEAN",
            Some(_) => "ABRUPT",
        };
        assert_eq!(verdict(None), "FIRST_RUN");
        assert_eq!(verdict(Some(-5)), "ABRUPT"); // clock unsynced, still a reboot
        assert_eq!(verdict(Some(6)), "CLEAN");
        assert_eq!(verdict(Some(90)), "CLEAN");
        assert_eq!(verdict(Some(91)), "ABRUPT");
        assert_eq!(verdict(Some(240)), "ABRUPT");
    }
}
