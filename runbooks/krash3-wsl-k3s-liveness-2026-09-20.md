# Making k3s-in-WSL stay alive — krash3 node liveness research

**Question:** Why does the k3s agent on krash3 (NixOS-WSL inside Windows 11) flap between Ready/NotReady, and what makes it stay alive permanently?
**As-of:** 2026-09-20 · **Audience:** j_kro + implementing agent (nexus-core) · **Status:** researched, fix staged (not yet applied — kanban `t_4d73d3b9`)

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
| `.wslconfig` | **only** `[wsl2] networkingMode=mirrored` — no timeout keys |
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

## Fix package (tiered)

### T0 — stop the auto-shutdown (root fix)
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

### T1 — harden the Windows tasks
- `NixOS-WSL-k3s-keepalive` → keep as 5-min **watchdog** (command is idempotent). Optionally downgrade cadence to 10 min once T0 is proven.
- `NixOS-WSL-k3s-autostart` → add trigger **At startup** and enable **"Run whether user is logged on or not"** (stores credential so WSL starts without an interactive logon). Verify with `schtasks /query /tn <name> /v /fo LIST`.
- Fallback anchor for WSL regressions (if T0 ever stops holding): run `wsl.exe -d NixOS --exec <user-process that lives>` (the community-proven anchor is a user `dbus` daemon via `dbus-launch true`; microsoft/WSL#10138). Not needed while T0 holds.

### T2 — Windows power
- `powercfg /change standby-timeout-ac 0` (+ `powercfg /h off` if hibernate unwanted): a sleeping box = dead node.
- After Windows Update reboots, T1's startup trigger restores the node unattended.

### T3 — cluster-side watchdog (defense in depth, optional but recommended)
nexus systemd timer (2-min): if `kubectl get node krash3` not Ready for >3 min → `ssh j_kro@10.1.1.150 "schtasks /run /tn NixOS-WSL-k3s-autostart"`. Catches task-scheduler hiccups, WSL crashes, and future regressions. (SSH to the Windows box already works from the cluster.)

## Verification plan

1. After T0: `wsl --shutdown`; start distro once; close all terminals; wait 10 min → `wsl -l -v` must show `NixOS Running`.
2. `ssh j_kro@10.1.1.150 "wsl -d NixOS -u root -- systemctl is-active k3s-agent"` → `active` at the 10-min mark with zero user sessions.
3. Cluster: `kubectl get nodes -w` → krash3 `Ready` continuously ≥30 min; no Ready↔NotReady events.
4. Reboot the Windows box once (T1/T2 check): node returns with no manual action.

## Risks / open questions

- **vmmemWSL residency** on a 15.6 GiB VM — acceptable for a cluster node; use `.wslconfig [wsl2] memory=` cap if the Windows side needs headroom.
- **Windows sleep/hibernate** still kills the node — T2 required, not optional, for a "always-on" claim.
- Whether the keepalive task's "Last Run" (queried as 1999-11-30 = never) is accurate is unverified; T0 does not depend on it.
- WSL auto-update regressions (see #13416 precedent) — T3 is the durable safety net.
- Version skew: node runs k3s v1.36.4 while the cluster is v1.37.0 — harmless for now; fold into the next maintenance window.

## Sources (retrieved 2026-09-20)

- Microsoft Learn — Advanced settings (.wslconfig): `vmIdleTimeout` semantics — https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- MicrosoftDocs WSL — systemd: "systemd services will NOT keep your WSL instance alive" — https://learn.microsoft.com/en-us/windows/wsl/systemd
- microsoft/WSL #10138 — "How to make wsl2 alive in the background" (`vmIdleTimeout=-1`, `dbus-launch true` keep-alive, scheduled-task recipes) — https://github.com/microsoft/WSL/issues/10138
- microsoft/WSL #13291 — `instanceIdleTimeout=-1` required in addition to `vmIdleTimeout` (WSL ≥2.5.7) — https://github.com/microsoft/WSL/issues/13291
- microsoft/WSL #13416 — regression: instance shuts down despite active systemd service (2.6.x) — https://github.com/microsoft/WSL/issues/13416
- microsoft/WSL #10157 — 8-second instance shutdown is intentional design — https://github.com/microsoft/WSL/issues/10157
- GreenGorych — WSL timeout reference (defaults: instanceIdleTimeout 8000, vmIdleTimeout 60000) — https://greengorych.io/blog/wsl-timeouts-whats-the-difference-and-how-to-use-them/
- NixOS Wiki — WSL: run distro at Windows startup (task-scheduler recipe) — https://wiki.nixos.org/wiki/WSL
