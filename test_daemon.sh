#!/bin/sh
# Test suite for dash_daemon.sh
#
# Sources the daemon with DASH_DAEMON_TEST=1 so the main loop doesn't run;
# then exercises every probe / schema / helper function with assertions.
#
# Run with: sh test_daemon.sh
# Mocking strategy: override external commands (curl, ping, iwinfo, etc.) with
# shell functions before calling a probe — shell functions take precedence
# over PATH lookups.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "${GREEN}PASS${NC}: %s\n" "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "${RED}FAIL${NC}: %s\n      expected: %s\n      got:      %s\n" "$1" "$2" "$3"
}

assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$3" | grep -qF "$2"; then pass "$1"; else fail "$1" "contains $2" "$3"; fi
}

assert_match() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$3" | grep -qE "$2"; then pass "$1"; else fail "$1" "matches /$2/" "$3"; fi
}

assert_valid_json() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$2" | jsonfilter -e '@' >/dev/null 2>&1; then
        pass "$1"
    else
        fail "$1" "valid JSON (per jsonfilter)" "$2"
    fi
}

section() { printf "\n${YELLOW}=== %s ===${NC}\n" "$1"; }

# --- Source the daemon under test ---
DASH_DAEMON_TEST=1
SCRIPT_DIR=$(dirname "$0")
# Redirect any stray output during sourcing
. "$SCRIPT_DIR/dash_daemon.sh"

# Override paths to use a sandbox so tests don't trample real router state.
SANDBOX=$(mktemp -d 2>/dev/null || mktemp -d -t dashtest)
JSON_OUT="$SANDBOX/data.json"
REBOOTS_OUT="$SANDBOX/reboots.json"
FETCH_LOG="$SANDBOX/fetch.log"
PING_LOG="$SANDBOX/ping.log"
THRU_LOG="$SANDBOX/thru.log"
AVAIL_LOG="$SANDBOX/avail.log"
CLIENTS_LOG="$SANDBOX/clients.log"
LAST_SUCCESS_FILE="$SANDBOX/last_success.txt"
UPLINK_CACHE="$SANDBOX/uplink_cache.json"
LUCI_HINTS_CACHE="$SANDBOX/luci_hints.cache"
CLIENTS_LIST_FILE="$SANDBOX/clients_list.json"
IW_CACHE="$SANDBOX/iw_cache"

trap 'rm -rf "$SANDBOX"' EXIT

############################################################
section "json_escape (pure)"
############################################################

assert_eq "plain string"        "hello"        "$(json_escape hello)"
assert_eq "embedded space"      "foo bar"      "$(json_escape 'foo bar')"
assert_eq "double-quote"        'bad\"name'    "$(json_escape 'bad"name')"
assert_eq "backslash"           'a\\b'         "$(json_escape 'a\b')"
assert_eq "quote + backslash"   'a\\b\"c'      "$(json_escape 'a\b"c')"
assert_eq "tab stripped"        "ab"           "$(json_escape "$(printf 'a\tb')")"
assert_eq "newline stripped"    "ab"           "$(json_escape "$(printf 'a\nb')")"
assert_eq "empty string"        ""             "$(json_escape '')"

############################################################
section "compute_avail (pure)"
############################################################

assert_eq "all good -> 1"          "1" "$(compute_avail 204 50 15.5)"
assert_eq "ping fails -> 0"        "0" "$(compute_avail 204 50 -1)"
assert_eq "web code !=204 -> 0"    "0" "$(compute_avail 0 -1 15.5)"
assert_eq "web ms <=0 -> 0"        "0" "$(compute_avail 204 0 15.5)"
assert_eq "web ms negative -> 0"   "0" "$(compute_avail 204 -1 15.5)"
assert_eq "all failed -> 0"        "0" "$(compute_avail 0 -1 -1)"
assert_eq "non-numeric ms -> 0"    "0" "$(compute_avail 204 abc 15.5)"

############################################################
section "record_history"
############################################################

# Fresh log
rm -f "$FETCH_LOG"
result=$(record_history "10" "$FETCH_LOG")
assert_eq "single entry CSV"       "10"        "$result"

result=$(record_history "20" "$FETCH_LOG")
assert_eq "two entries CSV"        "10,20"     "$result"

result=$(record_history "30" "$FETCH_LOG")
assert_eq "three entries CSV"      "10,20,30"  "$result"

# Negative integer (default pattern allows -?[0-9]+)
result=$(record_history "-1" "$FETCH_LOG")
assert_eq "negative integer ok"    "10,20,30,-1"  "$result"

# Pattern: only 0/1
rm -f "$AVAIL_LOG"
record_history "1" "$AVAIL_LOG" "^[01]$" > /dev/null
record_history "0" "$AVAIL_LOG" "^[01]$" > /dev/null
record_history "1" "$AVAIL_LOG" "^[01]$" > /dev/null
result=$(record_history "0" "$AVAIL_LOG" "^[01]$")
assert_eq "avail pattern filter"   "1,0,1,0"   "$result"

