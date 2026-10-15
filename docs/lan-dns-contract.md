# LAN DNS contract: router DHCP + fleet resolvers (t_40262b43)

Operational date: 2026-10-15. All evidence below was measured live on the fleet.

## The contract (one line)

Every client on the LAN — DHCP client, static host, or cluster pod — gets this
resolver order:

```
10.1.1.53   Pi-hole (MetalLB VIP, svc pihole-dns, ns pihole)   — filters + .lan
10.1.1.100  unbound keepalived VIP (nexus MASTER, sentry BACKUP) — .lan SoT, failover
10.1.1.120  nexus unbound (node IP, independent of the VIP)      — .lan SoT, failover
```

Failover guarantee (the point of this task): **no client may ever have Pi-hole
as its ONLY resolver.** A Pi-hole outage must degrade the LAN to UNFILTERED
DNS, never to no DNS. systemd-resolved never uses `FallbackDNS` while any
primary `DNS=` is set, so the secondaries must be LIVE primaries in the `DNS=`
line itself, not `FallbackDNS` entries.

## What is already live (do not redo)

- All four Linux hosts carry the triad in `DNS=` with public `FallbackDNS`
  (landed by t_d47a5575, homelab-ops commit 5cdbecf; per-host drop-ins under
  `omarchy/<host>/etc/systemd/resolved.conf.d/50-pihole.conf`).
- Hosts are Omarchy desktops: `omarchy-dns` owns the main resolved.conf + NM
  layers on zephyr/sentry. Do not fight it with a `DNS=` drop-in there — the
  drop-in carries only `Domains=~.` + `FallbackDNS` on those two.
- k3s pods resolve via `/etc/rancher/k3s/resolv.conf` -> Pi-hole ClusterIP
  (check: `scripts/verify/k3s-resolv-conf.sh`).

## Known behaviors you must re-check after any DNS change

1. **resolved pins to the failover server.** After a Pi-hole outage,
   systemd-resolved keeps using the first server that answered (unbound) and
   does NOT return to Pi-hole on its own (systemd issues #5755, #25020 —
   upstream WONTFIX). Symptom: `Current DNS Server: 10.1.1.100` while Pi-hole
   is healthy again, and the host is silently UNFILTERED.
   Fix: `sudo systemctl restart systemd-resolved` then
   `sudo resolvectl flush-caches`, then verify
   `Current DNS Server: 10.1.1.53` and `getent ahostsv4 doubleclick.net`
   returns `0.0.0.0`. NOTE: restarting resolved makes tailscaled re-assert
   MagicDNS claims on tailscale0 — the pihole-dns-trim timer (nexus/sentry)
   re-trims within 30s; re-check `resolvectl domain tailscale0` after.
2. **After EVERY per-host network/DNS change, prove connectivity before
   calling the host done** (incident 2026-10-15 07:54: an agent left zephyr's
   wired connection `down`, WAN was gone, both miners idle at 0 TH/s for 1h):
   - `ip route show default` — a default route must exist on the intended
     interface (enp38s0/eno1/enp7s0), metric < any wifi route;
   - WAN probe: `ping -c1 -W3 1.1.1.1` (or a TCP connect);
   - mining pool: `timeout 5 bash -c 'exec 3<>/dev/tcp/prl-us.kryptex.network/7048'`.
   Never `nmcli connection down` — use `nmcli device reapply` or `con up`.
3. **zephyr's KDS wifi is NOT redundancy.** With the wired link up, KDS passes
   no traffic (`ping -I wlo1` 100% loss, measured 2026-10-15). It currently
   holds a default route (metric 600) and steals traffic when wired drops.
   Correct posture: `nmcli con mod KDS ipv4.never-default yes` so it can never
   be the default route (fix its AP-side upstream before re-enabling).
