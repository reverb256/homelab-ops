# Making k3s-in-WSL stay alive — krash3 node liveness research + applied runbook

**Question:** Why does the k3s agent on krash3 (NixOS-WSL inside Windows 11) flap between Ready/NotReady, and what makes it stay alive permanently?
**As-of:** 2026-09-20 (research) · **Applied:** 2026-09-21 · **Audience:** j_kro + implementing agent (nexus-core) · **Status:** T0/T1/T2 **applied and verified live** on the Windows host; T3 (cluster-side watchdog) **not built**. Research was staged under kanban `t_4d73d3b9`.

> This file merges the two lines of work that were written independently on 2026-09-20/21: the
> research dossier (evidence chain, tiered fix package, sources) and the applied runbook (what was
> actually changed on the host, how it was verified, recovery commands). Both are kept whole —
> the design rationale and the measured outcome — rather than one overwriting the other.

## TL;DR

The distro is being **auto-shut-down by WSL itself**. `.wslconfig` carries no idle-timeout overrides, so WSL defaults apply: a WSL2 *instance* is killed ~8 seconds after the last user process ends (no matter that systemd/k3s run inside), and the *VM* 60 s after that. The only revival is the Windows task `NixOS-WSL-k3s-keepalive` firing **every 5 minutes** — so the node is up for seconds per 5-minute cycle, then dies again → "kubelet stopped posting node status" → NotReady flaps.

**Fix (2 lines in `%USERPROFILE%\.wslconfig` + 2 task/power tweaks):**
```ini
[general]
instanceIdleTimeout=-1

[wsl2]
networkingMode=mirrored
vmIdleTimeout=-1
```
Then `wsl --shutdown`, start the distro once, and the agent stays up until the Windows box itself reboots/sleeps. Remaining work = autostart-at-boot + no-sleep + an optional cluster-side watchdog (below).

## Topology (observed 2026-09-20)

| Item | Value |
|---|---|
| Windows box | krash3, Win 11 26200.9457, IP `10.1.1.150` (OpenSSH → PowerShell; user `j_kro`) |
| WSL | version **2.9.4.0**, kernel 6.18.35.2-1, distro `NixOS` (NixOS-WSL, hostname `nixos-wsl-krash3`) |
| `.wslconfig` | **only** `[wsl2] networkingMode=mirrored` — no timeout keys (see T0: the two timeout keys were added 2026-09-21) |
| k3s agent | enabled + active inside the distro (systemd); version v1.36.4+k3s1; cluster nodes otherwise v1.37.0 |
| Scheduled tasks (Windows) | `NixOS-WSL-k3s-autostart` (at logon) and `NixOS-WSL-k3s-keepalive` (every 5 min) — both run `wsl.exe -d NixOS -u root -- systemctl start k3s-agent` |
| Node capacity | 24 vCPU / ~15.6 GiB (WSL2 VM) |
| NixOS config (source) | `nixos-config/hosts/wsl-krash3/configuration.nix` (k3s + ComfyUI/RTX 4060) |

## Evidence chain

1. **Cluster side:** `describe node krash3` → `Ready=Unknown`, *"Kubelet stopped posting node status"*; events show Ready↔NotReady transitions minutes apart.
2. **Windows side:** `wsl -l -v` → `NixOS Stopped` while `vmmemWSL` lingers. Keepalive task = 5-minute cadence. When an interactive `wsl.exe` command (e.g. our SSH probe) runs, the distro boots, systemd starts k3s-agent, kubelet logs *"Fast updating node status as it just became ready"* — i.e. the node's liveness == "was someone poking WSL recently".
3. **Mechanism:** WSL2 kills an idle *instance* on a timer. Default `instanceIdleTimeout` = 8000 ms; default `vmIdleTimeout` = 60 000 ms (Microsoft docs + WSL issue tracker; see Sources). Microsoft's own systemd doc states: *"systemd services will NOT keep your WSL instance alive."* A 2.6.x regression (WSL#13416) made even actively-running systemd services stop counting; WSL 2.9.4 is past that version line.
4. **Consequence:** every 5-minute keepalive pulse buys roughly 8 seconds of agent uptime, unless another process holds the instance (interactive shell, VS Code, our probes). The 25-minute NotReady windows = periods with no successful poke (no interactive session, task hiccup, or box asleep).

## Why the current tasks can't fix it

`wsl.exe -d NixOS -u root -- systemctl start k3s-agent` is *revive-only*: the command exits, WSL sees no remaining user process, the instance idles out ~8 s later and takes kubelet with it. The task cadence (5 min) is far coarser than the shutdown timer (8 s), so uptime is ~0.03% of wall time in the worst case. It cannot be fixed by poking harder alone — the *timeout* is the bug.

## Fix package (tiered) — design, and what was applied

