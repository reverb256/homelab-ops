# hermes-nous-proxy on sentry (moved 2026-09-24)

A local HTTP server that forwards OpenAI-compatible requests to the OAuth-authenticated
Nous Portal. Callers send ANY bearer token; the proxy discards it and attaches the real
OAuth session. That is the tool's design, and it is why this MUST stay bound to
127.0.0.1: it does not authenticate callers, so anything that can reach the port spends
the Nous quota.

Moved from zephyr (the workstation) to sentry, where the pipelines that consume it run.
On zephyr it could never serve them: it was bound to localhost and the consumers are not
local. sentry already had the `nous` provider in its auth.json, so no credential copy was
needed. Verify with `hermes proxy status` - the upstream must read "ready".

Rollback: the zephyr unit is still installed but disabled; `systemctl --user enable --now
hermes-nous-proxy` there restores the old location.
