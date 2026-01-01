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
UPLINK_CACHE="/tmp/uplink_cache.json"
UPLINK_DETECT_INTERVAL=60  # Re-detect every 60 samples (5 min at 5s interval)
UPLINK_SAMPLE_COUNT=0
CLIENTS_LOG="/tmp/clients_history.log"

# --- Uplink Detection Functions ---

get_external_ip() {
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
  curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
  curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null
}

lookup_asn() {
  local ip="$1"
  curl -s --max-time 5 "http://ip-api.com/json/${ip}?fields=status,isp,org,as,query" 2>/dev/null
}

classify_by_asn_number() {
  local as_field="$1"
  local asn=$(echo "$as_field" | grep -oE 'AS[0-9]+' | sed 's/AS//')
  [ -z "$asn" ] && return 1

  case "$asn" in
    14593) echo "starlink"; return 0 ;;
    21928|393960) echo "airplane"; return 0 ;;
    18747|64294) echo "airplane"; return 0 ;;
    50973|22351) echo "airplane"; return 0 ;;
    7155|16491|40306|40311|46536) echo "geo_satellite"; return 0 ;;
    1358|6621|63062) echo "geo_satellite"; return 0 ;;
    35228) echo "geo_satellite"; return 0 ;;
    15146|26415) echo "maritime"; return 0 ;;
  esac
  return 1
}

classify_connection() {
  local asn_info="$1"
  local as_field=$(echo "$asn_info" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)

  local result=$(classify_by_asn_number "$as_field")
  if [ -n "$result" ]; then
    echo "$result"
    return
  fi

  local info_upper=$(echo "$asn_info" | tr '[:lower:]' '[:upper:]')

  if echo "$info_upper" | grep -qE 'STARLINK|SPACEX'; then
    echo "starlink"; return
  fi
  if echo "$info_upper" | grep -qE 'GOGO|GO-GO|PANASONIC.*AVIONIC|INMARSAT|VIASAT.*AIRLINE|ANUVU|THALES|SMARTSKY|GLOBAL EAGLE'; then
    echo "airplane"; return
  fi
  if echo "$info_upper" | grep -qE 'VIASAT|HUGHESNET|ECHOSTAR|EUTELSAT|SES S\.A|TELESAT|SKYTERRA'; then
    echo "geo_satellite"; return
  fi
  if echo "$info_upper" | grep -qE 'MARITIME|MARLINK|KVH|SPEEDCAST'; then
    echo "maritime"; return
  fi
  if echo "$info_upper" | grep -qE 'T-MOBILE|VERIZON WIRELESS|AT&T MOBILITY|CELLULAR|LTE|5G'; then
    echo "cellular"; return
  fi
  echo "landline"
}

get_thresholds() {
  local conn_type="$1"
  # Format: ping_good ping_warn web_good web_warn
  # Web thresholds ~3x ping (TCP handshake + HTTP round trips)
  case "$conn_type" in
    starlink) echo "60 120 200 400" ;;
    airplane|geo_satellite|maritime) echo "700 1000 2000 3500" ;;
    cellular) echo "80 150 250 500" ;;
    *) echo "30 80 100 300" ;;
  esac
}