### T0 — stop the auto-shutdown (root fix) — **APPLIED 2026-09-21**
Edit `C:\Users\j_kro\.wslconfig`:
```ini
[general]
instanceIdleTimeout=-1

[wsl2]
networkingMode=mirrored
vmIdleTimeout=-1
```
Apply: `wsl --shutdown`, then `wsl -d NixOS -u root -- systemctl start k3s-agent` (or just open the distro once; systemd auto-starts k3s). Both keys are needed: `vmIdleTimeout=-1` alone still lets the *instance* die (microsoft/WSL#13291); `instanceIdleTimeout` requires ≥2.5.x (we run 2.9.4 ✓).
Tradeoff: `vmmemWSL` memory stays resident (currently ~275 MB idle; expect 1–3 GB with k3s + containerd; ComfyUI loads on demand).

**Applied as:** the file was written from the workspace by `copy_wslconfig.py`, which pipes it over SSH to
Windows, decodes base64 with PowerShell and writes the target path. Then `wsl --shutdown` (drop the old VM)
→ `wsl -d NixOS` (start the distro) → restart `k3s-agent`. After the restart the node returned `Ready` and
longhorn-manager recovered. (This file edits Windows-side behaviour only; it does not change the NixOS config.)

### T1 — harden the Windows tasks — **APPLIED 2026-09-21**
- `NixOS-WSL-k3s-keepalive` → keep as 5-min **watchdog** (command is idempotent). Optionally downgrade cadence to 10 min once T0 is proven.
- `NixOS-WSL-k3s-autostart` → add trigger **At startup** and enable **"Run whether user is logged on or not"** (stores credential so WSL starts without an interactive logon). Verify with `schtasks /query /tn <name> /v /fo LIST`.
- Fallback anchor for WSL regressions (if T0 ever stops holding): run `wsl.exe -d NixOS --exec <user-process that lives>` (the community-proven anchor is a user `dbus` daemon via `dbus-launch true`; microsoft/WSL#10138). Not needed while T0 holds.

**Applied as:** three tasks now exist under the `j_kro` account, all "run whether logged on or not":

| Task                          | Trigger(s)                  | Purpose                                  |
|-------------------------------|-----------------------------|------------------------------------------|
| `NixOS-WSL-k3s-autostart`     | At startup / at logon       | Start the NixOS-WSL distro on boot       |
| `NixOS-WSL-hold`              | At startup / logon / 5-min  | Hold the VM open so it never quiesces    |
| `NixOS-WSL-k3s-keepalive`     | 5-minute                    | Ping the distro to keep it warm          |

Verified with `Get-ScheduledTask ... | Format-List TaskName,State,Triggers` → boot triggers present
(startup), states Ready/Running.

### T2 — Windows power — **APPLIED 2026-09-21**
- `powercfg /change standby-timeout-ac 0` (+ `powercfg /h off` if hibernate unwanted): a sleeping box = dead node.
- After Windows Update reboots, T1's startup trigger restores the node unattended.

**Applied as:** `powercfg /change standby-timeout-ac 0` → Current AC power setting index `0x0` (never).
Prevents Windows suspend from stalling the WSL2 VM. (krash3 is plugged in 24/7.)

### T3 — cluster-side watchdog (defense in depth, optional but recommended) — **NOT BUILT**
nexus systemd timer (2-min): if `kubectl get node krash3` not Ready for >3 min → `ssh j_kro@10.1.1.150 "schtasks /run /tn NixOS-WSL-k3s-autostart"`. Catches task-scheduler hiccups, WSL crashes, and future regressions. (SSH to the Windows box already works from the cluster.)

### NixOS-side: longhorn binary symlinks (applied, persisted)
`krash3-fix-module.nix` adds `systemd.tmpfiles.rules` creating `/usr/bin/iscsiadm`,
`/usr/sbin/iscsiadm`, `/usr/bin/mount.nfs`, `/usr/sbin/mount.nfs` symlinks into
`/run/current-system/sw/bin/...`. longhorn-manager reaches these via nsenter into the
host mount namespace where the NixOS PATH isn't available. This is the module carried in the
homelab NixOS config (not ephemeral); re-run `nixos-rebuild switch` if the symlinks drift.

## Verification plan

1. After T0: `wsl --shutdown`; start distro once; close all terminals; wait 10 min → `wsl -l -v` must show `NixOS Running`.
2. `ssh j_kro@10.1.1.150 "wsl -d NixOS -u root -- systemctl is-active k3s-agent"` → `active` at the 10-min mark with zero user sessions.
3. Cluster: `kubectl get nodes -w` → krash3 `Ready` continuously ≥30 min; no Ready↔NotReady events.
4. Reboot the Windows box once (T1/T2 check): node returns with no manual action.
5. Node Ready from the cluster side:
   `kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get node krash3` → STATUS Ready.
6. kubelet posting fresh heartbeats:
   `kubectl get node krash3 -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}'`
   advances within the last ~5s.
7. longhorn-manager on krash3 healthy:
   `kubectl -n longhorn-system get pods -o wide | grep krash3` → `longhorn-manager-<x> 2/2 Running`
   and `longhorn-csi-plugin-<x> 3/3 Running`, plus instance-manager + engine-image.
8. Pods scheduled onto krash3:
   `kubectl get pods -A --field-selector spec.nodeName=krash3` → expected set
   (calico-node, csi-smb-node, metallb-speaker, node-exporter, longhorn engine/ims/csi).
   **Moot since 2026-09-22** — see "Later state" below: krash3 has left the cluster.
9. **10-min WSL watchdog** (the acceptance test — the instance must stay Running with zero user sessions):
   from the workspace: `bash watchdog_wsl.sh` → polls `wsl -l -v` +
   `systemctl is-active k3s-agent` + `who` at t=2,4,6,8,10 min.
   NixOS must read `Running` and `k3s-agent` `active` at every tick while `who` shows
   no interactive user sessions (only the keepalive's own root ssh session is acceptable;
   a stale human `pts` session should be cleared).
10. SSH note: management SSH to the Windows host 10.1.1.150 **MUST** use `-i ~/.ssh/id_ed25519_fleet`
    explicitly; the bare `ssh krash3` config selects a different key first and is rejected
    (the host accepts only the fleet key). `wsl -d NixOS -u root -- <cmd>` then runs commands
    inside the distro over the same SSH channel.

## Later state (2026-09-22)

krash3 **has left the cluster**: `kubectl get node krash3` → `NotFound`, and no pods are scheduled on it
(the cluster is now forge / nexus / sentry-agent, with zephyr `Ready,SchedulingDisabled`).

Two consequences for this runbook:

- Verification steps that assert pods *on* krash3 (step 8 above) are retained only as the historical
  acceptance test; they no longer describe the current cluster.
- The pod-reachability half of the krash3 problem was measured separately and is documented in
  `runbooks/krash3-pod-reachability-2026-09-22.md`: pod-IP targets on krash3 were never reachable from
  other nodes (a Calico-overlay limit, not a firewall problem), which is why node-IP scraping worked while
  pod-IP scraping did not. Node liveness (this file) and pod reachability (that file) are distinct defects —
  the WSL idle-eviction fix here is what makes the agent stay up; it does not make the overlay route.

## Risks / open questions

- **vmmemWSL residency** on a 15.6 GiB VM — acceptable for a cluster node; use `.wslconfig [wsl2] memory=` cap if the Windows side needs headroom.
- **Windows sleep/hibernate** still kills the node — T2 required, not optional, for a "always-on" claim. (Now applied.)
- Whether the keepalive task's "Last Run" (queried as 1999-11-30 = never) is accurate is unverified; T0 does not depend on it.
- WSL auto-update regressions (see #13416 precedent) — T3 is the durable safety net. **T3 is still unbuilt**, so a future WSL regression would only be caught by the keepalive cadence at best.
- **Version skew:** krash3 agent = v1.36.4+k3s1 while the control-plane nodes (nexus/forge/sentry-agent) run v1.37.0+k3s1. This is within the k8s supported skew (agent may be N-1) and is **not** causal to the incident, but should be eliminated on the next maintenance window by rebuilding the NixOS-WSL k3s-agent module with the v1.37.0 package, since longhorn-manager and the CSI plugin are version-aligned with v1.37 expectations. (Moot while krash3 is out of the cluster; applies if it returns.)

## Recovery commands (cheat sheet)

```
# write .wslconfig from scratch on this host
python3 copy_wslconfig.py

# restart WSL + k3s-agent after a .wslconfig change
ssh -i ~/.ssh/id_ed25519_fleet j_kro@10.1.1.150 \
  'wsl --shutdown && wsl -d NixOS -n && wsl -d NixOS -u root -- systemctl restart k3s-agent'

# quick status checks
ssh -i ~/.ssh/id_ed25519_fleet j_kro@10.1.1.150 'wsl -l -v'
ssh -i ~/.ssh/id_ed25519_fleet j_kro@10.1.1.150 'wsl -d NixOS -u root -- systemctl status k3s-agent --no-pager'
```

## Sources (retrieved 2026-09-20)

- Microsoft Learn — Advanced settings (.wslconfig): `vmIdleTimeout` semantics — https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- MicrosoftDocs WSL — systemd: "systemd services will NOT keep your WSL instance alive" — https://learn.microsoft.com/en-us/windows/wsl/systemd
- microsoft/WSL #10138 — "How to make wsl2 alive in the background" (`vmIdleTimeout=-1`, `dbus-launch true` keep-alive, scheduled-task recipes) — https://github.com/microsoft/WSL/issues/10138
- microsoft/WSL #13291 — `instanceIdleTimeout=-1` required in addition to `vmIdleTimeout` (WSL ≥2.5.7) — https://github.com/microsoft/WSL/issues/13291
- microsoft/WSL #13416 — regression: instance shuts down despite active systemd service (2.6.x) — https://github.com/microsoft/WSL/issues/13416
- microsoft/WSL #10157 — 8-second instance shutdown is intentional design — https://github.com/microsoft/WSL/issues/10157
- GreenGorych — WSL timeout reference (defaults: instanceIdleTimeout 8000, vmIdleTimeout 60000) — https://greengorych.io/blog/wsl-timeouts-whats-the-difference-and-how-to-use-them/
- NixOS Wiki — WSL: run distro at Windows startup (task-scheduler recipe) — https://wiki.nixos.org/wiki/WSL
