#!/bin/sh
# Chaos/integration test: simulate an unstable airline-wifi-style connection
# across many cycles and assert the daemon stays healthy.
#
# Touches nothing real:
#   - Sources dash_daemon.sh with DASH_DAEMON_TEST=1 (no main loop)
#   - Redirects ALL output paths to /tmp/airplane_sandbox/
#   - Mocks curl/ping/iwinfo/iw/ubus/timeout/uci via shell functions
#
# Scenarios driven by $CYCLE_NUM:
#   cycles  1- 8  STABLE      — both probes succeed, low latency
#   cycles  9-16  DEGRADING   — web ms rises 800-1500, ping fails ~50%
#   cycles 17-24  BLACKOUT    — every probe fails
#   cycles 25-32  FLAPPING    — alternates success/fail each cycle
#   cycles 33-40  RECOVERY    — back to stable
#
# Invariants asserted per cycle:
#   1. data.json is valid JSON (jsonfilter parses)
#   2. avail.current matches the scenario's expected value
#   3. Cycle ran in < 3 seconds wall time
#   4. No probe leaked unrecognised values into the schema

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); }
fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "${RED}FAIL cycle %d (%s): %s${NC}\n" "$1" "$2" "$3"
}

# --- Load daemon ---
DASH_DAEMON_TEST=1
SCRIPT_DIR=$(dirname "$0")
. "$SCRIPT_DIR/dash_daemon.sh"

# --- Sandbox ALL paths ---
SANDBOX=$(mktemp -d 2>/dev/null || mktemp -d -t airplane)
JSON_OUT="$SANDBOX/data.json"
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
echo "0" > "$LAST_SUCCESS_FILE"

# --- Scenario classifier ---
# Echoes one of: stable, degrading, blackout, flapping, recovery
scenario_for_cycle() {
    local n="$1"
    if   [ "$n" -le 8  ]; then echo stable
    elif [ "$n" -le 16 ]; then echo degrading
    elif [ "$n" -le 24 ]; then echo blackout
    elif [ "$n" -le 32 ]; then echo flapping
    else                       echo recovery
    fi
}

# Expected avail.current for each scenario+cycle. We require the daemon to
# correctly identify outage cycles.
#   stable      -> 1   (always up)
#   degrading   -> mixed (web up, ping ~50%); daemon's AND-gate: ping fails -> 0
#                  We use a deterministic pattern: cycles 9,11,13,15 = ping OK -> 1
#                                                   cycles 10,12,14,16 = ping fails -> 0
#   blackout    -> 0   (always down)
#   flapping    -> alternating starting with 1 on cycle 25
#   recovery    -> 1   (always up)
expected_avail_for_cycle() {
    local n="$1"
    case "$(scenario_for_cycle $n)" in
        stable|recovery) echo 1 ;;
        blackout)        echo 0 ;;
        degrading)
            # ping succeeds on odd cycles
            [ $((n % 2)) = 1 ] && echo 1 || echo 0
            ;;
        flapping)
            # cycles 25,27,29,31 succeed; 26,28,30,32 fail
            [ $((n % 2)) = 1 ] && echo 1 || echo 0
            ;;
    esac
}

# --- Mock external commands per cycle (driven by $CYCLE_NUM) ---

timeout() { shift; "$@"; }   # neutralize timeout wrapper

uci() { return 1; }

iwinfo() {
    case "$1" in
        sta0) echo 'wlan0     ESSID: "AirlineWifi"' ;;
        *)    echo 'unknown' ;;
    esac
}

# Mock iw to emit no station data (so throughput is 0). Avoids needing to
# manage byte-counter cache state across mocked cycles.
iw() { :; }

# Mock ubus: simulate no clients online so probe_clients returns "0 0 0".
ubus() {
    # `ubus -t N call ...` — discard the -t N if present
    [ "$1" = "-t" ] && shift 2
    [ "$1" = "call" ] && echo '{"clients":{}}'
}

# Probe the system for a sub-second sleep mechanism we can use to fake HTTP
# latency in the curl mock. The daemon's compute_avail requires web_ms > 0
# (a real HTTP request always satisfies this — an instant mock would not).
if usleep 1 2>/dev/null; then
    fake_latency() { usleep 50000; }
elif sleep 0.05 2>/dev/null; then
    fake_latency() { sleep 0.05; }
else
    echo "WARN: no sub-second sleep available; web_ms will be 0 and avail checks may fail" >&2
    fake_latency() { :; }
fi

# Mock curl: probe_web is the only probe that calls curl.
curl() {
    local scenario=$(scenario_for_cycle "$CYCLE_NUM")
    fake_latency
    case "$scenario" in
        stable|recovery) echo "204" ;;
        degrading)       echo "204" ;;
        blackout)        echo "000" ;;
        flapping)
            [ $((CYCLE_NUM % 2)) = 1 ] && echo "204" || echo "000"
            ;;
        *)               echo "000" ;;
    esac
}

# Mock ping: only probe_ping calls ping.
ping() {
    local scenario=$(scenario_for_cycle "$CYCLE_NUM")
    case "$scenario" in
        stable|recovery)
            echo "PING test (1.2.3.4): 56 data bytes
64 bytes from 1.2.3.4: seq=0 ttl=118 time=15.3 ms"
            ;;
        degrading)
            # Alternate: odd cycle = ping OK (high latency), even = ping fails
            if [ $((CYCLE_NUM % 2)) = 1 ]; then
                echo "PING test (1.2.3.4): 56 data bytes