detect_uplink() {
  # Check if we have a valid cache
  if [ -f "$UPLINK_CACHE" ] && [ $UPLINK_SAMPLE_COUNT -lt $UPLINK_DETECT_INTERVAL ]; then
    UPLINK_SAMPLE_COUNT=$((UPLINK_SAMPLE_COUNT + 1))
    return 0
  fi

  log "Detecting uplink type..."
  UPLINK_SAMPLE_COUNT=0

  local ext_ip=$(get_external_ip)
  if [ -z "$ext_ip" ]; then
    log "Could not get external IP, using defaults"
    # Write default cache (landline defaults)
    cat > "$UPLINK_CACHE" << CACHE
{"connection_type":"unknown","isp":"Unknown","thresholds":{"ping":{"good":30,"warn":80},"web":{"good":100,"warn":300}}}
CACHE
    return 1
  fi

  local asn_info=$(lookup_asn "$ext_ip")
  if [ -z "$asn_info" ]; then
    log "Could not lookup ASN, using defaults"
    cat > "$UPLINK_CACHE" << CACHE
{"connection_type":"unknown","isp":"Unknown","thresholds":{"ping":{"good":30,"warn":80},"web":{"good":100,"warn":300}}}
CACHE
    return 1
  fi

  local conn_type=$(classify_connection "$asn_info")
  local thresholds=$(get_thresholds "$conn_type")
  local ping_good=$(echo "$thresholds" | cut -d' ' -f1)
  local ping_warn=$(echo "$thresholds" | cut -d' ' -f2)
  local web_good=$(echo "$thresholds" | cut -d' ' -f3)
  local web_warn=$(echo "$thresholds" | cut -d' ' -f4)

  local isp=$(echo "$asn_info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
  [ -z "$isp" ] && isp="Unknown"

  cat > "$UPLINK_CACHE" << CACHE
{"connection_type":"$conn_type","isp":"$isp","thresholds":{"ping":{"good":$ping_good,"warn":$ping_warn},"web":{"good":$web_good,"warn":$web_warn}}}
CACHE

  log "Uplink detected: $conn_type ($isp)"
  return 0
}

# --- Client Data Collection Functions ---

# Collect client data using jsonfilter (available on OpenWrt)
collect_clients() {
  # Refresh LuCI hints cache occasionally (every 60 seconds)
  local hints_cache="/tmp/luci_hints.cache"
  local hints_age=9999
  if [ -f "$hints_cache" ]; then
    local cache_mtime=$(stat -c %Y "$hints_cache" 2>/dev/null || stat -f %m "$hints_cache" 2>/dev/null || echo 0)
    hints_age=$(($(date +%s) - cache_mtime))
  fi
  if [ $hints_age -gt 60 ]; then
    ubus call luci-rpc getHostHints '{}' > "$hints_cache" 2>/dev/null
  fi

  # Get gl-clients data
  local clients_raw=$(ubus call gl-clients list '{}' 2>/dev/null)
  [ -z "$clients_raw" ] && clients_raw='{"clients":{}}'

  # Use jsonfilter to extract client data
  local macs=$(echo "$clients_raw" | jsonfilter -e '@.clients[*].mac' 2>/dev/null)

  CLIENTS_ONLINE=0
  CLIENTS_TOTAL_TX=0
  CLIENTS_TOTAL_RX=0
  CLIENTS_JSON=""
  local first=1

  for mac in $macs; do
    # Get client data using jsonfilter
    local online=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].online" 2>/dev/null)
    [ "$online" != "true" ] && continue

    local ip=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].ip" 2>/dev/null)
    local iface=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].iface" 2>/dev/null)
    local tx=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].tx" 2>/dev/null)
    local rx=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].rx" 2>/dev/null)
    local gl_name=$(echo "$clients_raw" | jsonfilter -e "@.clients[\"$mac\"].name" 2>/dev/null)

    # Convert bytes/sec to kbps
    tx=$((${tx:-0} * 8 / 1000))
    rx=$((${rx:-0} * 8 / 1000))

    # Resolve name
    local name=""
    # 1. Use gl-clients name if available
    if [ -n "$gl_name" ] && [ "$gl_name" != "" ]; then
      name="$gl_name"
    fi
    # 2. Check DHCP leases
    if [ -z "$name" ] && [ -f /tmp/dhcp.leases ]; then
      local mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
      name=$(awk -v m="$mac_lower" 'tolower($2)==m && $4!="*" {print $4}' /tmp/dhcp.leases)
    fi
    # 3. Check if random MAC (locally administered)
    if [ -z "$name" ]; then
      local first_byte=$(echo "$mac" | cut -d: -f1)
      local dec=$(printf "%d" "0x$first_byte" 2>/dev/null || echo 0)
      if [ $((dec & 2)) -ne 0 ]; then
        name="Private Device"
      fi
    fi
    # 4. Fallback to truncated MAC
    [ -z "$name" ] && name=$(echo "$mac" | cut -d: -f1-3)

    # Build JSON
    CLIENTS_ONLINE=$((CLIENTS_ONLINE + 1))
    CLIENTS_TOTAL_TX=$((CLIENTS_TOTAL_TX + tx))
    CLIENTS_TOTAL_RX=$((CLIENTS_TOTAL_RX + rx))

    [ $first -eq 0 ] && CLIENTS_JSON="${CLIENTS_JSON},"
    first=0
    CLIENTS_JSON="${CLIENTS_JSON}{\"mac\":\"$mac\",\"name\":\"$name\",\"ip\":\"$ip\",\"iface\":\"$iface\",\"tx\":$tx,\"rx\":$rx}"
  done

  # Update history
  echo "$CLIENTS_ONLINE" >> "$CLIENTS_LOG"
  tail -n $MAX_HISTORY "$CLIENTS_LOG" > "${CLIENTS_LOG}.tmp" && mv "${CLIENTS_LOG}.tmp" "$CLIENTS_LOG"
  CLIENTS_HIST=$(cat "$CLIENTS_LOG" | tr '\n' ',' | sed 's/,$//')
  [ -z "$CLIENTS_HIST" ] && CLIENTS_HIST="0"
}

