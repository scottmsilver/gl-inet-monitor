#!/bin/sh
# Dashboard data collector daemon.
#
# Architecture:
#   1. SCHEMA        — emit_data_json: single source of truth for the JSON
#                      shape. Every parameter has a default; called with no
#                      args, produces a valid "outage" document.
#   2. PROBES        — probe_* functions: each returns typed values. A failed
#                      probe returns its sentinel (0 / -1 / DEFAULT_UPLINK / "").
#   3. ORCHESTRATOR  — collect_data: reads each probe, calls the schema.
#
# Output is correct by construction. No post-hoc sanitizers or boundary
# validators are needed because nothing untyped ever reaches the schema.

# === CONFIG ===
INTERVAL=5
MAX_HISTORY=120  # 120 samples * 5s = 10 min of history
UPLINK_DETECT_INTERVAL=60
HINTS_CACHE_AGE=60

JSON_OUT="/www/data.json"
FETCH_LOG="/tmp/fetch_history.log"
PING_LOG="/tmp/ping_history.log"
THRU_LOG="/tmp/thru_history.log"
AVAIL_LOG="/tmp/avail_history.log"
CLIENTS_LOG="/tmp/clients_history.log"
IW_CACHE="/tmp/iw_stats_cache"
PID_FILE="/tmp/dash_daemon.pid"
LAST_SUCCESS_FILE="/tmp/last_success.txt"
UPLINK_CACHE="/tmp/uplink_cache.json"
DHCP_LEASES="/tmp/dhcp.leases"
LUCI_HINTS_CACHE="/tmp/luci_hints.cache"
CLIENTS_LIST_FILE="/tmp/clients_list_built.json"

UPLINK_SAMPLE_COUNT=0
LAST_SSID=""
LAST_EXTERNAL_IP=""
LAST_AVAIL_STATE=1
UPLINK_SSID=""
AVAIL=0

# === PERSISTENT DIAGNOSTIC LOGGING ===
# Lives on /overlay/upper (ubifs flash, survives reboot). Heartbeat lets us
# detect unclean reboots by checking the gap between last write and current
# boot time. Boot log preserves dmesg/pstore/last-snapshots for postmortem.
# Flash wear: ~1 write/minute on heartbeat + snapshot, well under UBIFS limits.
PERSIST_DIR="/overlay/upper/root"
HEARTBEAT_FILE="$PERSIST_DIR/dash_heartbeat.txt"
BOOT_LOG="$PERSIST_DIR/dash_boot.log"
SNAPSHOT_LOG="$PERSIST_DIR/dash_snapshot.log"
SHUTDOWN_LOG="$PERSIST_DIR/dash_shutdown.log"
SYSLOG_TAIL_LOG="$PERSIST_DIR/dash_syslog_tail.log"
SYSLOG_TAIL_PID="/tmp/dash_syslog_tail.pid"
PS_SNAPSHOT="$PERSIST_DIR/dash_ps_snapshot.log"
# Drop to 1 cycle = 5s heartbeats — tighter pre-death window. Flash impact
# stays modest because each write is tiny (<300 bytes) and we sync only once.
HEARTBEAT_INTERVAL_CYCLES=1
SNAPSHOT_MAX_LINES=4000         # ~5.5h at 1/5s
BOOT_LOG_MAX_BYTES=524288       # 512 KiB
SYSLOG_TAIL_MAX_BYTES=524288    # 512 KiB rolling
HEARTBEAT_COUNTER=0

DEFAULT_UPLINK='{"connection_type":"unknown","isp":"Unknown","thresholds":{"ping":{"good":30,"warn":80},"web":{"good":100,"warn":300}}}'

# === HELPERS ===

log() { echo "$(date '+%H:%M:%S') $1"; }

# record_history <value> <logfile> [<pattern>]
#   Append, rotate to MAX_HISTORY lines, echo CSV of matching values.
record_history() {
    local value="$1" logfile="$2" pattern="${3:-^-?[0-9]+$}"
    echo "$value" >> "$logfile"
    tail -n $MAX_HISTORY "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
    local csv=$(awk -v pat="$pattern" 'NF && $0 ~ pat {printf "%s%s", sep, $1; sep=","}' "$logfile")
    echo "${csv:-0}"
}

# json_escape <raw>
#   Emits inner contents of a JSON string (no surrounding quotes).
#   Strips control chars; escapes backslash and double-quote.
json_escape() {
    printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# === UPLINK CLASSIFICATION ===

get_external_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
    curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null
}

lookup_asn() {
    curl -s --max-time 5 "http://ip-api.com/json/$1?fields=status,isp,org,as,query" 2>/dev/null
}

classify_by_asn_number() {
    local asn=$(echo "$1" | grep -oE 'AS[0-9]+' | sed 's/AS//')
    [ -z "$asn" ] && return 1
    case "$asn" in
        14593) echo "starlink"; return 0 ;;
        21928|393960|18747|64294|50973|22351) echo "airplane"; return 0 ;;
        7155|16491|40306|40311|46536|1358|6621|63062|35228) echo "geo_satellite"; return 0 ;;
        15146|26415) echo "maritime"; return 0 ;;
    esac
    return 1
}