############################################################
section "probe_uplink_json (file-based)"
############################################################

# Empty cache -> DEFAULT
rm -f "$UPLINK_CACHE"
result=$(probe_uplink_json)
assert_eq "missing cache -> DEFAULT" "$DEFAULT_UPLINK" "$result"

# Garbage cache -> DEFAULT
echo "garbage not json" > "$UPLINK_CACHE"
result=$(probe_uplink_json)
assert_eq "garbage cache -> DEFAULT" "$DEFAULT_UPLINK" "$result"

# Valid JSON missing required field -> DEFAULT
echo '{"foo":"bar"}' > "$UPLINK_CACHE"
result=$(probe_uplink_json)
assert_eq "missing connection_type -> DEFAULT" "$DEFAULT_UPLINK" "$result"

# Valid JSON with connection_type -> echoed back
valid='{"connection_type":"starlink","isp":"SpaceX"}'
echo "$valid" > "$UPLINK_CACHE"
result=$(probe_uplink_json)
assert_eq "valid cache echoed" "$valid" "$result"

############################################################
section "probe_uplink_ssid (mocked iwinfo)"
############################################################

# Override `timeout` so it doesn't fork a PATH binary (which would bypass
# our shell-function mock of iwinfo). The test version just drops the
# duration arg and runs the rest as a shell command — so the mocked
# `iwinfo` function gets invoked.
timeout() { shift; "$@"; }

# Mock 1: iwinfo returns a quoted SSID on sta0
iwinfo() {
    case "$1" in
        sta0) echo 'wlan0     ESSID: "VilaVita_Wi-Fi"' ;;
        sta1) echo 'wlan1     ESSID: unknown' ;;
    esac
}
result=$(probe_uplink_ssid)
assert_eq "sta0 SSID extracted" "VilaVita_Wi-Fi" "$result"

# Mock 2: SSID with embedded quotes — iwinfo's awk parser strips ALL quotes
# (because iwinfo wraps SSIDs in quotes, e.g. ESSID: "Name"). So a quote in
# the SSID itself is lossy here but cannot break the JSON downstream. The
# json_escape unit tests above prove escaping handles quotes when it sees
# them; this test pins down what actually reaches json_escape.
iwinfo() {
    case "$1" in
        sta0) echo 'wlan0     ESSID: "bad"name"' ;;
        sta1) echo 'wlan1     ESSID: unknown' ;;
    esac
}
result=$(probe_uplink_ssid)
assert_eq "iwinfo strips embedded quotes" "badname" "$result"

# Mock 3: both interfaces unknown, no UCI → "Not connected"
iwinfo() { echo 'wlan0     ESSID: unknown'; }
uci() { return 1; }
result=$(probe_uplink_ssid)
assert_eq "all fail -> Not connected" "Not connected" "$result"

unset -f iwinfo uci timeout

############################################################
section "probe_web (mocked curl)"
############################################################

# Mock: curl returns 204 (success)
curl() { echo "204"; }
result=$(probe_web 12345)
assert_match "204 emits int ms"        "^204 [0-9]+$"        "$result"

# Mock: curl returns "000" (failure) — must strip leading zeros to '0'
curl() { echo "000"; }
result=$(probe_web 12345)
assert_eq "curl 000 -> 0 -1"          "0 -1"                 "$result"

# Mock: curl returns empty (catastrophic failure)
curl() { echo ""; }
result=$(probe_web 12345)
assert_eq "curl empty -> 0 -1"        "0 -1"                 "$result"

# Mock: curl returns valid non-204 (captive portal redirect)
curl() { echo "302"; }
result=$(probe_web 12345)
assert_eq "non-204 -> code -1 ms"     "302 -1"               "$result"

# Mock: curl returns non-numeric garbage
curl() { echo "abc"; }
result=$(probe_web 12345)
assert_eq "garbage -> 0 -1"           "0 -1"                 "$result"

unset -f curl

############################################################
section "probe_ping (mocked ping)"
############################################################