# Write PID file
echo $$ > "$PID_FILE"

# Initialize logs
[ -f "$FETCH_LOG" ] || touch "$FETCH_LOG"
[ -f "$PING_LOG" ] || touch "$PING_LOG"
[ -f "$THRU_LOG" ] || touch "$THRU_LOG"
[ -f "$AVAIL_LOG" ] || touch "$AVAIL_LOG"
[ -f "$CLIENTS_LOG" ] || touch "$CLIENTS_LOG"
[ -f "$LAST_SUCCESS_FILE" ] || echo "0" > "$LAST_SUCCESS_FILE"

log() {
    echo "$(date '+%H:%M:%S') $1"
}

get_uplink_ssid() {
    # Try sta0/sta1 first (repeater uplink interfaces)
    # Handle both quoted ("SSID") and unquoted (unknown) formats
    SSID=$(iwinfo sta0 info 2>/dev/null | awk -F'ESSID: ' '/ESSID:/{gsub(/"/, "", $2); print $2}')
    [ -z "$SSID" ] || [ "$SSID" = "unknown" ] && \
        SSID=$(iwinfo sta1 info 2>/dev/null | awk -F'ESSID: ' '/ESSID:/{gsub(/"/, "", $2); print $2}')
    # Fallback to UCI config
    [ -z "$SSID" ] || [ "$SSID" = "unknown" ] && SSID=$(uci get wireless.sta.ssid 2>/dev/null)
    [ -z "$SSID" ] || [ "$SSID" = "unknown" ] && SSID="Not connected"
    echo "$SSID"
}

collect_data() {
    NOW=$(date +%s)

    # --- Detect uplink type (cached, refreshes every 5 min) ---
    detect_uplink
    UPLINK_JSON=$(cat "$UPLINK_CACHE" 2>/dev/null || echo '{"connection_type":"landline","isp":"Unknown","thresholds":{"ping":{"good":30,"warn":80},"web":{"good":100,"warn":300}}}')

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

    # --- Collect client data ---
    collect_clients

    # --- Output JSON ---
    cat > "$JSON_OUT" << EOF
{
  "ts": $NOW,
  "interval": $INTERVAL,
  "uplink_ssid": "$UPLINK_SSID",
  "uplink": $UPLINK_JSON,
  "web": {"code": $WEB_CODE, "ms": $WEB_MS, "history": [$FETCH_HIST]},
  "ping": {"current": $PING_MS, "history": [$PING_HIST]},
  "throughput": {
    "rx_kbps": $RX_KBPS, "tx_kbps": $TX_KBPS,
    "rx_peak": $RX_PEAK, "tx_peak": $TX_PEAK,
    "rx_history": [$RX_HIST], "tx_history": [$TX_HIST],
    "source": "iw-station"
  },
  "avail": {"current": $AVAIL, "last_success": $LAST_SUCCESS, "history": [$AVAIL_HIST]},
  "clients": {"online": $CLIENTS_ONLINE, "total_tx": $CLIENTS_TOTAL_TX, "total_rx": $CLIENTS_TOTAL_RX, "history": [$CLIENTS_HIST], "list": [$CLIENTS_JSON]}
}
EOF
    log "Web:${WEB_MS}ms Ping:${PING_MS}ms DL:${TX_KBPS}K UL:${RX_KBPS}K Clients:${CLIENTS_ONLINE}"
}

# Cleanup on exit
trap "rm -f $PID_FILE; exit 0" INT TERM

log "Dashboard daemon starting (interval: ${INTERVAL}s, history: ${MAX_HISTORY} samples)"

# Main loop
while true; do
    collect_data
    sleep $INTERVAL
done