classify_connection() {
    local asn_info="$1"
    local as_field=$(echo "$asn_info" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)
    local result=$(classify_by_asn_number "$as_field")
    if [ -n "$result" ]; then echo "$result"; return; fi
    local up=$(echo "$asn_info" | tr '[:lower:]' '[:upper:]')
    if echo "$up" | grep -qE 'STARLINK|SPACEX'; then echo "starlink"; return; fi
    if echo "$up" | grep -qE 'GOGO|GO-GO|PANASONIC.*AVIONIC|INMARSAT|VIASAT.*AIRLINE|ANUVU|THALES|SMARTSKY|GLOBAL EAGLE'; then echo "airplane"; return; fi
    if echo "$up" | grep -qE 'VIASAT|HUGHESNET|ECHOSTAR|EUTELSAT|SES S\.A|TELESAT|SKYTERRA'; then echo "geo_satellite"; return; fi
    if echo "$up" | grep -qE 'MARITIME|MARLINK|KVH|SPEEDCAST'; then echo "maritime"; return; fi
    if echo "$up" | grep -qE 'T-MOBILE|VERIZON WIRELESS|AT&T MOBILITY|CELLULAR|LTE|5G'; then echo "cellular"; return; fi
    echo "landline"
}

get_thresholds() {
    # Format: ping_good ping_warn web_good web_warn
    case "$1" in
        starlink)                            echo "60 120 200 400" ;;
        airplane|geo_satellite|maritime)     echo "775 1100 2000 3500" ;;
        cellular)                            echo "80 150 250 500" ;;
        *)                                   echo "30 80 100 300" ;;
    esac
}

