# device/ — on-router operational scripts

Scripts that live on the Beryl AX (not part of the collector binary). The router
keeps the canonical copies; these are the version-controlled source.

## `dash_net_persist.sh` → `/root/dash_net_persist.sh`
Self-healing hook that re-asserts state GL's firmware/boot strips, run **at boot**
(via `/etc/init.d/dash_net_persist`) and **every 5 min** (cron). Idempotent —
only acts on drift. Enforces:
- Tailscale `--accept-routes --accept-dns --hostname=beryl-ax` (GL re-runs
  `tailscale up` without these on boot),
- masquerade on the `tailscale` firewall zone (SNAT forwarded LAN→tailnet),
- the dnsmasq split-DNS forwards (tailnet + home domains),
- the floating dashboard link in `gl_home.html` (re-injects if a firmware update
  wiped it — see below).

Install:
```sh
cat device/dash_net_persist.sh | ssh -i ~/.ssh/beryl_ax root@192.168.8.1 'cat > /root/dash_net_persist.sh && chmod +x /root/dash_net_persist.sh'
# boot hook (procd):
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 'cat > /etc/init.d/dash_net_persist <<EOF
#!/bin/sh /etc/rc.common
START=99
boot() { (/root/dash_net_persist.sh) & }
EOF
chmod +x /etc/init.d/dash_net_persist && /etc/init.d/dash_net_persist enable'
# cron:
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 'grep -q dash_net_persist /etc/crontabs/root || echo "*/5 * * * * /root/dash_net_persist.sh" >> /etc/crontabs/root; /etc/init.d/cron restart'
```

## `dash_link.html` → `/root/dash_link.html`
The floating "📊 Dashboard" button injected into the GL admin home page
(`/www/gl_home.html`, served at `http://192.168.8.1/`) linking to `/dash2.html`.
`position:fixed`, so it overlays the GL UI without interfering. `dash_net_persist.sh`
re-appends it whenever it's missing (firmware updates overwrite `gl_home.html`).

Initial install:
```sh
cat device/dash_link.html | ssh -i ~/.ssh/beryl_ax root@192.168.8.1 'cat > /root/dash_link.html'
# back up the original, then inject once (the persist hook keeps it thereafter):
ssh -i ~/.ssh/beryl_ax root@192.168.8.1 'cp /www/gl_home.html /www/gl_home.html.bak; grep -q /dash2.html /www/gl_home.html || cat /root/dash_link.html >> /www/gl_home.html'
```
Revert: `cp /www/gl_home.html.bak /www/gl_home.html` (and remove the persist block).
