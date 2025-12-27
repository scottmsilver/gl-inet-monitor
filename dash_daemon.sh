#!/bin/sh
# Dashboard data collector daemon - runs every 5 seconds
# Stores data in /tmp (RAM) with rolling history

INTERVAL=5
MAX_HISTORY=120  # 120 samples * 5 sec = 10 minutes of history
JSON_OUT="/www/data.json"
FETCH_LOG="/tmp/fetch_history.log"
PING_LOG="/tmp/ping_history.log"
THRU_LOG="/tmp/thru_history.log"
IW_CACHE="/tmp/iw_stats_cache"
PID_FILE="/tmp/dash_daemon.pid"
AVAIL_LOG="/tmp/avail_history.log"
LAST_SUCCESS_FILE="/tmp/last_success.txt"

# Write PID file
echo $$ > "$PID_FILE"

# Initialize logs
[ -f "$FETCH_LOG" ] || touch "$FETCH_LOG"
[ -f "$PING_LOG" ] || touch "$PING_LOG"
[ -f "$THRU_LOG" ] || touch "$THRU_LOG"
[ -f "$AVAIL_LOG" ] || touch "$AVAIL_LOG"
[ -f "$LAST_SUCCESS_FILE" ] || echo "0" > "$LAST_SUCCESS_FILE"

log() {
    echo "$(date '+%H:%M:%S') $1"
}

get_uplink_ssid() {
    # Try sta0/sta1 first (repeater uplink interfaces)
    SSID=$(iwinfo sta0 info 2>/dev/null | grep -i 'ESSID:' | sed 's/.*ESSID: "\([^"]*\)".*/\1/')
    [ -z "$SSID" ] && SSID=$(iwinfo sta1 info 2>/dev/null | grep -i 'ESSID:' | sed 's/.*ESSID: "\([^"]*\)".*/\1/')
    # Fallback to UCI config
    [ -z "$SSID" ] && SSID=$(uci get wireless.sta.ssid 2>/dev/null)
    [ -z "$SSID" ] && SSID="Unknown Network"
    echo "$SSID"
}