4. **MagicDNS must never own `lan` or `~.` on tailscale0** (nexus/sentry):
   `~.` spreads queries across default-route links (canary flap, Pi-hole
   bypass); `lan` sends *.lan to MagicDNS which NXDOMAINs them — sentry could
   not resolve `nexus.lan` while unbound/Pi-hole answered it fine. Trim keeps
   ONLY `tigris-ule.ts.net` + `resolvectl default-route tailscale0 no`.
   (Coordination: the pihole-dns-trim timer currently re-asserts ts.net+lan —
   see kanban t_d47a5575 comment 280 for the correction handoff.)

## The router: DHCP option 6 for j_kro to apply (10.1.1.1)

**Do not change the router yourself — these are the steps for j_kro.**
Router: Shaw gateway at 10.1.1.1 (MAC 40:0f:c1:bf:42:f7, Technicolor OUI —
BlueCurve-class). SSH is not open on it; the change is in its web UI.

Evidence for the change: the router's DHCP option 6 hands out the ISP
resolvers `64.59.176.16 64.59.176.228` (measured from zephyr's lease,
2026-10-14). They answer public names but cannot answer `*.lan` and do no
filtering — every DHCP client (phones, TVs, guests) bypasses Pi-hole today.

Steps (Shaw BlueCurve / Technicolor UI path):

1. Browse to `http://10.1.1.1` and log in as admin (credential on the modem
   label or in the vault; "Connection" section).
2. Gateway -> Connection -> LAN -> DHCP (or "Home Networking" -> DHCP).
3. Under DNS servers / "Manual DNS configuration", set:
   - Primary: `10.1.1.53`
   - Secondary: `10.1.1.100`
   Leave tertiary empty if the UI only offers two (never set the ISP
   resolvers as tertiary — a client that fails over to them loses .lan and
   filtering silently).
4. Save/Apply. The router usually restarts its DHCP service only (not the
   whole modem) — but if the modem reboots, expect the LAN to blip ~2 min.
5. Verify from a DHCP client (phone/laptop, not a fleet host):
   - Release/renew the lease (toggle wifi off/on).
   - Confirm the new lease: `nslookup google.com` shows server `10.1.1.53`.
   - Confirm filtering: browse to `doubleclick.net` — should be blocked /
     `nslookup doubleclick.net` -> `0.0.0.0`.
   - Confirm .lan: `nslookup nexus.lan` -> `10.1.1.120`.
6. Leave the fleet hosts' static triad as-is (they already point at all three
   resolvers; DHCP changes do not affect them).

Rollback: set the DNS fields back to "Automatic" in the same panel.

Why this order (.53 then .100, no ISP resolvers in the list):
- .53 first = filtering + .lan for every client;
- .100 second = live secondary on a keepalived VIP (nexus/sentry failover),
  answers .lan from unbound's local-data, unfiltered public recursion;
- ISP resolvers would be a third class of behavior (no .lan, no filtering) —
  a client that lands on them gets silent breakage, which is worse than
  unfiltered-but-working.

Alternative (if j_kro prefers Pi-hole to serve DHCP too): not recommended —
Pi-hole DHCP needs `hostNetwork: true` + port 67 exposed, and the 2026-10-14
incident showed a Pi-hole pod restart already risks the LAN's DNS; making it
the DHCP server couples lease lifetime to pod lifetime too. Keep DHCP on the
router, DNS on the fleet.

## Verification (run from any host, read-only)

```bash
# triad live + Pi-hole preferred on every host
for h in zephyr nexus forge sentry; do ssh $h resolvectl | head -8; done
# filtered canary + working public + .lan on every host
for h in zephyr nexus forge sentry; do
  ssh $h getent ahostsv4 doubleclick.net | head -1   # 0.0.0.0
  ssh $h getent ahostsv4 github.com | head -1        # real IP
  ssh $h getent ahostsv4 nexus.lan | head -1         # 10.1.1.120
done
```

Fleet-wide regression check: `scripts/verify/lan-dns-contract.sh` (new,
homelab-ops) — asserts per host: triad config, Current DNS Server = 10.1.1.53,
canary filtered, public + .lan resolve, default route present, WAN + pool
TCP reachable. Exit 0 only when every assertion passes on all four hosts.
