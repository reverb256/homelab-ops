# k3s etcd on the fast tier (2026-09-24)

`/var/lib/rancher/k3s/server/db/etcd` is a bind mount onto `/data/fast/k3s/etcd`
(the EVO). This is the cure for the 2026-09-24 quorum loss: nexus etcd stalled
11 minutes on the fragile LUKS2+SN550 root fs, k3s self-killed, sentry was down
too, and only forge remained - no quorum.

Both units are required and depend on `/data/fast`:

- `var-lib-rancher-k3s-server-db-etcd.mount` - the bind mount itself
- `k3s.service.d/30-etcd-fasttier.conf` - `RequiresMountsFor` so k3s never starts
  against an unmounted path (an empty etcd would be catastrophic)

Rollback: `umount /var/lib/rancher/k3s/server/db/etcd` + restore
`etcd.pre-fasttier` (preserved, 439M) + remove the drop-in. The pre-move etcd
snapshot is `pre-fasttier-nexus-1790276796.zip`.

The k3s unit itself is NOT tracked here: it carries the etcd-backup S3 secret in
its ExecStart line. FOLLOW-UP: move that credential to a 0600 EnvironmentFile and
reference `${VAR}` from ExecStart, so the unit can be tracked safely. The key was
rotated on 2026-09-24 (the previous one had leaked into backups and status output).