# Mock: ping returns valid output with float ms
ping() { echo "PING google.com: 56 data bytes
64 bytes from 1.2.3.4: seq=0 ttl=118 time=15.916 ms"; }
result=$(probe_ping)
assert_eq "ping 15.916ms"             "15.916"   "$result"

# Mock: ping returns valid integer ms
ping() { echo "64 bytes: time=20 ms"; }
result=$(probe_ping)
assert_eq "ping int 20ms"             "20"       "$result"

# Mock: ping returns no time= field (timeout)
ping() { echo "PING google.com: timeout"; }
result=$(probe_ping)
assert_eq "ping timeout -> -1"        "-1"       "$result"

# Mock: ping fails (bad address)
ping() { return 1; }
result=$(probe_ping)
assert_eq "ping fails -> -1"          "-1"       "$result"

# Mock: ping returns garbage that grep matches but isn't a number
ping() { echo "time=abc"; }
result=$(probe_ping)
assert_eq "ping garbage -> -1"        "-1"       "$result"

unset -f ping

############################################################
section "emit_data_json schema"
############################################################

# 1. No args at all — outage doc must be VALID JSON and have all expected keys
outage=$(emit_data_json)
assert_valid_json "no-args outage doc parses" "$outage"
assert_contains  "outage has avail.current 0"    '"current": 0'      "$outage"
assert_contains  "outage has web.code 0"         '"code": 0'         "$outage"
assert_contains  "outage has web.ms -1"          '"ms": -1'          "$outage"
assert_contains  "outage has ping.current -1"    '"current": -1'     "$outage"
assert_contains  "outage has SSID --"            '"uplink_ssid": "--"' "$outage"
assert_contains  "outage has uplink connection_type" '"connection_type":"unknown"' "$outage"
assert_contains  "outage has empty clients.list" '"list": []'        "$outage"

# 2. Full args — every value flows through to output
full=$(emit_data_json 1700000000 "MyAP" '{"connection_type":"starlink","isp":"SpaceX","thresholds":{"ping":{"good":60,"warn":120},"web":{"good":200,"warn":400}}}' \
    204 50 "50,60,70" \
    15.5 "16,15" \
    100 200 500 1000 "100,200" "300,400" \
    1 1699999000 "1,1,0,1" \
    3 100 50 "3,3" '{"mac":"AA:BB:CC:DD:EE:FF","name":"x","ip":"1.2.3.4","iface":"5G","tx":1,"rx":1}')
assert_valid_json "full doc parses"         "$full"
assert_contains  "ts populated"          '"ts": 1700000000'   "$full"
assert_contains  "ssid populated"        '"uplink_ssid": "MyAP"' "$full"
assert_contains  "uplink populated"      '"connection_type":"starlink"' "$full"
assert_contains  "web code 204"          '"code": 204'        "$full"
assert_contains  "web ms 50"             '"ms": 50'           "$full"
assert_contains  "web history"           '"history": [50,60,70]' "$full"
assert_contains  "ping 15.5"             '"current": 15.5'    "$full"
assert_contains  "clients online 3"      '"online": 3'        "$full"
assert_contains  "client list element"   '"mac":"AA:BB:CC:DD:EE:FF"' "$full"

# 3. JSON-escaped SSID flows through correctly (no extra quoting)
esc=$(json_escape 'bad"name')
result=$(emit_data_json 1 "$esc")
assert_valid_json "escaped SSID stays valid JSON" "$result"
assert_contains  "escaped SSID literal"  '"uplink_ssid": "bad\"name"' "$result"

############################################################
section "classify_by_asn_number"
############################################################

assert_eq "Starlink 14593"      "starlink"      "$(classify_by_asn_number 'AS14593 SpaceX Services')"
assert_eq "Gogo 21928"          "airplane"      "$(classify_by_asn_number 'AS21928 Gogo LLC')"
assert_eq "ViaSat 40306"        "geo_satellite" "$(classify_by_asn_number 'AS40306 ViaSat,Inc.')"
assert_eq "Marlink 15146"       "maritime"      "$(classify_by_asn_number 'AS15146 Marlink')"
assert_eq "Unknown empty"       ""              "$(classify_by_asn_number 'AS7922 Comcast' 2>/dev/null)"

############################################################
section "classify_connection (keyword fallback)"
############################################################

assert_eq "Starlink keyword"    "starlink"      "$(classify_connection '"isp":"STARLINK Internet","as":"AS99999"')"
assert_eq "Gogo keyword"        "airplane"      "$(classify_connection '"isp":"GOGO LLC","as":"AS99999"')"
assert_eq "Viasat keyword"      "geo_satellite" "$(classify_connection '"isp":"VIASAT","as":"AS99999"')"
assert_eq "T-Mobile keyword"    "cellular"      "$(classify_connection '"isp":"T-MOBILE USA","as":"AS99999"')"
assert_eq "Default landline"    "landline"      "$(classify_connection '"isp":"Comcast Cable","as":"AS7922"')"

############################################################
section "get_thresholds"
############################################################

assert_eq "starlink thresholds" "60 120 200 400"     "$(get_thresholds starlink)"
assert_eq "airplane thresholds" "775 1100 2000 3500" "$(get_thresholds airplane)"
assert_eq "geo_sat thresholds"  "775 1100 2000 3500" "$(get_thresholds geo_satellite)"
assert_eq "cellular thresholds" "80 150 250 500"     "$(get_thresholds cellular)"
assert_eq "landline default"    "30 80 100 300"      "$(get_thresholds landline)"
assert_eq "unknown -> default"  "30 80 100 300"      "$(get_thresholds xyz)"

############################################################
section "read_system_state"
############################################################

# Real call against this host's /proc — should give us 5 numeric fields.
state=$(read_system_state)
field_count=$(echo "$state" | awk '{print NF}')
assert_eq "5 fields"                   "5"        "$field_count"
assert_match "uptime numeric"          "^[0-9.]+ "        "$state"
assert_match "load numeric"            "^[^ ]+ [0-9.]+ "  "$state"

############################################################
section "read_hw_state"
############################################################

# Real call: should produce 14 fields, every one a non-negative integer.
hw=$(read_hw_state)
field_count=$(echo "$hw" | awk '{print NF}')
assert_eq "14 fields"                  "14"       "$field_count"
# Every field must match /^[0-9]+$/ (non-negative int). Counter-based.
all_int=$(echo "$hw" | awk '{
    for (i=1; i<=NF; i++) if ($i !~ /^[0-9]+$/) { print "BAD@"i":"$i; exit }
    print "OK"
}')
assert_eq "all fields non-negative integers" "OK" "$all_int"

# wifi_irq pattern must populate on BOTH firmwares. This mirrors the awk
# expression in read_hw_state: vanilla labels the WiFi IRQ "mt7915e"; the
# GL.iNet vendor (MediaTek SDK) driver exposes the MT7915 as PCIe
# "0000:00:00.0" plus a WED offload coprocessor "ccif_wo_isr".
wifi_irq_sum() {
    awk '/mt7915e|0000:00:00\.0|ccif_wo_isr/{s+=$2+$3} END{print s+0}' "$1"
}
cat > "$SANDBOX/irq_vendor" <<'IRQ'
           CPU0       CPU1
  7:    2400683          0     GICv3 237 Level     0000:00:00.0
  9:       6170          0     GICv3 243 Level     ccif_wo_isr
 11:          0          0     GICv3 142 Level     wdt_bark
 47:          0          0   mt-eint  29 Edge      pwm-fan
IRQ
assert_eq "vendor wifi_irq sums PCIe + WED" "2406853" "$(wifi_irq_sum "$SANDBOX/irq_vendor")"
cat > "$SANDBOX/irq_vanilla" <<'IRQ'
           CPU0       CPU1
 74:       8165          0     GICv3 237 Level     mt7915e
 78:          0          0     GICv3 142 Level     wdt_bark
IRQ
assert_eq "vanilla wifi_irq matches mt7915e" "8165" "$(wifi_irq_sum "$SANDBOX/irq_vanilla")"
echo "  3: 100 200 GICv3 30 Level arch_timer" > "$SANDBOX/irq_none"
assert_eq "no wifi IRQ line -> 0" "0" "$(wifi_irq_sum "$SANDBOX/irq_none")"
unset -f wifi_irq_sum

############################################################
section "heartbeat_gap_seconds"
############################################################

# Override the persistent paths to use the sandbox
HEARTBEAT_FILE="$SANDBOX/heartbeat.txt"
SNAPSHOT_LOG="$SANDBOX/snapshot.log"
BOOT_LOG="$SANDBOX/boot.log"
PERSIST_DIR="$SANDBOX"

# No file at all -> -1
rm -f "$HEARTBEAT_FILE"
result=$(heartbeat_gap_seconds 1000)
assert_eq "missing heartbeat -> -1"    "-1"       "$result"

# Garbage content -> -1
echo "not a heartbeat" > "$HEARTBEAT_FILE"
result=$(heartbeat_gap_seconds 1000)
assert_eq "garbage heartbeat -> -1"    "-1"       "$result"

# Valid heartbeat at ts=500, now=1000 -> 500
echo "ts=500 uptime=12.3 load=0.1 mem_avail_kb=200000 temp_milli=45000 rss_kb=1500" > "$HEARTBEAT_FILE"
result=$(heartbeat_gap_seconds 1000)
assert_eq "valid heartbeat gap"        "500"      "$result"

# Negative-looking ts (shouldn't happen, but verify regex rejects it)
echo "ts=-1 uptime=12 load=0.1" > "$HEARTBEAT_FILE"
result=$(heartbeat_gap_seconds 1000)
assert_eq "negative ts rejected"       "-1"       "$result"

############################################################
section "record_heartbeat"
############################################################

# With HEARTBEAT_INTERVAL_CYCLES=12, no write until call 12.
HEARTBEAT_COUNTER=0
HEARTBEAT_INTERVAL_CYCLES=12
rm -f "$HEARTBEAT_FILE" "$SNAPSHOT_LOG"

# First 11 calls: no write
i=1
while [ $i -lt 12 ]; do
    record_heartbeat 1000
    i=$((i + 1))
done
if [ -f "$HEARTBEAT_FILE" ]; then
    fail "no write before interval" "no file" "file exists"
else
    pass "no write before HEARTBEAT_INTERVAL_CYCLES"
fi

# 12th call: writes
record_heartbeat 1000
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$HEARTBEAT_FILE" ]; then
    pass "writes on interval boundary"
else
    fail "writes on interval boundary" "file exists" "no file"
fi

# Heartbeat file is a single-line ts=... record carrying all hw fields
content=$(cat "$HEARTBEAT_FILE")
assert_match "heartbeat ts field"      "^ts=1000 uptime=" "$content"
assert_match "heartbeat has taint"     "taint=[0-9]+"     "$content"
assert_match "heartbeat has wdt_bark"  "wdt_bark=[0-9]+"  "$content"
assert_match "heartbeat has eth0 errs" "eth0_rx_err=[0-9]+ eth0_tx_err=[0-9]+ eth0_crc_err=[0-9]+" "$content"
assert_match "heartbeat has entropy"   "entropy=[0-9]+"   "$content"
assert_match "heartbeat has proc_count" "proc_count=[0-9]+" "$content"

# Snapshot log: 1 line, 21 positional fields (added proc_count)
snap_lines=$(wc -l < "$SNAPSHOT_LOG")
assert_eq "snapshot log line count"    "1"        "$snap_lines"
snap_fields=$(awk '{print NF; exit}' "$SNAPSHOT_LOG")
assert_eq "snapshot has 21 positional fields" "21" "$snap_fields"

# 11 more calls: still 1 snapshot line, 2nd interval not reached
i=1
while [ $i -lt 12 ]; do
    record_heartbeat 1060
    i=$((i + 1))
done
snap_lines=$(wc -l < "$SNAPSHOT_LOG")
assert_eq "snapshot only on interval"  "1"        "$snap_lines"

# 24th call (2nd interval) writes
record_heartbeat 1060
snap_lines=$(wc -l < "$SNAPSHOT_LOG")
assert_eq "second interval appends"    "2"        "$snap_lines"

# Final check: with HEARTBEAT_INTERVAL_CYCLES=1 (production setting), every
# call writes. Reset state — this is independent of the gating tests above.
HEARTBEAT_COUNTER=0
HEARTBEAT_INTERVAL_CYCLES=1
rm -f "$HEARTBEAT_FILE" "$SNAPSHOT_LOG"
record_heartbeat 2000
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$HEARTBEAT_FILE" ]; then
    pass "5s heartbeat (interval=1): writes every call"
else
    fail "5s heartbeat" "file exists" "no file"
fi
record_heartbeat 2005
snap_lines=$(wc -l < "$SNAPSHOT_LOG")
assert_eq "interval=1: 2nd call also writes" "2" "$snap_lines"

############################################################
section "record_boot"
############################################################

# Reset boot log; create a heartbeat at ts=100 and call record_boot.
# Mock `date +%s` so we control "now". Override `date` with a function that
# returns 200 for +%s but defers to the real binary otherwise.
rm -f "$BOOT_LOG"
echo "ts=100 uptime=50 load=0.1 mem_avail_kb=200000 temp_milli=45000 rss_kb=1500" > "$HEARTBEAT_FILE"
# Add two snapshots so record_boot can dump them
echo "100 50 0.1 200000 45000 1500" > "$SNAPSHOT_LOG"
echo "160 110 0.2 199000 46000 1520" >> "$SNAPSHOT_LOG"

# Mock `date`: `+%s` returns 200; anything else calls real date
real_date=$(command -v date)
date() { if [ "$1" = "+%s" ]; then echo 200; else "$real_date" "$@"; fi; }

record_boot
unset -f date

TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$BOOT_LOG" ]; then pass "boot log created"
else fail "boot log created" "file" "missing"; fi

log_content=$(cat "$BOOT_LOG")
assert_contains "verdict line present" "verdict:" "$log_content"
assert_contains "verdict ABRUPT for 100s gap" "ABRUPT" "$log_content"
assert_contains "last 10 snapshots dumped"    "100 50 0.1" "$log_content"
assert_contains "second snapshot dumped"      "160 110 0.2" "$log_content"

# Clean run: heartbeat 70s ago is within tolerance — CLEAN verdict
rm -f "$BOOT_LOG"
echo "ts=130 uptime=50 load=0.1 mem_avail_kb=200000 temp_milli=45000 rss_kb=1500" > "$HEARTBEAT_FILE"
date() { if [ "$1" = "+%s" ]; then echo 200; else "$real_date" "$@"; fi; }
record_boot
unset -f date
log_content=$(cat "$BOOT_LOG")
assert_contains "70s gap -> CLEAN"     "CLEAN" "$log_content"

# No prior heartbeat -> FIRST_RUN
rm -f "$BOOT_LOG" "$HEARTBEAT_FILE"
date() { if [ "$1" = "+%s" ]; then echo 200; else "$real_date" "$@"; fi; }
record_boot
unset -f date
log_content=$(cat "$BOOT_LOG")
assert_contains "no heartbeat -> FIRST_RUN" "FIRST_RUN" "$log_content"

############################################################
section "record_shutdown"
############################################################

SHUTDOWN_LOG="$SANDBOX/shutdown.log"
rm -f "$SHUTDOWN_LOG"

record_shutdown TERM
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$SHUTDOWN_LOG" ]; then pass "shutdown log created"
else fail "shutdown log created" "file" "missing"; fi

content=$(cat "$SHUTDOWN_LOG")
assert_match "shutdown ts field"      "^ts=[0-9]+"      "$content"
assert_match "shutdown signal field"  "signal=TERM"     "$content"
assert_match "shutdown uptime field"  "uptime=[0-9.]+"  "$content"

# Two consecutive signals append, don't overwrite
record_shutdown INT
lines=$(wc -l < "$SHUTDOWN_LOG")
assert_eq "shutdown log appends, not overwrites" "2" "$lines"
last=$(tail -1 "$SHUTDOWN_LOG")
assert_match "second entry has INT" "signal=INT" "$last"

############################################################
section "probe_throughput PRIMARY: gl-clients get_speed (offload-aware)"
############################################################

# GL.iNet vendor firmware exposes per-client byte accounting via
# `ubus call gl-clients get_speed`, which captures WED hardware-offloaded
# traffic that /proc/net/dev misses. Mock both ubus (the data source) and
# jsonfilter (absent on the dev host) for a deterministic test. speed_rx is
# the download direction, speed_tx the upload; both bytes/sec.
ubus() { echo "$MOCK_GETSPEED"; }
jsonfilter() {
    # Minimal stand-in: `jsonfilter -e '@.speed_rx'` reads JSON on stdin and
    # prints the integer value of the named key (empty if absent/non-numeric).
    local key
    case "$2" in
        *speed_rx*) key=speed_rx ;;
        *speed_tx*) key=speed_tx ;;
        *) cat; return ;;
    esac
    sed -n "s/.*\"$key\"[: ]*\([0-9][0-9]*\).*/\1/p"
}

