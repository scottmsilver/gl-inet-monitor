# Plan: Add Client List and Per-Client Bandwidth to Dashboard

## Data Sources Available

### Primary: `ubus call gl-clients list '{}'`
Provides per-client:
- `mac`, `ip`, `name` (sometimes empty)
- `online` (boolean)
- `iface` ("5G", "2.4G")
- `tx`, `rx` - current speed (bytes/sec)
- `total_tx`, `total_rx` - cumulative bytes
- `last_tx`, `last_rx` - 60-sample history

### Supplementary (for names):
1. `/tmp/dhcp.leases` - DHCP hostnames
2. `ubus call luci-rpc getHostHints '{}'` - LuCI cached names
3. MAC vendor lookup (first 3 octets → manufacturer)

## Why Some Clients Are "Unnamed"
- Device didn't send hostname in DHCP request
- Using static IP (no DHCP interaction)
- Privacy-focused devices (iOS/Android randomize MACs + hide hostname)

## Implementation Plan

### Step 1: Add client data collection to dash_daemon.sh
- Call `ubus call gl-clients list '{}'`
- Parse JSON to extract online clients with their stats
- Merge names from multiple sources (gl-clients → DHCP → LuCI hints → MAC vendor)
- Calculate current bandwidth from tx/rx fields
- Add to data.json output

### Step 2: Update data.json schema
```json
{
  "clients": {
    "online_count": 6,
    "total_tx_kbps": 24,
    "total_rx_kbps": 1,
    "list": [
      {
        "mac": "F2:A6:CB:CD:14:55",
        "ip": "192.168.8.171",
        "name": "Unknown (Apple)",  // fallback to vendor
        "tx_kbps": 20,
        "rx_kbps": 0.5,
        "iface": "5G"
      }
    ]
  }
}
```

### Step 3: Add UI to dash2.html
Options:
- A) New expandable row showing client count + total bandwidth
- B) Small badge in header showing "6 clients"
- C) Separate clients panel accessible via tap/click

Suggested: Option A - new row like "Clients" with:
- Sparkline showing online count over time (or total bandwidth)
- Current online count
- Expandable detail showing per-client breakdown

### Step 4: Name Resolution Strategy
Priority order:
1. `gl-clients` name field (if not empty)
2. DHCP lease hostname
3. LuCI host hints name
4. MAC vendor prefix (e.g., "Apple", "Samsung", "Intel")
5. Truncated MAC as last resort (e.g., "F2:A6:CB")

### Step 5: MAC Vendor Lookup
- Embed small lookup table for common vendors
- Or use online API sparingly with caching
- Common prefixes: Apple, Samsung, Google, Intel, Raspberry Pi, etc.

## Open Questions
1. Should we show offline clients too? (maybe grayed out)
2. How much history to keep per client?
3. Should clicking a client show its historical bandwidth?

## Files to Modify
- `dash_daemon.sh` - add client data collection
- `dash2.html` - add clients UI row/panel
- `data.json` - new clients section