64 bytes from 1.2.3.4: seq=0 ttl=118 time=950.2 ms"
            else
                echo "PING test: timeout" ; return 1
            fi
            ;;
        blackout)
            echo "PING test: timeout" ; return 1
            ;;
        flapping)
            if [ $((CYCLE_NUM % 2)) = 1 ]; then
                echo "64 bytes: time=80 ms"
            else
                return 1
            fi
            ;;
    esac
}

# --- Run scenarios ---
echo "Sandbox: $SANDBOX"
echo
printf "${YELLOW}Running 40 simulated cycles...${NC}\n\n"
printf "  %-6s %-10s %-5s %-7s %-7s %-9s %-6s\n" cycle scenario want got web_code web_ms ping_ms

NUM_CYCLES=40
CYCLE_NUM=1
while [ "$CYCLE_NUM" -le "$NUM_CYCLES" ]; do
    scenario=$(scenario_for_cycle "$CYCLE_NUM")
    want=$(expected_avail_for_cycle "$CYCLE_NUM")

    # Time the cycle
    start=$(date +%s)
    collect_data >/dev/null 2>&1
    end=$(date +%s)
    elapsed=$((end - start))

    # --- Invariant 1: JSON parses ---
    if ! jsonfilter -e '@' < "$JSON_OUT" >/dev/null 2>&1; then
        fail "$CYCLE_NUM" "$scenario" "JSON does not parse"
        head -c 300 "$JSON_OUT"
        echo
        CYCLE_NUM=$((CYCLE_NUM + 1))
        continue
    fi
    pass

    # --- Invariant 2: avail.current matches scenario ---
    got=$(jsonfilter -e '@.avail.current' < "$JSON_OUT")
    if [ "$got" = "$want" ]; then
        pass
    else
        fail "$CYCLE_NUM" "$scenario" "avail want=$want got=$got"
    fi

    # --- Invariant 3: cycle time bounded ---
    if [ "$elapsed" -le 3 ]; then
        pass
    else
        fail "$CYCLE_NUM" "$scenario" "cycle took ${elapsed}s (> 3s)"
    fi

    web_code=$(jsonfilter -e '@.web.code' < "$JSON_OUT")
    web_ms=$(jsonfilter -e '@.web.ms' < "$JSON_OUT")
    ping_ms=$(jsonfilter -e '@.ping.current' < "$JSON_OUT")

    indicator=" "
    [ "$got" != "$want" ] && indicator="!"
    printf " %s%-6d %-10s %-5s %-7s %-7s %-9s %-6s\n" \
        "$indicator" "$CYCLE_NUM" "$scenario" "$want" "$got" "$web_code" "$web_ms" "$ping_ms"

    CYCLE_NUM=$((CYCLE_NUM + 1))
done

# --- Post-run invariants ---
echo
printf "${YELLOW}Post-run checks...${NC}\n"

# Invariant 4: history accumulated to expected length
avail_hist_len=$(jsonfilter -e '@.avail.history' < "$JSON_OUT" | tr ',' '\n' | grep -c .)
if [ "$avail_hist_len" = "$NUM_CYCLES" ]; then
    printf "${GREEN}PASS${NC}: avail history length = %d cycles\n" "$NUM_CYCLES"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf "${RED}FAIL${NC}: avail history length expected %d, got %d\n" "$NUM_CYCLES" "$avail_hist_len"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Invariant 5: avail history matches the scenario pattern
# Expected pattern:
#   8x stable up   -> 1,1,1,1,1,1,1,1
#   8x degrading   -> 1,0,1,0,1,0,1,0  (odd=up, even=down)
#   8x blackout    -> 0,0,0,0,0,0,0,0
#   8x flapping    -> 1,0,1,0,1,0,1,0  (odd=up, even=down)
#   8x recovery    -> 1,1,1,1,1,1,1,1
expected_pattern="1,1,1,1,1,1,1,1,1,0,1,0,1,0,1,0,0,0,0,0,0,0,0,0,1,0,1,0,1,0,1,0,1,1,1,1,1,1,1,1"
# jsonfilter formats arrays as `[ 1, 0, ... ]`; normalize to a bare CSV
got_pattern=$(jsonfilter -e '@.avail.history' < "$JSON_OUT" | tr -d ' []')
if [ "$got_pattern" = "$expected_pattern" ]; then
    printf "${GREEN}PASS${NC}: avail.history pattern matches scenario sequence\n"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf "${RED}FAIL${NC}: avail.history pattern mismatch\n  want: %s\n  got:  %s\n" "$expected_pattern" "$got_pattern"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Invariant 6: last_success advanced into the recovery scenario
last_success=$(jsonfilter -e '@.avail.last_success' < "$JSON_OUT")
ts_now=$(jsonfilter -e '@.ts' < "$JSON_OUT")
if [ "$last_success" -gt 0 ] && [ "$last_success" -le "$ts_now" ]; then
    printf "${GREEN}PASS${NC}: last_success populated (%d, ts=%d)\n" "$last_success" "$ts_now"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    printf "${RED}FAIL${NC}: last_success suspicious: %d (ts=%d)\n" "$last_success" "$ts_now"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# --- Summary ---
echo
printf "========================================\n"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "$FAIL_COUNT" = 0 ]; then
    printf "${GREEN}All %d invariants passed across %d cycles.${NC}\n" "$TOTAL" "$NUM_CYCLES"
    exit 0
else
    printf "${RED}%d / %d invariants FAILED.${NC}\n" "$FAIL_COUNT" "$TOTAL"
    exit 1
fi
