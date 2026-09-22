# Cloudflare state that would otherwise exist only as API calls

DNS and tunnel config here were applied imperatively (API/MCP). These files record the
intended state so it is reviewable and reproducible.

| File | What it is |
|---|---|
| `records.tsv` | The records this workstream owns, with the zone id and why each is set the way it is |
| `tunnel-haven-vps.json` | Remote config for the `haven-vps` tunnel (ingress -> `127.0.0.1:3001` on the VPS) |

Applied with: `POST/PATCH /zones/{zone}/dns_records` and
`PUT /accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations`.

Why not a full provider: three records and one tunnel do not justify a Terraform stack. If
Cloudflare state grows past this, promote it to a provider — the files above are already the
desired-state input.

Two rules worth remembering, both learned by breaking them:

- **A tunnel route must be DNS-only with a real origin.** No Cloudflare proxy in front of a
  control plane (headscale): the protocol needs real TCP/TLS, so `proxied: false`.
- **A web origin behind a tunnel needs no certificate work at all** — which is why Haven uses
  a tunnel instead of fighting headscale for port 443.
