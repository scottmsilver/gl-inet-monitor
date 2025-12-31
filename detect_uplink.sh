#!/bin/sh
# Detect uplink type based on IP/ASN lookup
# Returns connection type and recommended latency thresholds

# Get external IP
get_external_ip() {
  curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
  curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
  curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null
}

# Lookup ASN info for an IP
lookup_asn() {
  local ip="$1"
  # Use ip-api.com - free, no API key, returns JSON
  curl -s --max-time 5 "http://ip-api.com/json/${ip}?fields=status,isp,org,as,query" 2>/dev/null
}

# Classify by ASN number (most reliable)
classify_by_asn_number() {
  local as_field="$1"
  # Extract just the AS number (e.g., "AS14593 SpaceX" -> "14593")
  local asn=$(echo "$as_field" | grep -oE 'AS[0-9]+' | sed 's/AS//')
  [ -z "$asn" ] && return 1

  case "$asn" in
    # Starlink - LEO satellite
    14593) echo "starlink"; return 0 ;;

    # Airplane WiFi
    21928|393960) echo "airplane"; return 0 ;;           # Gogo
    18747|64294) echo "airplane"; return 0 ;;            # Panasonic Avionics
    50973) echo "airplane"; return 0 ;;                   # Inmarsat (also maritime)
    22351) echo "airplane"; return 0 ;;                   # Intelsat (airplane/maritime)

    # GEO Satellite ISPs
    7155|16491|40306|40311|46536) echo "geo_satellite"; return 0 ;;  # Viasat
    1358|6621|63062) echo "geo_satellite"; return 0 ;;               # HughesNet
    35228) echo "geo_satellite"; return 0 ;;                          # EchoStar

    # Maritime
    15146) echo "maritime"; return 0 ;;                   # Marlink
    26415) echo "maritime"; return 0 ;;                   # Speedcast
  esac

  return 1  # Unknown ASN
}

# Classify connection based on ASN/ISP info
classify_connection() {
  local asn_info="$1"

  # Extract AS field for number-based lookup
  local as_field=$(echo "$asn_info" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)

  # Try ASN number first (most reliable)
  local result=$(classify_by_asn_number "$as_field")
  if [ -n "$result" ]; then
    echo "$result"
    return
  fi

  # Fall back to keyword matching on ISP/org/AS fields
  local info_upper=$(echo "$asn_info" | tr '[:lower:]' '[:upper:]')

  # Starlink / SpaceX - LEO satellite
  if echo "$info_upper" | grep -qE 'STARLINK|SPACEX'; then
    echo "starlink"
    return
  fi

  # Airplane WiFi providers - GEO satellite, high latency
  if echo "$info_upper" | grep -qE 'GOGO|GO-GO|PANASONIC.*AVIONIC|INMARSAT|VIASAT.*AIRLINE|ANUVU|THALES|SMARTSKY|GLOBAL EAGLE'; then
    echo "airplane"
    return
  fi

  # GEO satellite providers - high latency
  if echo "$info_upper" | grep -qE 'VIASAT|HUGHESNET|ECHOSTAR|EUTELSAT|SES S\.A|TELESAT|SKYTERRA'; then
    echo "geo_satellite"
    return
  fi

  # Maritime satellite
  if echo "$info_upper" | grep -qE 'MARITIME|MARLINK|KVH|SPEEDCAST'; then
    echo "maritime"
    return
  fi

  # Mobile/cellular - variable latency
  if echo "$info_upper" | grep -qE 'T-MOBILE|VERIZON WIRELESS|AT&T MOBILITY|CELLULAR|LTE|5G'; then
    echo "cellular"
    return
  fi

  # Default to landline
  echo "landline"
}

# Get thresholds for connection type
# Returns: ping_good ping_warn fetch_good fetch_warn
get_thresholds() {
  local conn_type="$1"

  case "$conn_type" in
    starlink)
      # LEO satellite - decent latency but variable
      echo "60 120 150 400"
      ;;
    airplane|geo_satellite|maritime)
      # GEO satellite - high latency is normal
      echo "700 1000 800 1500"
      ;;
    cellular)
      # Mobile - variable
      echo "80 150 200 500"
      ;;
    landline|*)
      # Landline/fiber - low latency expected
      echo "30 80 100 300"
      ;;
  esac
}

# Main
main() {
  local output_format="${1:-text}"

  # Get external IP
  local ext_ip=$(get_external_ip)
  if [ -z "$ext_ip" ]; then
    echo "Error: Could not determine external IP" >&2
    exit 1
  fi

  # Lookup ASN info
  local asn_info=$(lookup_asn "$ext_ip")
  if [ -z "$asn_info" ]; then
    echo "Error: Could not lookup ASN info" >&2
    exit 1
  fi

  # Classify connection
  local conn_type=$(classify_connection "$asn_info")

  # Get thresholds
  local thresholds=$(get_thresholds "$conn_type")
  local ping_good=$(echo "$thresholds" | cut -d' ' -f1)
  local ping_warn=$(echo "$thresholds" | cut -d' ' -f2)
  local fetch_good=$(echo "$thresholds" | cut -d' ' -f3)
  local fetch_warn=$(echo "$thresholds" | cut -d' ' -f4)

  # Extract ISP name for display
  local isp=$(echo "$asn_info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
  local org=$(echo "$asn_info" | grep -o '"org":"[^"]*"' | cut -d'"' -f4)
  local as=$(echo "$asn_info" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)

  if [ "$output_format" = "json" ]; then
    cat <<EOF
{
  "ip": "$ext_ip",
  "isp": "$isp",
  "org": "$org",
  "as": "$as",
  "connection_type": "$conn_type",
  "thresholds": {
    "ping": {"good": $ping_good, "warn": $ping_warn},
    "fetch": {"good": $fetch_good, "warn": $fetch_warn}
  }
}
EOF
  else
    echo "External IP: $ext_ip"
    echo "ISP: $isp"
    echo "Org: $org"
    echo "AS: $as"
    echo "Connection Type: $conn_type"
    echo "Ping Thresholds: good < ${ping_good}ms, warn < ${ping_warn}ms"
    echo "Fetch Thresholds: good < ${fetch_good}ms, warn < ${fetch_warn}ms"
  fi
}

main "$@"
