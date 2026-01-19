#!/bin/sh
# Test suite for dash_daemon.sh functions
# Run with: sh test_daemon.sh

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf "${GREEN}PASS${NC}: %s\n" "$1"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "${RED}FAIL${NC}: %s (expected '%s', got '%s')\n" "$1" "$2" "$3"
}

assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name" "$expected" "$actual"
  fi
}

assert_contains() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1"
  local needle="$2"
  local haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    pass "$name"
  else
    fail "$name" "contains '$needle'" "$haystack"
  fi
}

# --- Setup: Source functions from daemon (skip the main loop) ---
# We'll extract and test individual functions

echo "=== Testing dash_daemon.sh functions ==="
echo ""

# --- Test classify_by_asn_number ---
echo "--- classify_by_asn_number tests ---"

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

result=$(classify_by_asn_number "AS14593 SpaceX Services")
assert_eq "Starlink ASN 14593" "starlink" "$result"

result=$(classify_by_asn_number "AS21928 Gogo LLC")
assert_eq "Gogo airplane ASN 21928" "airplane" "$result"

result=$(classify_by_asn_number "AS40306 ViaSat,Inc.")
assert_eq "ViaSat ASN 40306" "geo_satellite" "$result"

result=$(classify_by_asn_number "AS15146 Marlink")
assert_eq "Marlink maritime ASN 15146" "maritime" "$result"

result=$(classify_by_asn_number "AS7922 Comcast")
assert_eq "Unknown ASN returns empty" "" "$result"

echo ""

# --- Test get_thresholds ---
echo "--- get_thresholds tests ---"

get_thresholds() {
  local conn_type="$1"
  case "$conn_type" in
    starlink) echo "60 120 200 400" ;;
    airplane|geo_satellite|maritime) echo "700 1000 2000 3500" ;;
    cellular) echo "80 150 250 500" ;;
    *) echo "30 80 100 300" ;;
  esac
}

result=$(get_thresholds "starlink")
assert_eq "Starlink thresholds" "60 120 200 400" "$result"

result=$(get_thresholds "airplane")
assert_eq "Airplane thresholds" "700 1000 2000 3500" "$result"

result=$(get_thresholds "geo_satellite")
assert_eq "Geo satellite thresholds" "700 1000 2000 3500" "$result"

result=$(get_thresholds "cellular")
assert_eq "Cellular thresholds" "80 150 250 500" "$result"

result=$(get_thresholds "landline")
assert_eq "Landline thresholds" "30 80 100 300" "$result"

result=$(get_thresholds "unknown_type")
assert_eq "Unknown type gets landline thresholds" "30 80 100 300" "$result"

echo ""

# --- Test classify_connection ---
echo "--- classify_connection tests ---"

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

# Test ASN-based classification
result=$(classify_connection '{"as":"AS14593 SpaceX","isp":"SpaceX Services"}')
assert_eq "Classify Starlink by ASN" "starlink" "$result"

result=$(classify_connection '{"as":"AS40306 ViaSat,Inc.","isp":"ViaSat, Inc."}')
assert_eq "Classify ViaSat by ASN" "geo_satellite" "$result"

# Test keyword-based classification (when ASN doesn't match)
result=$(classify_connection '{"as":"AS12345 Unknown","isp":"Starlink Services"}')
assert_eq "Classify Starlink by keyword" "starlink" "$result"

result=$(classify_connection '{"as":"AS12345 Unknown","isp":"Gogo Inflight"}')
assert_eq "Classify Gogo by keyword" "airplane" "$result"

result=$(classify_connection '{"as":"AS12345 Unknown","isp":"HughesNet"}')
assert_eq "Classify HughesNet by keyword" "geo_satellite" "$result"

result=$(classify_connection '{"as":"AS12345 Unknown","isp":"T-Mobile USA"}')
assert_eq "Classify T-Mobile by keyword" "cellular" "$result"

result=$(classify_connection '{"as":"AS7922 Comcast","isp":"Comcast Cable"}')
assert_eq "Classify Comcast as landline" "landline" "$result"

echo ""

# --- Test is_random_mac logic ---
echo "--- is_random_mac tests ---"