# detect_uplink — refreshes $UPLINK_CACHE on SSID change, IP change, or every
# UPLINK_DETECT_INTERVAL samples. Uses $UPLINK_SSID and $LAST_AVAIL_STATE.
detect_uplink() {
    local force_redetect=0
    if [ -n "$LAST_SSID" ] && [ "$UPLINK_SSID" != "$LAST_SSID" ]; then
        log "SSID changed ($LAST_SSID -> $UPLINK_SSID), re-detecting uplink..."
        force_redetect=1
    fi
    LAST_SSID="$UPLINK_SSID"

    if [ "$LAST_AVAIL_STATE" = "0" ] && [ "$AVAIL" = "1" ]; then
        log "Connection restored, re-detecting uplink..."
        force_redetect=1
    fi

    if [ $force_redetect -eq 0 ] && [ -f "$UPLINK_CACHE" ] && [ $UPLINK_SAMPLE_COUNT -lt $UPLINK_DETECT_INTERVAL ]; then
        UPLINK_SAMPLE_COUNT=$((UPLINK_SAMPLE_COUNT + 1))
        return 0
    fi

    log "Detecting uplink type..."
    UPLINK_SAMPLE_COUNT=0

    local ext_ip=$(get_external_ip)
    if [ -n "$LAST_EXTERNAL_IP" ] && [ -n "$ext_ip" ] && [ "$ext_ip" != "$LAST_EXTERNAL_IP" ]; then
        log "External IP changed ($LAST_EXTERNAL_IP -> $ext_ip)"
    fi
    [ -n "$ext_ip" ] && LAST_EXTERNAL_IP="$ext_ip"
    if [ -z "$ext_ip" ]; then
        log "Could not get external IP, using defaults"
        echo "$DEFAULT_UPLINK" > "$UPLINK_CACHE"
        return 1
    fi

    local asn_info=$(lookup_asn "$ext_ip")
    if [ -z "$asn_info" ]; then
        log "Could not lookup ASN, using defaults"
        echo "$DEFAULT_UPLINK" > "$UPLINK_CACHE"
        return 1
    fi

    local conn_type=$(classify_connection "$asn_info")
    local thresholds=$(get_thresholds "$conn_type")
    local pg=$(echo "$thresholds" | cut -d' ' -f1)
    local pw=$(echo "$thresholds" | cut -d' ' -f2)
    local wg=$(echo "$thresholds" | cut -d' ' -f3)
    local ww=$(echo "$thresholds" | cut -d' ' -f4)

    local isp=$(echo "$asn_info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
    local isp_esc=$(json_escape "${isp:-Unknown}")

    cat > "$UPLINK_CACHE" << CACHE
{"connection_type":"$conn_type","isp":"$isp_esc","thresholds":{"ping":{"good":$pg,"warn":$pw},"web":{"good":$wg,"warn":$ww}}}
CACHE

    log "Uplink detected: $conn_type ($isp)"
    return 0
}

# === SCHEMA ===
#
# Single source of truth for data.json. Every parameter has a default;
# emit_data_json with no args yields a valid "outage" document.
emit_data_json() {
    local ts="${1:-0}"
    local uplink_ssid_esc="${2:---}"
    local uplink_obj="${3:-$DEFAULT_UPLINK}"
    local web_code="${4:-0}"
    local web_ms="${5:--1}"
    local web_hist="${6:--1}"
    local ping_ms="${7:--1}"
    local ping_hist="${8:--1}"
    local rx_kbps="${9:-0}"
    local tx_kbps="${10:-0}"
    local rx_peak="${11:-0}"
    local tx_peak="${12:-0}"
    local rx_hist="${13:-0}"
    local tx_hist="${14:-0}"
    local avail="${15:-0}"
    local last_success="${16:-0}"
    local avail_hist="${17:-0}"
    local clients_online="${18:-0}"
    local clients_tx="${19:-0}"
    local clients_rx="${20:-0}"
    local clients_hist="${21:-0}"
    local clients_list="${22:-}"
    cat << EOF
{
  "ts": $ts,
  "interval": $INTERVAL,
  "uplink_ssid": "$uplink_ssid_esc",
  "uplink": $uplink_obj,
  "web": {"code": $web_code, "ms": $web_ms, "history": [$web_hist]},
  "ping": {"current": $ping_ms, "history": [$ping_hist]},
  "throughput": {
    "rx_kbps": $rx_kbps, "tx_kbps": $tx_kbps,
    "rx_peak": $rx_peak, "tx_peak": $tx_peak,
    "rx_history": [$rx_hist], "tx_history": [$tx_hist],
    "source": "iw-station"
  },
  "avail": {"current": $avail, "last_success": $last_success, "history": [$avail_hist]},
  "clients": {"online": $clients_online, "total_tx": $clients_tx, "total_rx": $clients_rx, "history": [$clients_hist], "list": [$clients_list]}
}
EOF
}

# === PROBES ===
# Each probe returns typed values via stdout. A failed probe returns its
# sentinel — never raw shell-out output. Probes are independently testable.

# probe_uplink_ssid -> JSON-escaped SSID string ("Not connected" sentinel)
probe_uplink_ssid() {
    local ssid
    ssid=$(timeout 3 iwinfo sta0 info 2>/dev/null | awk -F'ESSID: ' '/ESSID:/{gsub(/"/, "", $2); print $2}')
    [ -z "$ssid" ] || [ "$ssid" = "unknown" ] && \
        ssid=$(timeout 3 iwinfo sta1 info 2>/dev/null | awk -F'ESSID: ' '/ESSID:/{gsub(/"/, "", $2); print $2}')
    [ -z "$ssid" ] || [ "$ssid" = "unknown" ] && ssid=$(uci get wireless.sta.ssid 2>/dev/null)
    [ -z "$ssid" ] || [ "$ssid" = "unknown" ] && ssid="Not connected"
    json_escape "$ssid"
}

# probe_uplink_json -> JSON object ($DEFAULT_UPLINK sentinel)
probe_uplink_json() {
    local raw=$(cat "$UPLINK_CACHE" 2>/dev/null)
    if [ -n "$raw" ] && echo "$raw" | jsonfilter -e '@.connection_type' >/dev/null 2>&1; then
        echo "$raw"
    else
        echo "$DEFAULT_UPLINK"
    fi
}

# probe_web <now> -> "code ms" (ints; sentinels: 0, -1)
probe_web() {
    local now="$1" up1 up2 code ms
    read up1 _ < /proc/uptime
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 --connect-timeout 3 \
        -H "Cache-Control: no-cache" "http://www.google.com/generate_204?$now" 2>/dev/null)
    read up2 _ < /proc/uptime
    case "$code" in
        ''|*[!0-9]*) code=0 ;;
        *) code=$(printf '%d' "$code") ;;  # strips leading zeros from "000"
    esac
    if [ "$code" = "204" ]; then
        ms=$(awk "BEGIN {printf \"%.0f\", ($up2 - $up1) * 1000}")
    else
        ms=-1
    fi
    echo "$code $ms"
}

# probe_ping -> ms (float >= 0, or -1 sentinel)
# Ping the same host the web check uses — some networks (airline wifi,
# captive portals) drop pings to 8.8.8.8/1.1.1.1 but allow traffic on the
# path web actually uses.
probe_ping() {
    local raw=$(ping -c 1 -W 2 www.google.com 2>/dev/null | grep -oE 'time=[0-9.]+' | cut -d= -f2)
    awk -v v="$raw" 'BEGIN { if (v ~ /^[0-9]+(\.[0-9]+)?$/) print v; else print -1 }'
}