collect_data() {
    NOW=$(date +%s)

    # --- Web Verify ---
    read UP1 _ < /proc/uptime
    WEB_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 --connect-timeout 3 \
        -H "Cache-Control: no-cache" "http://www.google.com/generate_204?$NOW" 2>/dev/null)
    read UP2 _ < /proc/uptime
    if [ "$WEB_CODE" = "204" ]; then
        WEB_MS=$(awk "BEGIN {printf \"%.0f\", ($UP2 - $UP1) * 1000}")
    else
        WEB_MS=-1
    fi

    echo "$WEB_MS" >> "$FETCH_LOG"
    tail -n $MAX_HISTORY "$FETCH_LOG" > "${FETCH_LOG}.tmp" && mv "${FETCH_LOG}.tmp" "$FETCH_LOG"
    FETCH_HIST=$(awk 'NF && /^-?[0-9]+$/ {printf "%s%s", sep, $1; sep=","}' "$FETCH_LOG")
    [ -z "$FETCH_HIST" ] && FETCH_HIST="0"

    # --- Ping latency ---
    PING_MS=$(ping -c 1 -W 2 8.8.8.8 2>/dev/null | grep -oE 'time=[0-9.]+' | cut -d= -f2)
    [ -z "$PING_MS" ] && PING_MS=-1

    # Store ping history (convert to int, -1 for failure)
    if [ "$PING_MS" = "-1" ]; then
        echo "-1" >> "$PING_LOG"
    else
        printf "%.0f\n" "$PING_MS" >> "$PING_LOG"
    fi
    tail -n $MAX_HISTORY "$PING_LOG" > "${PING_LOG}.tmp" && mv "${PING_LOG}.tmp" "$PING_LOG"
    PING_HIST=$(awk 'NF && /^-?[0-9]+$/ {printf "%s%s", sep, $1; sep=","}' "$PING_LOG")
    [ -z "$PING_HIST" ] && PING_HIST="0"

    # --- Throughput from iw ---
    TMP_FILE="/tmp/iw_stats_current"

    for iface in wlan0 wlan1; do
        iw dev $iface station dump 2>/dev/null | awk '
            /Station/ { mac=$2 }
            /rx bytes:/ { rx=$3 }
            /tx bytes:/ { if(mac && rx) print mac, rx, $3 }
        '
    done > "$TMP_FILE"

    if [ -f "$IW_CACHE.time" ]; then
        read PREV_TIME < "$IW_CACHE.time"
    else
        PREV_TIME=$NOW
    fi
    ELAPSED=$((NOW - PREV_TIME))
    [ $ELAPSED -lt 1 ] && ELAPSED=1

    SPEED_DATA=$(awk -v cachefile="$IW_CACHE" -v elapsed="$ELAPSED" '
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
    ' "$TMP_FILE")

    RX_KBPS=$(echo "$SPEED_DATA" | awk '{print $1}')
    TX_KBPS=$(echo "$SPEED_DATA" | awk '{print $2}')
    [ -z "$RX_KBPS" ] && RX_KBPS=0
    [ -z "$TX_KBPS" ] && TX_KBPS=0

    cp "$TMP_FILE" "$IW_CACHE"
    echo "$NOW" > "$IW_CACHE.time"

    # Update history
    echo "${TX_KBPS},${RX_KBPS}" >> "$THRU_LOG"
    tail -n $MAX_HISTORY "$THRU_LOG" > "${THRU_LOG}.tmp" && mv "${THRU_LOG}.tmp" "$THRU_LOG"

    TX_HIST=$(awk -F',' 'NF==2 && $1 ~ /^[0-9]+$/ {printf "%s%s", sep, $1; sep=","}' "$THRU_LOG")
    RX_HIST=$(awk -F',' 'NF==2 && $2 ~ /^[0-9]+$/ {printf "%s%s", sep, $2; sep=","}' "$THRU_LOG")
    [ -z "$TX_HIST" ] && TX_HIST="0"
    [ -z "$RX_HIST" ] && RX_HIST="0"

    TX_PEAK=$(awk -F',' 'NF==2 && $1 ~ /^[0-9]+$/ {if($1>max)max=$1} END{print max+0}' "$THRU_LOG")
    RX_PEAK=$(awk -F',' 'NF==2 && $2 ~ /^[0-9]+$/ {if($2>max)max=$2} END{print max+0}' "$THRU_LOG")

    # --- Get uplink SSID ---
    UPLINK_SSID=$(get_uplink_ssid)

    # --- Availability tracking ---
    WEB_OK=0; PING_OK=0
    [ "$WEB_CODE" = "204" ] && [ "$WEB_MS" -gt 0 ] 2>/dev/null && WEB_OK=1
    [ "$PING_MS" != "-1" ] && PING_OK=1

    # Both must succeed for "available"
    if [ $WEB_OK -eq 1 ] && [ $PING_OK -eq 1 ]; then
        AVAIL=1
        echo "$NOW" > "$LAST_SUCCESS_FILE"
    else
        AVAIL=0
    fi

    echo "$AVAIL" >> "$AVAIL_LOG"
    tail -n $MAX_HISTORY "$AVAIL_LOG" > "${AVAIL_LOG}.tmp" && mv "${AVAIL_LOG}.tmp" "$AVAIL_LOG"
    AVAIL_HIST=$(awk 'NF && /^[01]$/ {printf "%s%s", sep, $1; sep=","}' "$AVAIL_LOG")
    [ -z "$AVAIL_HIST" ] && AVAIL_HIST="1"

    read LAST_SUCCESS < "$LAST_SUCCESS_FILE" 2>/dev/null || LAST_SUCCESS=0

    # --- Output JSON ---
    cat > "$JSON_OUT" << EOF
{
  "ts": $NOW,
  "interval": $INTERVAL,
  "uplink_ssid": "$UPLINK_SSID",
  "web": {"code": $WEB_CODE, "ms": $WEB_MS, "history": [$FETCH_HIST]},
  "ping": {"current": $PING_MS, "history": [$PING_HIST]},
  "throughput": {
    "rx_kbps": $RX_KBPS, "tx_kbps": $TX_KBPS,
    "rx_peak": $RX_PEAK, "tx_peak": $TX_PEAK,
    "rx_history": [$RX_HIST], "tx_history": [$TX_HIST],
    "source": "iw-station"
  },
  "avail": {"current": $AVAIL, "last_success": $LAST_SUCCESS, "history": [$AVAIL_HIST]}
}
EOF
    log "Web:${WEB_MS}ms Ping:${PING_MS}ms DL:${TX_KBPS}K UL:${RX_KBPS}K"
}

# Cleanup on exit
trap "rm -f $PID_FILE; exit 0" INT TERM

log "Dashboard daemon starting (interval: ${INTERVAL}s, history: ${MAX_HISTORY} samples)"

# Main loop
while true; do
    collect_data
    sleep $INTERVAL
done
