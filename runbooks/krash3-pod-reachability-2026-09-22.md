# Making krash3's pods reachable — measured cause and fix

**Question:** hosts and other nodes cannot reach pods scheduled on krash3. What is actually broken, and
what fixes it?
**As-of:** 2026-09-22 · **Audience:** j_kro + implementing agent · **Status:** researched, fix not yet
applied

## TL;DR

krash3's k3s is healthy and its pods ARE reachable from pods. What fails is **host-originated traffic to
the pod IPs**, and the cause is **WSL2 mirrored networking**, not krash3. Packet capture inside the pod
showed the SYN **never arrives** — the drop happens in the Windows/WSL layer before the VM.

The fix is **not** a CNI change. It is to stop depending on WSL's L2/L3 forwarding: make krash3 a
**tailnet subnet router** advertising its pod block (`192.168.21.0/26`). Traffic then arrives over
WireGuard, which WSL already carries fine, and the router does the last hop inside the VM where pod
routing works.

## Measurements (2026-09-22, all repeated)

| From | To | Result |
|---|---|---|
| pod on nexus | pod on krash3 (`192.168.21.91:8899`) | **HTTP 200, 2 ms** |
| pod on krash3 | internet (`haven.reverb256.dev`) | **HTTP 200, 0.26 s** |
| host nexus / sentry / forge / zephyr | pod on krash3 | **timeout, 8.00 s — all four** |
| tcpdump INSIDE the krash3 pod during a host curl | — | **captured nothing** |

The empty capture is the decisive one: the packet is dropped **before** the pod, in the Windows/WSL path.

## Why VXLAN/IPIP would NOT fix this (correction to an earlier claim)

Calico encapsulation applies to **pod-originated** traffic. Host-originated packets to a pod IP are
never encapsulated by Calico, so switching the IPPool to `vxlanMode: Always` would not restore the
host->pod path. It would only change how node-to-node pod traffic is wrapped — and that path already
works here. Do not make a cluster-wide encapsulation change expecting this to fix it.

## Corroborating upstream issues

- microsoft/WSL **#12548** — in mirrored mode WSL creates the subnet route **without a `src`**, e.g.
  `10.1.1.0/24 dev eth0 proto kernel scope link metric 281` (real Debian prints `... scope link src ...`).
  Confirmed identical on this VM. Pinning `src` changed the route but **did not** restore host->pod, so
  this is a real defect but not the operative one here.
- microsoft/WSL **#11034** — connection matrix showing mirrored mode does not support several
  host->WSL and VM->WSL combinations.
- tigera/operator **#2340** — changing `Installation.spec.ipPools.encapsulation` after install is not
  reliably applied; the IPPool object itself is the lever.

## The fix: krash3 as a tailnet subnet router

Tailscale's subnet router is designed exactly for "devices that cannot run the client" and routes
respect the tailnet ACLs. Tailscale SNATs subnet traffic to the router by default, which also removes any
question of the pod's IP being an invalid source on the wire.

On **krash3, inside the WSL distro** (kernel TUN is required — WSL2's kernel has `/dev/net/tun`;
userspace networking CANNOT act as a subnet router):

    # SaaS tailnet (the fleet is already on it; nexus/forge/zephyr)
    sudo tailscale up --advertise-routes=192.168.21.0/26 --accept-dns=false

    # ...or Headscale, when the fleet cuts over
    sudo tailscale up --login-server=https://headscale.reverb256.dev \
         --advertise-routes=192.168.21.0/26 --accept-dns=false

Approve the route:

- SaaS: the Tailscale admin console (Machines -> krash3 -> Subnet routes), or an ACL autoApprover.
- Headscale: `headscale routes enable -r <id>` (list with `headscale routes list`), or configure
  `autoApprovers.routes` in the policy so approval needs no manual step.

Clients need `--accept-routes`. **nexus already has RouteAll=true**, so it will use the route with no
change. Verify from a tailnet member:

    curl -s -m 8 -o /dev/null -w '%{http_code}\n' http://192.168.21.91:8899/   # expect 200

## Why this is the right shape

- It needs **no change to WSL networking**, no CNI change, and no cluster-wide disruption.
- It survives the Headscale migration unchanged — only the login server differs.
- The pod block belongs to krash3 alone, so advertising it is scoped and revocable.
- It also makes krash3's pods reachable from phones/laptops on the tailnet, not just the fleet.

## Open questions to settle at implementation time

1. Does kernel-mode tailscaled inside this WSL distro establish and route cleanly under mirrored mode?
   Check `tailscale status` shows `active; direct` and that `--advertise-routes` is accepted.
2. Route approval on the SaaS tailnet is a console step; decide whether to add an ACL autoApprover so
   this stays declarative (the Headscale path can use `autoApprovers` in policy).
3. Confirm no overlap: krash3 owns `192.168.21.0/26`; ensure no other node advertises the same block.

## Not needed, for the record

In-cluster reachability to krash3 **already works** (pod-to-pod, kubelet metrics, the API server). The
failures that prompted this were host-originated. `kubectl port-forward` also works regardless, because
the kubelet makes that connection locally.
