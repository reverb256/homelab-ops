# sentry — gitlawb node backup (source of truth)

Daily backup of the gitlawb node on sentry (`/srv/gitlawb`: Postgres metadata,
bare repos, node identity) to `nexus:~/backups/gitlawb/`.

**Status: to be applied + verified (see Verification below after first run).**

## Layout

| Path | Installs to | Purpose |
|------|-------------|---------|
| `bin/gitlawb-backup` | `/usr/local/bin/gitlawb-backup` | the backup script (dump, tar, ship, verify, rotate) |
| `systemd/gitlawb-backup.service` | `/etc/systemd/system/` | oneshot unit, runs as `j_kro` |
| `systemd/gitlawb-backup.timer` | `/etc/systemd/system/` | daily 04:30, persistent |

## Apply

```sh
./apply.sh            # idempotent; needs passwordless sudo on sentry
./apply.sh --check    # show what would change
```

Never hand-edit the live files on sentry: edit here, commit, re-apply.

## Why nexus and not garage S3

The memlawb pattern (nexus → garage) reads credentials from garage's local admin
socket, which only exists on nexus. Sentry is remote, so this script ships
artifacts to `nexus:~/backups/gitlawb/` (the same destination already used for
`gh-mirrors`). Moving to S3 later only changes step 4 of the script.

## Verification

```sh
systemctl start gitlawb-backup.service   # one manual run
journalctl -u gitlawb-backup -n 20
ssh nexus 'ls -la ~/backups/gitlawb/'    # expect pg-<stamp>.sql.gz + data-<stamp>.tar.gz
```

The script refuses empty artifacts and verifies destination byte counts, so a
successful exit plus `gitlawb backup ok:` in the journal is the acceptance bar.

## Rollback

```sh
systemctl disable --now gitlawb-backup.timer
rm /etc/systemd/system/gitlawb-backup.{service,timer} /usr/local/bin/gitlawb-backup
systemctl daemon-reload
```