# The real 88 Mbps speedtest sample: 11,190,619 B/s down, 65,838 B/s up.
MOCK_GETSPEED='{ "speed_rx": 11190619, "speed_tx": 65838 }'
result=$(probe_throughput 1000)
# tx_kbps (DL) = 11190619*8/1000 = 89524 ; rx_kbps (UL) = 65838*8/1000 = 526
assert_eq "get_speed: download -> tx_kbps, upload -> rx_kbps" "526 89524 gl-clients" "$result"

MOCK_GETSPEED='{ "speed_rx": 0, "speed_tx": 0 }'
result=$(probe_throughput 1005)
assert_eq "get_speed: idle -> 0 0" "0 0 gl-clients" "$result"

# Symmetric check — upload-dominant sample maps to rx_kbps.
MOCK_GETSPEED='{ "speed_rx": 4000, "speed_tx": 1000 }'
result=$(probe_throughput 1010)
# tx_kbps = 4000*8/1000 = 32 (DL) ; rx_kbps = 1000*8/1000 = 8 (UL)
assert_eq "get_speed: upload-dominant -> rx_kbps" "8 32 gl-clients" "$result"

# Malformed/missing fields → 0 0 but still tagged gl-clients (we got a reply).
MOCK_GETSPEED='{ "speed_rx": "x" }'
result=$(probe_throughput 1015)
assert_eq "get_speed: malformed fields -> 0 0" "0 0 gl-clients" "$result"

