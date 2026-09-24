# Zephyr service migration — plan (2026-09-24)

**Goal:** move the two user-scope services that run on zephyr (the workstation) to a
server host. Standing rule: nothing may be hosted on zephyr; violations migrate off.

## What is running there now

| unit | scope | state | what it does |
|---|---|---|---|
| `hermes-gateway.service` | user | **active** | Messaging platform integration (the live chat bridge) |
| `hermes-nous-proxy.service` | user | **active** | Nous OpenAI-compatible proxy on :8899 for pipelines |
| `home-j_kro-.hermes-skills\x2dnexus.mount` | user | **mounted** | sshfs of `nexus:/data/hermes/skills` |

No `hermes-gateway` exists on any other host (checked nexus, forge, sentry), so these
are the only copies and the violation is real.

## Why this is not a copy-paste migration

Both units execute from a **zephyr-specific Hermes install**:

```
ExecStart=/home/j_kro/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main ...
```

- **nexus has no `~/.hermes/hermes-agent/venv`** — its Hermes is `/usr/bin/hermes`
  (a package install). Copying the units verbatim would crash-loop on a missing binary.
- **nexus's `~/.hermes/.env` has 0 messaging-token matches** — the gateway's credentials
  live in zephyr's env and in the sops store. The gateway cannot start without them.
- The gateway is the **live messaging bridge**, so the cutover is user-visible: it needs a
  window where a brief disconnect is acceptable, and a rollback (the zephyr units stay
  installed but stopped until the new host is verified).

## Decision required before executing

**Where should the gateway live?** The architecture doc says sentry is the control plane
and nexus is cluster ops; a messaging bridge fits neither cleanly. Options:

1. **nexus** — alongside the ops stack, closest to the pipelines that use :8899.
2. **sentry** — the control-plane host, which already runs Hermes profiles for
   site-agency and software-factory.

This is a placement/policy decision, not a technical blocker.

## Execution outline (once placed)

1. Install the Hermes venv on the target (or repoint ExecStart at that host's install).
2. Provision the gateway tokens from the sops store into the target's env
   (`sops-hermes-env-sync.sh` already does this pattern; run it on the target).
3. Stage the units in `homelab-ops` (they are hand-placed today) with the correct paths.
4. Cutover: stop on zephyr → start on target → verify the bridge reconnects → only then
   `disable` the zephyr units. Keep them installed for rollback until verified.
5. Verify from the outside: a real message through the bridge, not just an active unit.

## The sshfs skills mount — recommendation: KEEP, with reasoning

`~/.hermes/skills-nexus` mounts nexus's canonical skills read-only-in-practice (rw mount,
but the data lives on nexus). Removing it would leave zephyr's Hermes without the skill
library; the alternative — copying the skills onto zephyr — violates the standing rule
*harder*, because it puts a second copy of the state on the workstation. A live read of
the canonical copy is the least-bad option and hosts nothing on zephyr. Flagging it rather
than silently changing it, since it was listed as a violation.