# probe_throughput <now> -> "rx_kbps tx_kbps" (ints; sentinels 0).
# Side effect: refreshes $IW_CACHE for the next call's delta computation.
probe_throughput() {
    local now="$1" tmp_file=/tmp/iw_stats_current prev_time elapsed data rx tx

    for iface in wlan0 wlan1; do
        timeout 3 iw dev $iface station dump 2>/dev/null | awk '
            /Station/ { mac=$2 }
            /rx bytes:/ { rx=$3 }
            /tx bytes:/ { if(mac && rx) print mac, rx, $3 }
        '
    done > "$tmp_file"

    if [ -f "$IW_CACHE.time" ]; then
        read prev_time < "$IW_CACHE.time"
    else
        prev_time=$now
    fi
    elapsed=$((now - prev_time))
    [ $elapsed -lt 1 ] && elapsed=1

    data=$(awk -v cachefile="$IW_CACHE" -v elapsed="$elapsed" '
    BEGIN {
        while((getline line < cachefile) > 0) {
            split(line, f, " ")
            if(f[1]) { prev_rx[f[1]] = f[2]; prev_tx[f[1]] = f[3] }
        }
        close(cachefile)
        total_up = 0; total_down = 0
    }
    {
        mac = $1; rx = $2; tx = $3
        if(mac in prev_rx) {
            d_up = int((rx - prev_rx[mac]) * 8 / elapsed / 1000)
            d_down = int((tx - prev_tx[mac]) * 8 / elapsed / 1000)
            if(d_up < 0) d_up = 0
            if(d_down < 0) d_down = 0
        } else { d_up = 0; d_down = 0 }
        total_up += d_up; total_down += d_down
    }
    END { print total_up, total_down }
    ' "$tmp_file")

    cp "$tmp_file" "$IW_CACHE"
    echo "$now" > "$IW_CACHE.time"

    read rx tx <<EOF
$data
EOF
    case "$rx" in ''|*[!0-9]*) rx=0 ;; *) rx=$(printf '%d' "$rx") ;; esac
    case "$tx" in ''|*[!0-9]*) tx=0 ;; *) tx=$(printf '%d' "$tx") ;; esac
    echo "$rx $tx"
}

# probe_clients -> "online total_tx total_rx" (ints).
# Side effect: writes the JSON client-list (inner contents, no brackets)
# to $CLIENTS_LIST_FILE. Empty file is valid (means no clients).
probe_clients() {
    local hints_age=9999
    if [ -f "$LUCI_HINTS_CACHE" ]; then
        local cache_mtime=$(stat -c %Y "$LUCI_HINTS_CACHE" 2>/dev/null || stat -f %m "$LUCI_HINTS_CACHE" 2>/dev/null || echo 0)
        hints_age=$(($(date +%s) - cache_mtime))
    fi
    if [ $hints_age -gt $HINTS_CACHE_AGE ]; then
        ubus -t 3 call luci-rpc getHostHints '{}' > "$LUCI_HINTS_CACHE" 2>/dev/null
    fi

    local clients_raw=$(ubus -t 3 call gl-clients list '{}' 2>/dev/null)
    [ -z "$clients_raw" ] && clients_raw='{"clients":{}}'

    local macs=$(echo "$clients_raw" | jsonfilter -e '@.clients[*].mac' 2>/dev/null)

    local online=0 total_tx=0 total_rx=0 list_json="" first=1

    for mac in $macs; do
        local is_online=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].online" 2>/dev/null)
        [ "$is_online" != "true" ] && continue

        local ip=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].ip" 2>/dev/null)
        local iface=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].iface" 2>/dev/null)
        local tx=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].tx" 2>/dev/null)
        local rx=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].rx" 2>/dev/null)
        local gl_name=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].name" 2>/dev/null)

        tx=$((${tx:-0} * 8 / 1000))
        rx=$((${rx:-0} * 8 / 1000))

        local name=""
        [ -n "$gl_name" ] && name="$gl_name"
        if [ -z "$name" ] && [ -f "$DHCP_LEASES" ]; then
            local mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
            name=$(awk -v m="$mac_lower" 'tolower($2)==m && $4!="*" {print $4}' "$DHCP_LEASES")
        fi
        if [ -z "$name" ]; then
            local first_byte=$(echo "$mac" | cut -d: -f1)
            local dec=$(printf "%d" "0x$first_byte" 2>/dev/null || echo 0)
            [ $((dec & 2)) -ne 0 ] && name="Private Device"
        fi
        [ -z "$name" ] && name=$(echo "$mac" | cut -d: -f1-3)

        local name_esc=$(json_escape "$name")
        local mac_esc=$(json_escape "$mac")
        local ip_esc=$(json_escape "$ip")
        local iface_esc=$(json_escape "$iface")

        online=$((online + 1))
        total_tx=$((total_tx + tx))
        total_rx=$((total_rx + rx))

        [ $first -eq 0 ] && list_json="${list_json},"
        first=0
        list_json="${list_json}{\"mac\":\"$mac_esc\",\"name\":\"$name_esc\",\"ip\":\"$ip_esc\",\"iface\":\"$iface_esc\",\"tx\":$tx,\"rx\":$rx}"
    done

    printf '%s' "$list_json" > "$CLIENTS_LIST_FILE"
    echo "$online $total_tx $total_rx"
}

# === PERSISTENT-LOG HELPERS ===

# read_system_state -> "uptime load mem_avail_kb temp_milli daemon_rss_kb"
# All numeric, single space-separated line. Sentinel "0" for any unavailable.
read_system_state() {
    local up=$(awk '{print $1}' /proc/uptime 2>/dev/null)
    local load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    local mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
    local temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    local rss=$(awk '/VmRSS/{print $2}' /proc/$$/status 2>/dev/null)
    echo "${up:-0} ${load:-0} ${mem:-0} ${temp:-0} ${rss:-0}"
}

