# stale-reaper — kill processes whose job is over

Bots launch Hermes jobs with `nohup` or `systemd-run`. The helpers those jobs
start — pyright, MCP servers, Unity, VRoid/wine, Blender, headless Chromium —
**outlive the job**. They sit in `systemd --user` with no owner, holding RAM for
days.

On 2026-10-22 at 23:46 this class of leftover crashed zephyr's desktop session.

Two pieces fix it:

1. `bin/stale-reaper` — a 15-minute reaper that kills only unambiguous orphans.
2. `bin/hermes-job` — a launcher that puts a job and every helper in one cgroup,
   so the kernel kills the helpers when the job ends. This fixes the source.

## stale-reaper

```
stale-reaper [--dry-run] [--json] [--verbose]
```

`--dry-run` prints what it would kill and changes nothing. `--json` implies
`--dry-run` and prints one object per candidate.

### Decision order

Every rule below is evaluated in this order. The first match wins.

1. **Protected set.** The reaper itself, its ancestors, and every process whose
   pid is in `~/.hermes/locks/*.lock.d/holder`.
2. **Denylist.** Matched against the full cmdline. See the list below.
3. **Keep file.** `~/.config/stale-reaper/keep`, one extended regex per line,
   `#` comments. A match protects the process **and its whole tree**.
4. **Detached browser daemons.** `browser_harness.daemon` is never a target. It
   detaches to `systemd --user` on purpose, so it always *looks* orphaned while
   it is live. It costs ~4 MB.
5. **Active unit.** A process inside a *running* `systemd --user` unit is part of
   a live job and is never a target. This is what stops the reaper from eating a
   running Hermes job whose MainPID has `ppid=1` and whose tree is full of
   allowlisted helpers.
6. **TTY.** Anything attached to a terminal is never touched.

Then, for survivors:

| Rule | Condition | Action |
|---|---|---|
| A. orphaned helper | parent is PID 1 or `systemd --user`, cmdline is a helper class, age > 30 min, no TTY | SIGTERM the tree, SIGKILL after 15 s |
| B. idle long job | `hermes ... -z`, age > 12 h, lifetime-average CPU < 1 % | same |
| C. dead units | failed `systemd --user` units; transient `run-*`/`hermes-*` units with no MainPID | `stop`, `reset-failed` |

Helper classes: `pyright-server`, MCP servers (`npm exec`, `node_modules/.bin/mcp`,
`mcp-for-unity`, `mcp-for-blender`, `comfyui_mcp_server`, `obsidian-mcp`,
`argocd-mcp`), `python3 -m http.server`, VRoid Studio, Unity/`VBCSCompiler`,
`blender -b`, `hermes_kernel`.

Two more cases are handled because they are how these helpers really appear:

- **Headless browser trees.** A `chromium`/`playwright` tree is a target only when
  something in the tree carries `--headless`. An interactive browser never matches.
- **Leftover shell wrappers.** An orphaned `bash -lc/-lic/-c` whose tree contains a
  helper above (or a headless browser) is reaped as `wrapped-<class>`. This is the
  `bash -lic ... && chromium` shape that bot jobs leave behind.

A helper that still **listens** on a TCP port is skipped for the classes where the
port *is* the service (`http.server`, MCP, pyright). Those need a human decision.

### Never killed (denylist)

miners (`peakminer`, `xmrig`, `srbminer`, …), the whole k3s stack (`k3s`,
`containerd`, `kubelet`, `calico`, `csi-*`, `flannel`, `etcd`), `computer.service`,
`hermes-gateway`, interactive Hermes TUIs (`tui_gateway`, `ui-tui`, `entry.js`), the
ComfyUI server (`main.py --listen`), the desktop session (Hyprland, quickshell,
waybar, Xvfb, openbox, uwsm), Grok Bot, ssh/tmux, system daemons, and any
`hermes-svc-lock` holder.

`Xvfb` and `openbox` are denied on purpose: GUI jobs share `DISPLAY=:99`.

### Logging

Every decision goes to journald with the tag `stale-reaper`:

```
journalctl -t stale-reaper -n 50
```

Each kill records pid, class, age, process count, RSS and the cmdline (truncated).

### Keep file

```
# ~/.config/stale-reaper/keep — one regex per line
^/usr/bin/blender .*/projects/commission-2026
MEDIA_BROWSER_PROFILE=/home/j_kro/.config/chromium
```

## hermes-job

```
hermes-job <name> <taskfile> [max-hours]     # default 6
```

Runs `hermes --provider opencode-go -m deepseek-v4.1-flash -z "$(cat <taskfile>)"`
inside a transient unit `hermes-<name>` with:

- `KillMode=control-group` — every helper dies with the job;
- `RuntimeMaxSec=<max-hours>h` — the job cannot run forever;
- `TimeoutStopSec=20`, `SendSIGKILL=yes` — a stubborn helper still dies;
- `--collect` — no unit litter after exit.

Log: `<taskfile>.log`, next to the task file. Follow:
`journalctl --user -u hermes-<name> -f`.

Override the model with `HERMES_JOB_PROVIDER` / `HERMES_JOB_MODEL`.

Do not use `nohup hermes -z`. That is what creates the orphans.

## Install

```bash
bash omarchy/fleet/install-stale-reaper.sh          # on each host
bash omarchy/fleet/install-stale-reaper.sh --dry-run
```

It installs both scripts to `~/.local/bin`, installs the unit and timer to
`~/.config/systemd/user`, creates an empty keep file, enables the timer, and
verifies that linger is on. Linger must be on, or the timer dies with the last
login session.

The timer runs 10 minutes after boot, then every 15 minutes.

## Verify

```bash
systemctl --user list-timers stale-reaper.timer
stale-reaper --dry-run            # never kills
journalctl -t stale-reaper -n 20
```

Tests: `bash tests/test-stale-reaper.sh` — no root, no real units left behind.

## Rules for changing this tool

- Add a class only when the helper **cannot** be doing useful work once its parent
  job is gone. `browser_harness.daemon` taught that lesson.
- A new class needs a test in `tests/test-stale-reaper.sh`.
- `STALE_REAPER_ORPHAN_PPIDS` **replaces** the default orphan set. Never make it
  additive: a test that inherits "everything under `systemd --user`" with the age
  floor at zero reaps the live host.