unset -f ubus jsonfilter
unset MOCK_GETSPEED

############################################################
section "probe_throughput FALLBACK: /proc/net/dev (no gl-clients)"
############################################################

# When gl-clients is absent (vanilla OpenWrt), the ubus call yields nothing and
# the probe falls back to /proc/net/dev byte deltas, tagged "proc-net-dev".
# Mock ubus to emit nothing so this path is exercised deterministically.
ubus() { return 1; }

# Helper: write a minimal /proc/net/dev fixture for the given iface lines.
# Header is two lines (the kernel always emits this); body is one line per
# iface in the order requested. Caller passes "name rx_bytes tx_bytes" tuples.
# Other counter columns (rx_packets, errs, drops, fifo, frame, compressed,
# multicast for rx; tx_packets, errs, drops, fifo, colls, carrier, compressed
# for tx) are 0 — only cols 2 (rx_bytes) and 10 (tx_bytes) matter to the probe.
write_proc_net_dev() {
    local file="$1"; shift
    {
        echo "Inter-|   Receive                                                |  Transmit"
        echo " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed"
        while [ $# -ge 3 ]; do
            # iface: rx_bytes rx_packets errs drop fifo frame compressed multicast tx_bytes tx_packets errs drop fifo colls carrier compressed
            printf "%6s: %s 0 0 0 0 0 0 0 %s 0 0 0 0 0 0 0\n" "$1" "$2" "$3"
            shift 3
        done
    } > "$file"
}

THRU_CACHE="$SANDBOX/thru_cache"
PROC_NET_DEV="$SANDBOX/proc_net_dev"

# --- vendor names: ra0 + apclix0 + apcli0 ---
WIFI_IFACES="ra0 wlan0 wlan1 apclix0 apcli0"
rm -f "$THRU_CACHE"
write_proc_net_dev "$PROC_NET_DEV" \
    lo 100 100 \
    eth0 9999 9999 \
    ra0 1000 2000 \
    apclix0 500 1500

# First call: no cache → 0 0 (otherwise the dashboard would render the boot
# totals as a fake spike)
result=$(probe_throughput 1000)
assert_eq "first call (no cache) -> 0 0" "0 0 proc-net-dev" "$result"

# Cache should now exist with the summed totals (ra0 + apclix0 = 1500 rx, 3500 tx)
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$THRU_CACHE" ]; then pass "first call writes cache"
else fail "first call writes cache" "file exists" "no file"; fi

cache_line=$(cat "$THRU_CACHE")
assert_eq "cache holds vendor totals" "1000 1500 3500" "$cache_line"

# Second call: 10 seconds later, +12500 rx bytes (across ifaces), +25000 tx bytes
# Expected rx_kbps = 12500 * 8 / 1000 / 10 = 10
# Expected tx_kbps = 25000 * 8 / 1000 / 10 = 20
write_proc_net_dev "$PROC_NET_DEV" \
    lo 100 100 \
    eth0 9999 9999 \
    ra0 6000 12000 \
    apclix0 8000 16500
result=$(probe_throughput 1010)
assert_eq "second call: rx/tx kbps from byte delta" "10 20 proc-net-dev" "$result"

# Third call with same byte counters (no traffic) → 0 0
result=$(probe_throughput 1015)
assert_eq "no traffic -> 0 0" "0 0 proc-net-dev" "$result"

# Counter rollback (iface bounced) → clamped to 0 instead of huge negative
write_proc_net_dev "$PROC_NET_DEV" \
    lo 100 100 \
    eth0 9999 9999 \
    ra0 100 200 \
    apclix0 50 150
result=$(probe_throughput 1020)
assert_eq "counter rollback clamps to 0" "0 0 proc-net-dev" "$result"

# --- vanilla OpenWrt names: wlan0 + wlan1 ---
rm -f "$THRU_CACHE"
write_proc_net_dev "$PROC_NET_DEV" \
    lo 100 100 \
    wlan0 1000 2000 \
    wlan1 500 1500
result=$(probe_throughput 2000)
assert_eq "vanilla first call -> 0 0" "0 0 proc-net-dev" "$result"
cache_line=$(cat "$THRU_CACHE")
assert_eq "vanilla cache holds wlan totals" "2000 1500 3500" "$cache_line"

write_proc_net_dev "$PROC_NET_DEV" \
    lo 100 100 \
    wlan0 6000 12000 \
    wlan1 8000 16500
result=$(probe_throughput 2010)
assert_eq "vanilla wlan delta -> 10 20" "10 20 proc-net-dev" "$result"

# --- only some interfaces present (vendor router missing apcli0) ---
rm -f "$THRU_CACHE"
write_proc_net_dev "$PROC_NET_DEV" \
    ra0 5000 6000 \
    apclix0 3000 4000
result=$(probe_throughput 3000)
assert_eq "subset of ifaces: first call -> 0 0" "0 0 proc-net-dev" "$result"
cache_line=$(cat "$THRU_CACHE")
assert_eq "subset cache sums present ifaces" "3000 8000 10000" "$cache_line"

# --- elapsed=0 guard: clock didn't advance, must not divide by zero ---
rm -f "$THRU_CACHE"
write_proc_net_dev "$PROC_NET_DEV" ra0 1000 2000
probe_throughput 4000 > /dev/null
write_proc_net_dev "$PROC_NET_DEV" ra0 2250 3500
result=$(probe_throughput 4000)
# Treated as 1s elapsed: (1250 * 8 / 1000) = 10, (1500 * 8 / 1000) = 12
assert_eq "elapsed=0 treated as 1s" "10 12 proc-net-dev" "$result"

# --- no interfaces in /proc/net/dev match → 0 0 (cache stores zeros) ---
rm -f "$THRU_CACHE"
write_proc_net_dev "$PROC_NET_DEV" \
    lo 100 100 \
    eth0 9999 9999
result=$(probe_throughput 5000)
assert_eq "no matching ifaces: first call -> 0 0" "0 0 proc-net-dev" "$result"
cache_line=$(cat "$THRU_CACHE")
assert_eq "no matching ifaces: cache zeros" "5000 0 0" "$cache_line"
result=$(probe_throughput 5010)
assert_eq "no matching ifaces: still 0 0" "0 0 proc-net-dev" "$result"

unset -f write_proc_net_dev

############################################################
section "probe_clients direction (mocked ubus + jsonfilter)"
############################################################

# gl-clients is client-centric (.rx = download, .tx = upload); data.json is
# router-centric (tx = download ↓, rx = upload ↑). probe_clients must cross-map.
# Feed one downloading client and assert the emitted totals/list are oriented
# so tx = download.
DHCP_LEASES="$SANDBOX/dhcp.leases"; : > "$DHCP_LEASES"
MOCK_CLIENT_MAC="AA:BB:CC:DD:EE:FF"

ubus() {
    case "$*" in
        *"gl-clients list"*)      echo '{"clients":{"present":1}}' ;;  # non-empty; parsed by mocked jsonfilter
        *"luci-rpc getHostHints"*) echo '{}' ;;
        *)                         echo "" ;;
    esac
}
# jsonfilter stand-in: return canned values keyed by the -e expression.
# gl .tx = 50000 B/s (upload), gl .rx = 1000000 B/s (download).
jsonfilter() {
    local expr=""
    while [ $# -gt 0 ]; do case "$1" in -e) shift; expr="$1" ;; esac; shift; done
    case "$expr" in
        '@.clients[*].mac') echo "$MOCK_CLIENT_MAC" ;;
        *.online)           echo "true" ;;
        *.ip)               echo "192.168.8.50" ;;
        *.iface)            echo "5G" ;;
        *.tx)               echo "50000" ;;
        *.rx)               echo "1000000" ;;
        *.name)             echo "TestLaptop" ;;
        *)                  cat >/dev/null 2>&1; echo "" ;;
    esac
}