# read_hw_state -> "taint nr_running wdt_bark wifi_irq pwmfan_irq err_irq eth0_rx_err eth0_tx_err eth0_crc_err eth1_rx_err eth1_tx_err eth1_crc_err ubi_max_ec entropy"
# Hardware telemetry sampled at heartbeat cadence. Absolute counters so we
# can compute deltas across boots. Anomalies to watch for:
#   * taint changes from baseline (4096 = expected OOT module) — new bit = new problem
#   * wdt_bark > 0   — kernel watchdog growled (system was about to be reset)
#   * eth_*_err climbing — link-layer issues
#   * entropy < 256  — RNG starvation can hang TLS / boot
#   * load_running spike — runaway userspace
# All values default to "0" if unavailable so the line stays parse-able.
read_hw_state() {
    local taint=$(cat /proc/sys/kernel/tainted 2>/dev/null)
    local nr_running=$(awk '{print $4}' /proc/loadavg 2>/dev/null | cut -d/ -f1)
    local entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)
    # IRQ counts: sum across both CPUs. Pattern-match the IRQ source name.
    local wdt_bark=$(awk '/wdt_bark/{print $2+$3}' /proc/interrupts 2>/dev/null)
    local wifi_irq=$(awk '/mt7915e/{print $2+$3}' /proc/interrupts 2>/dev/null)
    local pwmfan_irq=$(awk '/pwm-fan/{print $2+$3}' /proc/interrupts 2>/dev/null)
    local err_irq=$(awk '/^Err:/{print $2+$3}' /proc/interrupts 2>/dev/null)
    # Ethernet counters
    local e0r=$(cat /sys/class/net/eth0/statistics/rx_errors 2>/dev/null)
    local e0t=$(cat /sys/class/net/eth0/statistics/tx_errors 2>/dev/null)
    local e0c=$(cat /sys/class/net/eth0/statistics/rx_crc_errors 2>/dev/null)
    local e1r=$(cat /sys/class/net/eth1/statistics/rx_errors 2>/dev/null)
    local e1t=$(cat /sys/class/net/eth1/statistics/tx_errors 2>/dev/null)
    local e1c=$(cat /sys/class/net/eth1/statistics/rx_crc_errors 2>/dev/null)
    # Flash wear
    local ec=$(cat /sys/class/ubi/ubi0/max_ec 2>/dev/null)
    echo "${taint:-0} ${nr_running:-0} ${wdt_bark:-0} ${wifi_irq:-0} ${pwmfan_irq:-0} ${err_irq:-0} ${e0r:-0} ${e0t:-0} ${e0c:-0} ${e1r:-0} ${e1t:-0} ${e1c:-0} ${ec:-0} ${entropy:-0}"
}

# heartbeat_gap_seconds <now> -> seconds since last heartbeat (or -1 if none)
heartbeat_gap_seconds() {
    local now=$1
    local last=$(awk -F'[ =]' '/^ts=/{print $2; exit}' "$HEARTBEAT_FILE" 2>/dev/null)
    case "$last" in
        ''|*[!0-9]*) echo -1 ;;
        *) echo $((now - last)) ;;
    esac
}

# record_heartbeat <now>
#   Updates the single-line heartbeat file every $HEARTBEAT_INTERVAL_CYCLES
#   calls. Also appends a snapshot to the rolling snapshot log.
record_heartbeat() {
    local now=$1
    HEARTBEAT_COUNTER=$((HEARTBEAT_COUNTER + 1))
    [ $((HEARTBEAT_COUNTER % HEARTBEAT_INTERVAL_CYCLES)) -ne 0 ] && return

    local state=$(read_system_state)
    local up load mem temp rss
    read up load mem temp rss <<EOF
$state
EOF
    local hw=$(read_hw_state)
    local taint nr_run wdt_bark wifi_irq pwmfan_irq err_irq e0r e0t e0c e1r e1t e1c ec entropy
    read taint nr_run wdt_bark wifi_irq pwmfan_irq err_irq e0r e0t e0c e1r e1t e1c ec entropy <<EOF
$hw
EOF

    # ps audit: process count. A spike or a known-bad name suggests something
    # rogue. Recorded as a single integer in the snapshot line for cheap diff.
    local proc_count=$(ps 2>/dev/null | wc -l)

    {
        printf 'ts=%d uptime=%s load=%s mem_avail_kb=%s temp_milli=%s rss_kb=%s ' \
            "$now" "$up" "$load" "$mem" "$temp" "$rss"
        printf 'taint=%s nr_running=%s wdt_bark=%s wifi_irq=%s pwmfan_irq=%s err_irq=%s ' \
            "$taint" "$nr_run" "$wdt_bark" "$wifi_irq" "$pwmfan_irq" "$err_irq"
        printf 'eth0_rx_err=%s eth0_tx_err=%s eth0_crc_err=%s ' \
            "$e0r" "$e0t" "$e0c"
        printf 'eth1_rx_err=%s eth1_tx_err=%s eth1_crc_err=%s ' \
            "$e1r" "$e1t" "$e1c"
        printf 'ubi_max_ec=%s entropy=%s proc_count=%s\n' "$ec" "$entropy" "$proc_count"
    } > "$HEARTBEAT_FILE.tmp" && mv "$HEARTBEAT_FILE.tmp" "$HEARTBEAT_FILE"

    # Snapshot log: 21 positional fields (matches read_hw_state order + proc_count).
    printf '%d %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
        "$now" "$up" "$load" "$mem" "$temp" "$rss" \
        "$taint" "$nr_run" "$wdt_bark" "$wifi_irq" "$pwmfan_irq" "$err_irq" \
        "$e0r" "$e0t" "$e0c" "$e1r" "$e1t" "$e1c" "$ec" "$entropy" "$proc_count" >> "$SNAPSHOT_LOG"

    # `sync` forces page cache to flash. Without this, the last few seconds
    # of writes are lost when an SoC reset hits — we'd see a stale heartbeat
    # in the next boot record instead of the true last-known-good moment.
    sync

    # Rotate snapshot log periodically.
    if [ $((HEARTBEAT_COUNTER % 240)) -eq 0 ]; then
        tail -n $SNAPSHOT_MAX_LINES "$SNAPSHOT_LOG" > "${SNAPSHOT_LOG}.tmp" \
            && mv "${SNAPSHOT_LOG}.tmp" "$SNAPSHOT_LOG"
    fi
}

