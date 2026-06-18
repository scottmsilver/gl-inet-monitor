#!/bin/sh
# Re-assert tailnet routing/DNS that GL firmware resets across reboots / re-stomps.
# Idempotent + self-healing. Runs at boot (waits for tailscaled) and every 5 min.
LOG=/tmp/dash_net_persist.log
note() { echo "$(date "+%F %T") $*" >> "$LOG"; }

# wait up to ~60s for tailscaled (returns instantly on cron runs)
i=0; while [ $i -lt 15 ]; do tailscale status >/dev/null 2>&1 && break; i=$((i+1)); sleep 4; done

# 1) tailnet prefs (GL re-runs `tailscale up` on boot without these)
tailscale status >/dev/null 2>&1 && tailscale set --accept-routes=true --accept-dns=true --hostname=beryl-ax 2>>"$LOG"

# 2) masquerade on the tailscale firewall zone (SNAT forwarded LAN -> tailnet)
z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name=.tailscale.\$/\1/p" | head -1)
if [ -n "$z" ] && [ "$(uci -q get firewall.$z.masq)" != "1" ]; then
  uci set firewall.$z.masq=1 && uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1
  note "restored $z masq=1"
fi

# 3) dnsmasq split-DNS forwards (add any missing)
DESIRED="/tail957ef.ts.net/100.100.100.100 /91wpc/100.100.100.100 /i.oursilverfamily.com/192.168.1.1 /316costello/192.168.1.1 /1.168.192.in-addr.arpa/192.168.1.1"
cur=$(uci -q get dhcp.@dnsmasq[0].server)
changed=0
for e in $DESIRED; do
  echo " $cur " | grep -q " $e " || { uci add_list dhcp.@dnsmasq[0].server="$e"; changed=1; note "re-added dnsmasq $e"; }
done
[ "$changed" = 1 ] && { uci commit dhcp && /etc/init.d/dnsmasq restart >/dev/null 2>&1; note "dnsmasq reloaded"; }

# Re-inject the floating dashboard link if a firmware update wiped gl_home.html.
if [ -f /www/gl_home.html ] && ! grep -q "/dash2.html" /www/gl_home.html 2>/dev/null; then
  cat /root/dash_link.html >> /www/gl_home.html 2>/dev/null && note "re-injected dashboard link into gl_home.html"
fi