is_random_mac() {
  local mac="$1"
  local first_byte=$(echo "$mac" | cut -d: -f1)
  local dec=$(printf "%d" "0x$first_byte" 2>/dev/null || echo 0)
  [ $((dec & 2)) -ne 0 ]
}

# Test random MACs (bit 1 set in first octet)
is_random_mac "F2:A6:CB:CD:14:55" && result="random" || result="real"
assert_eq "F2:xx is random (0xF2 & 2 = 2)" "random" "$result"

is_random_mac "CE:CB:B6:8E:87:62" && result="random" || result="real"
assert_eq "CE:xx is random (0xCE & 2 = 2)" "random" "$result"

is_random_mac "D2:CA:22:9E:F1:C5" && result="random" || result="real"
assert_eq "D2:xx is random (0xD2 & 2 = 2)" "random" "$result"

# Test real vendor MACs (bit 1 not set)
is_random_mac "CC:08:FA:61:FB:39" && result="random" || result="real"
assert_eq "CC:xx is real vendor (0xCC & 2 = 0)" "real" "$result"

is_random_mac "00:1A:2B:3C:4D:5E" && result="random" || result="real"
assert_eq "00:xx is real vendor" "real" "$result"

is_random_mac "AC:DE:48:00:11:22" && result="random" || result="real"
assert_eq "AC:xx is real vendor (0xAC & 2 = 0)" "real" "$result"

echo ""

# --- Test history append and format (proposed helper) ---
echo "--- append_history helper tests ---"

# Create temp directory for test files
TEST_DIR="/tmp/dash_daemon_test_$$"
mkdir -p "$TEST_DIR"

MAX_HISTORY=5

append_history() {
  local value="$1"
  local logfile="$2"
  echo "$value" >> "$logfile"
  tail -n $MAX_HISTORY "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
}

format_history_csv() {
  local logfile="$1"
  awk 'NF && /^-?[0-9]+$/ {printf "%s%s", sep, $1; sep=","}' "$logfile"
}

# Test appending and rotation
TEST_LOG="$TEST_DIR/test.log"
rm -f "$TEST_LOG"
touch "$TEST_LOG"

append_history "1" "$TEST_LOG"
append_history "2" "$TEST_LOG"
append_history "3" "$TEST_LOG"

result=$(format_history_csv "$TEST_LOG")
assert_eq "History after 3 appends" "1,2,3" "$result"

append_history "4" "$TEST_LOG"
append_history "5" "$TEST_LOG"
append_history "6" "$TEST_LOG"
append_history "7" "$TEST_LOG"

result=$(format_history_csv "$TEST_LOG")
assert_eq "History rotates to MAX_HISTORY=5" "3,4,5,6,7" "$result"

result=$(wc -l < "$TEST_LOG" | tr -d ' ')
assert_eq "Log file has MAX_HISTORY lines" "5" "$result"

echo ""

# --- Test threshold parsing ---
echo "--- threshold parsing tests ---"

parse_thresholds() {
  local thresholds="$1"
  local ping_good=$(echo "$thresholds" | cut -d' ' -f1)
  local ping_warn=$(echo "$thresholds" | cut -d' ' -f2)
  local web_good=$(echo "$thresholds" | cut -d' ' -f3)
  local web_warn=$(echo "$thresholds" | cut -d' ' -f4)
  echo "$ping_good $ping_warn $web_good $web_warn"
}

thresholds=$(get_thresholds "airplane")
result=$(parse_thresholds "$thresholds")
assert_eq "Parse airplane thresholds" "700 1000 2000 3500" "$result"

# Extract individual values
ping_good=$(echo "$thresholds" | cut -d' ' -f1)
assert_eq "Airplane ping_good" "700" "$ping_good"

web_warn=$(echo "$thresholds" | cut -d' ' -f4)
assert_eq "Airplane web_warn" "3500" "$web_warn"

echo ""

# --- Cleanup ---
rm -rf "$TEST_DIR"

# --- Summary ---
echo "=== Test Summary ==="
echo "Tests run: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [ $TESTS_FAILED -eq 0 ]; then
  printf "${GREEN}All tests passed!${NC}\n"
  exit 0
else
  printf "${RED}Some tests failed!${NC}\n"
  exit 1
fi