# record_shutdown <signal>
#   Called from the SIGTERM/SIGINT trap. Writes to a persistent log BEFORE
#   exiting. If the next boot's BOOT record shows a SHUTDOWN entry close to
#   the gap, the reboot was userspace-initiated (orderly). If not, it was
#   abrupt (hardware reset / SoC wedge).
record_shutdown() {
    local sig="$1"
    local now=$(date +%s)
    local up=$(awk '{print $1}' /proc/uptime 2>/dev/null)
    {
        printf 'ts=%d signal=%s uptime=%s\n' "$now" "$sig" "$up"
    } >> "$SHUTDOWN_LOG" 2>/dev/null
    sync 2>/dev/null
    log "SHUTDOWN signal=$sig at ts=$now uptime=${up}s — logged to flash"
}

# start_syslog_tail
#   Background: tail logread -f to a persistent file. Captures the last
#   moments of kernel + procd + service logs before death. We can't get this
#   from /var/log on reboot (it's RAM). Rate-limit via periodic rotation.
start_syslog_tail() {
    # Don't start if one's already running
    if [ -f "$SYSLOG_TAIL_PID" ]; then
        local old_pid=$(cat "$SYSLOG_TAIL_PID")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            return 0
        fi
    fi
    # Background tail; write to persistent log; cap size by rotation in
    # heartbeat path (avoids needing the tail process to do it).
    ( logread -f >> "$SYSLOG_TAIL_LOG" 2>/dev/null ) &
    echo $! > "$SYSLOG_TAIL_PID"
    log "syslog tail started (pid $(cat $SYSLOG_TAIL_PID)) -> $SYSLOG_TAIL_LOG"
}

# Rotate the syslog tail log if it exceeds cap. Called from collect_data
# at the same low cadence we rotate snapshots.
rotate_syslog_tail() {
    local size=$(wc -c < "$SYSLOG_TAIL_LOG" 2>/dev/null)
    if [ "${size:-0}" -gt "$SYSLOG_TAIL_MAX_BYTES" ] 2>/dev/null; then
        tail -c "$SYSLOG_TAIL_MAX_BYTES" "$SYSLOG_TAIL_LOG" > "${SYSLOG_TAIL_LOG}.tmp" \
            && mv "${SYSLOG_TAIL_LOG}.tmp" "$SYSLOG_TAIL_LOG"
    fi
}