result=$(probe_clients)
online=$(echo "$result" | awk '{print $1}')
total_tx=$(echo "$result" | awk '{print $2}')
total_rx=$(echo "$result" | awk '{print $3}')
# tx (download) = 1000000*8/1000 = 8000 ; rx (upload) = 50000*8/1000 = 400
assert_eq "clients: one online"                 "1"    "$online"
assert_eq "clients: download -> total_tx (↓)"   "8000" "$total_tx"
assert_eq "clients: upload -> total_rx (↑)"     "400"  "$total_rx"
client_list=$(cat "$CLIENTS_LIST_FILE" 2>/dev/null)
assert_contains "clients list: tx=download"     '"tx":8000' "$client_list"
assert_contains "clients list: rx=upload"       '"rx":400'  "$client_list"

unset -f ubus jsonfilter
unset MOCK_CLIENT_MAC

############################################################
section "publish_reboots (boot history + telemetry feed)"
############################################################

REBOOTS_OUT="$SANDBOX/reboots.json"
BOOT_LOG="$SANDBOX/boot.log"
SNAPSHOT_LOG="$SANDBOX/snapshot.log"
HEARTBEAT_FILE="$SANDBOX/hb.txt"

# 3 boots: FIRST_RUN (no gap), CLEAN (gap=6), ABRUPT (gap=240).
cat > "$BOOT_LOG" <<'BL'
==================== BOOT Mon Jun 16 ====================
ts=1000 uptime_now=50.12 verdict: FIRST_RUN (no previous heartbeat)
  unrelated forensic line