# record_boot
#   Called once at daemon startup. Appends a forensic record to BOOT_LOG with:
#     - Gap from last heartbeat (large gap = unclean / abrupt reboot)
#     - dmesg head (kernel boot messages — might mention reset reason)
#     - pstore dumps (kernel panic / oops survives reboot here, if any)
#     - Last 10 snapshots before the boot (system state right before death)
record_boot() {
    mkdir -p "$PERSIST_DIR"
    local now=$(date +%s)
    local gap=$(heartbeat_gap_seconds "$now")
    local verdict="UNKNOWN"
    if [ "$gap" -lt 0 ] 2>/dev/null; then
        verdict="FIRST_RUN (no previous heartbeat)"
    elif [ "$gap" -le 90 ]; then
        verdict="CLEAN (gap=${gap}s — within heartbeat interval)"
    else
        verdict="ABRUPT (gap=${gap}s — exceeds 90s; system died without warning)"
    fi

    {
        echo
        echo "==================== BOOT $(date) ===================="
        echo "ts=$now uptime_now=$(awk '{print $1}' /proc/uptime) verdict: $verdict"
        if [ "$gap" -ge 0 ] 2>/dev/null; then
            echo "last heartbeat raw:"
            cat "$HEARTBEAT_FILE" 2>/dev/null | sed 's/^/  /'
        fi
        echo "--- last 10 snapshots before boot ---"
        tail -n 10 "$SNAPSHOT_LOG" 2>/dev/null | sed 's/^/  /'
        echo "--- shutdown log (presence of recent SHUTDOWN entry = orderly reboot) ---"
        # If the gap to most-recent SHUTDOWN entry is small, the daemon got
        # SIGTERM before death (orderly). If the latest entry is much older
        # than the gap, this was an abrupt reset.
        tail -n 5 "$SHUTDOWN_LOG" 2>/dev/null | sed 's/^/  /'
        echo "--- last 50 lines of system logread (captured continuously to flash) ---"
        tail -n 50 "$SYSLOG_TAIL_LOG" 2>/dev/null | sed 's/^/  /'
        echo "--- pstore (kernel oops/panic if any) ---"
        ls /sys/fs/pstore/ 2>/dev/null | sed 's/^/  /'
        for f in /sys/fs/pstore/*; do
            [ -e "$f" ] && echo "--- $f (first 30 lines) ---" && head -30 "$f" 2>/dev/null | sed 's/^/  /'
        done
        echo "--- hardware state at boot ---"
        # Taint baseline + full /proc/interrupts + softirqs + reg state +
        # gpio-keys count (button-pressed reboot would show here) + flash
        # health. All cheap, single-snapshot — these change rarely so a per-boot
        # capture is enough; the heartbeat tracks the deltas in between.
        echo "  taint=$(cat /proc/sys/kernel/tainted 2>/dev/null)  (4096=OOT-only is baseline; anything else = NEW)"
        echo "  /proc/interrupts:"
        cat /proc/interrupts 2>/dev/null | sed 's/^/    /'
        echo "  /proc/softirqs (top):"
        head -8 /proc/softirqs 2>/dev/null | sed 's/^/    /'
        echo "  regulators:"
        for r in /sys/class/regulator/regulator.*; do
            [ -e "$r/name" ] && printf "    %s state=%s microvolts=%s\n" \
                "$(cat $r/name)" "$(cat $r/state 2>/dev/null)" "$(cat $r/microvolts 2>/dev/null)"
        done
        echo "  flash health: max_ec=$(cat /sys/class/ubi/ubi0/max_ec 2>/dev/null) bad_peb=$(cat /sys/class/ubi/ubi0/bad_peb_count 2>/dev/null)"
        echo "  entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)"
        echo "  watchdog: bootstatus=$(cat /sys/class/watchdog/watchdog0/bootstatus 2>/dev/null) timeout=$(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null)"
        echo "--- dmesg first 50 lines ---"
        dmesg 2>/dev/null | head -50 | sed 's/^/  /'
        echo "--- dmesg: ANY mention of reset/reboot/panic/oops ---"
        dmesg 2>/dev/null | grep -iE "reset|reboot|panic|oops|fault|warning|error" | head -20 | sed 's/^/  /'
    } >> "$BOOT_LOG"

    # Cap boot log size (head -c keeps newest by rewriting from the tail).
    local size=$(wc -c < "$BOOT_LOG" 2>/dev/null)
    if [ "${size:-0}" -gt "$BOOT_LOG_MAX_BYTES" ] 2>/dev/null; then
        tail -c "$BOOT_LOG_MAX_BYTES" "$BOOT_LOG" > "${BOOT_LOG}.tmp" \
            && mv "${BOOT_LOG}.tmp" "$BOOT_LOG"
    fi

    # Make sure the boot record itself survives a fast follow-up reboot.
    sync

    log "boot recorded: $verdict"
}

# compute_avail <web_code> <web_ms> <ping_ms> -> 0 or 1
compute_avail() {
    if [ "$1" = "204" ] && [ "${2:-0}" -gt 0 ] 2>/dev/null && [ "$3" != "-1" ]; then
        echo 1
    else
        echo 0
    fi
}

# === ORCHESTRATOR ===

collect_data() {
    local now=$(date +%s)

    UPLINK_SSID=$(probe_uplink_ssid)
    detect_uplink
    local uplink_obj=$(probe_uplink_json)

    local web_code web_ms
    read web_code web_ms <<EOF
$(probe_web "$now")
EOF

    local ping_ms=$(probe_ping)

    local rx_kbps tx_kbps
    read rx_kbps tx_kbps <<EOF
$(probe_throughput "$now")
EOF

    local clients_online clients_tx clients_rx
    read clients_online clients_tx clients_rx <<EOF
$(probe_clients)
EOF
    local clients_list=$(cat "$CLIENTS_LIST_FILE" 2>/dev/null)

    AVAIL=$(compute_avail "$web_code" "$web_ms" "$ping_ms")
    [ "$AVAIL" = "1" ] && echo "$now" > "$LAST_SUCCESS_FILE"
    local last_success
    read last_success < "$LAST_SUCCESS_FILE" 2>/dev/null || last_success=0

    # Histories
    local web_hist=$(record_history "$web_ms" "$FETCH_LOG")
    local ping_int
    if [ "$ping_ms" = "-1" ]; then ping_int=-1
    else ping_int=$(printf '%.0f' "$ping_ms"); fi
    local ping_hist=$(record_history "$ping_int" "$PING_LOG")
    local avail_hist=$(record_history "$AVAIL" "$AVAIL_LOG" "^[01]$")
    local clients_hist=$(record_history "$clients_online" "$CLIENTS_LOG" "^[0-9]+$")

    # Throughput history is a paired log: "tx_kbps,rx_kbps" per line
    echo "${tx_kbps},${rx_kbps}" >> "$THRU_LOG"
    tail -n $MAX_HISTORY "$THRU_LOG" > "${THRU_LOG}.tmp" && mv "${THRU_LOG}.tmp" "$THRU_LOG"
    local tx_hist=$(awk -F',' 'NF==2 && $1 ~ /^[0-9]+$/ {printf "%s%s", sep, $1; sep=","}' "$THRU_LOG")
    local rx_hist=$(awk -F',' 'NF==2 && $2 ~ /^[0-9]+$/ {printf "%s%s", sep, $2; sep=","}' "$THRU_LOG")
    [ -z "$tx_hist" ] && tx_hist="0"
    [ -z "$rx_hist" ] && rx_hist="0"
    local tx_peak=$(awk -F',' 'NF==2 && $1 ~ /^[0-9]+$/ {if($1>max)max=$1} END{print max+0}' "$THRU_LOG")
    local rx_peak=$(awk -F',' 'NF==2 && $2 ~ /^[0-9]+$/ {if($2>max)max=$2} END{print max+0}' "$THRU_LOG")

    # Emit via the schema, atomically publish.
    emit_data_json "$now" "$UPLINK_SSID" "$uplink_obj" \
        "$web_code" "$web_ms" "$web_hist" \
        "$ping_ms" "$ping_hist" \
        "$rx_kbps" "$tx_kbps" "$rx_peak" "$tx_peak" "$rx_hist" "$tx_hist" \
        "$AVAIL" "$last_success" "$avail_hist" \
        "$clients_online" "$clients_tx" "$clients_rx" "$clients_hist" "$clients_list" \
        > "${JSON_OUT}.tmp"
    mv "${JSON_OUT}.tmp" "$JSON_OUT"

    log "Web:${web_ms}ms Ping:${ping_ms}ms DL:${tx_kbps}K UL:${rx_kbps}K Clients:${clients_online}"
    LAST_AVAIL_STATE=$AVAIL

    # Persistent heartbeat (rate-limited inside the function)
    record_heartbeat "$now"

    # Rotate the syslog-tail log occasionally
    if [ $((HEARTBEAT_COUNTER % 240)) -eq 1 ]; then
        rotate_syslog_tail
    fi
}

# === INIT & MAIN LOOP ===
# Tests can `DASH_DAEMON_TEST=1 . dash_daemon.sh` to load functions without
# running init or the main loop.
if [ -z "$DASH_DAEMON_TEST" ]; then

echo $$ > "$PID_FILE"
for f in "$FETCH_LOG" "$PING_LOG" "$THRU_LOG" "$AVAIL_LOG" "$CLIENTS_LOG"; do
    [ -f "$f" ] || touch "$f"
done
[ -f "$LAST_SUCCESS_FILE" ] || echo "0" > "$LAST_SUCCESS_FILE"

# Initial outage doc so the dashboard never sees a 404 before cycle 1.
[ ! -s "$JSON_OUT" ] && emit_data_json > "$JSON_OUT"

# SIGTERM/SIGINT trap: log to persistent flash BEFORE exit. If we see a
# SHUTDOWN entry close to the next boot's heartbeat gap, the reboot was
# orderly (userspace asked for it). Missing entry = abrupt SoC reset.
shutdown_handler() {
    local sig="$1"
    record_shutdown "$sig"
    # Stop background syslog tail cleanly
    if [ -f "$SYSLOG_TAIL_PID" ]; then
        kill "$(cat "$SYSLOG_TAIL_PID")" 2>/dev/null
        rm -f "$SYSLOG_TAIL_PID"
    fi
    rm -f "$PID_FILE"
    exit 0
}
trap 'shutdown_handler TERM' TERM
trap 'shutdown_handler INT'  INT
trap 'shutdown_handler HUP'  HUP

# Start the continuous syslog tail BEFORE recording boot so we don't miss
# events during the boot-record write itself.
start_syslog_tail

# Record this boot with forensic snapshot (gap analysis, dmesg, pstore, last
# snapshots, recent shutdowns, syslog tail) BEFORE the heartbeat gets
# overwritten by the first cycle.
record_boot

log "Dashboard daemon starting (interval: ${INTERVAL}s, history: ${MAX_HISTORY} samples)"

while true; do
    collect_data
    sleep $INTERVAL
done

fi