==================== BOOT Mon Jun 16 ====================
ts=2000 uptime_now=700.50 verdict: CLEAN (gap=6s — within heartbeat interval)
==================== BOOT Mon Jun 16 ====================
ts=3000 uptime_now=55.00 verdict: ABRUPT (gap=240s — exceeds 90s; system died without warning)
BL

# snapshot cols: 1ts 2uptime 3load 4mem_kb 5temp_milli 6rss 7taint 8nr 9wdt 10wifi ... 21proc
printf '%s\n' \
  '100 10 0.20 250000 45000 1200 1 2 0 111 0 0 0 0 0 0 0 0 44 256 90' \
  '105 15 0.30 248000 46000 1200 1 1 0 222 0 0 0 0 0 0 0 0 44 256 92' \
  > "$SNAPSHOT_LOG"

echo 'ts=3500 uptime=120.00 load=0.10 temp_milli=47000 wifi_irq=333 proc_count=95' > "$HEARTBEAT_FILE"

publish_reboots 9999
out=$(cat "$REBOOTS_OUT" 2>/dev/null)

assert_contains "feed: generated ts"        '"generated":9999'                "$out"
assert_contains "feed: FIRST_RUN boot"       '"verdict":"FIRST_RUN","gap":-1'  "$out"
assert_contains "feed: CLEAN boot gap=6"     '"verdict":"CLEAN","gap":6'       "$out"
assert_contains "feed: ABRUPT boot gap=240"  '"verdict":"ABRUPT","gap":240'    "$out"
boot_count=$(echo "$out" | grep -o '"verdict"' | wc -l | tr -d ' ')
assert_eq       "feed: lists all 3 boots"    "3"                               "$boot_count"
assert_contains "feed: temp_c converted"     '"temp_c":[45.0,46.0]'            "$out"
assert_contains "feed: mem_mb converted"     '"mem_mb":[244,242]'              "$out"
assert_contains "feed: current heartbeat"    '"wifi_irq":333'                  "$out"

############################################################
# Summary
############################################################
printf "\n========================================\n"
if [ $TESTS_FAILED -eq 0 ]; then
    printf "${GREEN}All %d tests passed.${NC}\n" "$TESTS_RUN"
    exit 0
else
    printf "${RED}%d / %d tests FAILED.${NC}\n" "$TESTS_FAILED" "$TESTS_RUN"
    exit 1
fi
