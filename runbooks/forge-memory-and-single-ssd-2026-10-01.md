# forge memory pressure + the single-SSD hazard (2026-10-01 incident)

Status: **decisions recorded, host changes NOT executed.** Every host change below
needs j_kro's signature — see "Why this is not done yet".

Scope: this is the follow-up card `t_56d315ce` for INCIDENT `t_a3a44f39` (forge
wedged 2026-10-01 20:38 CDT, hard power cycle 23:14 CDT). It is the third time
the same device-sharing hazard has been named: `control-plane-io-stall-2026-09-22.md`
named it first, this incident is its second confirmed occurrence, and the swap
question was already open there.

Everything with a number below was read out of VictoriaMetrics, `/proc/swaps`,
`lsblk`, `du` or `journalctl` on the hosts. Nothing here is inferred.

---

## 1. The corrected swap picture

The incident write-up says "30.9 GiB of swap ... swap joined that device". The
first half is right, the second half is only half right. `node_memory_SwapTotal_bytes
{instance="10.1.1.130:9100"}` reads **30.94 GiB**, which is TWO devices added
together, measured on forge:

```
$ cat /proc/swaps
Filename                                Type            Size            Used    Priority
/swap/swapfile                          file            16224856        0       0
/dev/zram0                              partition       16223228        592024  100

$ lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
sda      223.6G
|-sda1       8G swap                       <-- formatted as swap, NOT active
`-sda2   215.6G btrfs   /mnt/oldforge
sdb      238.5G
|-sdb1       2G vfat    /boot
`-sdb2   236.5G crypto_LUKS
  `-root 236.5G btrfs   /                   <-- /dev/mapper/root = LUKS(sdb2)
zram0     15.5G swap    [SWAP]
```

| swap device | size | backing | active | shares the LUKS SSD? |
|---|---|---|---|---|
| `/dev/zram0` | 15.47 GiB | **RAM**, zstd, priority 100 | yes (~0.6 GiB used, ~99 MiB of real RAM) | no |
| `/swap/swapfile` | 15.47 GiB | btrfs file on `/dev/mapper/root` | yes, priority 0, **0 used** | **yes — same device as etcd WAL, containerd and journald** |
| `/dev/sda1` | 8 GiB | swap partition on the other disk | **no** | no |

Two consequences the original write-up got the wrong way round:

1. **The high page rates were mostly zram, not the SSD.** zram sits at priority
   100, so the kernel drains it before touching the file. The measured
   5,046-7,471 p/s in both directions is fast RAM-backed paging, which is why
   `/swap/swapfile` still reads **0 used**.
2. **The SSD storm is better explained by page-cache collapse than by swap.**
   `node_memory_Cached_bytes` was ~1.5 GiB at onset, and every refault landed on
   the one device that carries everything:

   | 01:30Z | 01:34Z | 01:38Z | 01:41Z | 01:42Z |
   |---|---|---|---|---|
   | `rate(node_disk_read_time_seconds_total{device="dm-0"}[5m])` | 8.93 | 7.65 | 10.07 | 18.96 | **20.28** |
   | `rate(node_disk_io_time_weighted_seconds_total{device="dm-0"}[5m])` | 12.04 | 11.74 | 13.35 | 24.29 | **26.69** |
   | `rate(node_disk_read_bytes_total{device="sdb"}[5m])` | 38 MB/s | 46 MB/s | 45 MB/s | 59 MB/s | **68 MB/s** |
   | `rate(node_disk_write_time_seconds_total{device="dm-0"}[5m])` | 3.12 | 4.10 | 3.28 | 5.32 | 6.40 |

   7d baselines for that device: `read_time` p50 0.39 / p90 1.94 / **p99 6.43** /
   max 53.80; `io_time_weighted` p50 0.65 / p90 2.41 / **p99 7.44** / max 60.26.
   The wedge ran at 20.28 and 26.69 s/s sustained. `sda` read **0 bytes** through
   the whole event — the idle second disk stayed idle.

That is the whole reason item 4 below exists: the storage is not "the swap is too
big", it is "one device holds etcd, all container storage, all logs and a
swapfile, so any reclaim pressure becomes a control-plane stall".

---

## 2. What was changed in git (done, deployed)

### 2a. llama memory limits: 36 GiB -> 12 GiB across the three forge members

`mining-k8s`, commit **a06f3bd**:

| member | old limit | new limit | 7d max working set | basis |
|---|---|---|---|---|
| `llama-forge-4060-0` | 12Gi | **4Gi** | 2390 MiB | 2390 x 1.5 = 3585 -> next 1Gi |
| `llama-forge-4060-1` | 12Gi | **3Gi** | 1936 MiB | 1936 x 1.5 = 2904 -> next 1Gi |
| `llama-forge-5700xt` | 12Gi | **5Gi** | 3235 MiB (pre-v4 image) | 3235 x 1.5 = 4853 -> next 1Gi |

Measured with `container_memory_working_set_bytes{namespace="mining",container="llama-server"}`,
7d to 2026-10-02T04:35Z. The MAX is used rather than the p95 the incident
write-up suggested, because the p95 is exactly what this incident exceeded:
`llama-forge-4060-0`'s wedge peak of 2390 MiB sits ABOVE its own 7d p95 of
1912 MiB, so sizing on p95 would have OOM-killed the member during the event
being defended against. The `5700xt` limit is the loosest by ratio because its
7d max comes from the pre-v4 generation; the file says so and it is the first
limit to tighten once a full 7d of v4 data exists.

Forge's total declared memory limits before this change, from
`kube_pod_container_resource_limits{node="forge",resource="memory"}`:

| namespace | GiB |
|---|---|
| mining | 49.06 |
| trading | 4.00 |
| longhorn-system | 0.50 |
| kube-system | 0.39 |
| monitoring | 0.12 |
| **total** | **54.08** |

against **15.47 GiB** of RAM. After the llama change mining drops to ~25 GiB, so
the total is ~30 GiB. Still over-committed — see 2b for why that is not by
itself the fix.

### 2b. DECISION — the swap: remove the SSD-backed half, cap zram

**Decision:** remove `/swap/swapfile` (the 15.47 GiB btrfs file on
`/dev/mapper/root`) from forge entirely, and cut `zram0` from 15.47 GiB to
**4 GiB**. Net swap: 30.94 GiB -> 4 GiB, and **zero SSD-backed swap**.

Evidence for removing the file rather than shrinking it:

- It is the only swap device that puts writes on the device carrying etcd's
  WAL, 40 GB of containerd storage and 998 MB of journald. Any paging to it is a
  control-plane I/O event by construction.
- The durable fix for that device — move containerd off it (item 4) — is not
  done, and is a j_kro-signed restart of every pod on the node. Removing 15.47
  GiB of latent hazard from the device now costs one `swapoff` and removes the
  write-side risk without touching etcd.
- `fstab` labels it "Btrfs swapfile for system hibernation". **Removing it
  disables hibernation on forge.** If hibernation is wanted, keep a file but
  move it to `/dev/sda2` (216 GB btrfs, 166 GB free, `/mnt/oldforge`) — sda is
  NOT the etcd device and read 0 bytes through the incident. That is the
  preferred variant if hibernation matters; the 8 GiB dormant `/dev/sda1` swap
  partition cannot host a 15.47 GiB RAM image.

Evidence for capping zram at 4 GiB rather than leaving 15.47 GiB:

- zram is RAM-backed, so it does not remove memory pressure — it converts it
  into **compressed RAM** plus a later refault. At 100% of RAM it lets the box
  absorb far more pressure before the OOM killer is reached, which is the
  behaviour the incident describes: "the kernel swapped ... instead of
  OOM-killing".
- Measured efficiency on forge is real but not unlimited: `mm_stat` showed
  592 MiB of swapped pages in ~99 MiB of RAM (~6:1 with zstd). 4 GiB of zram is
  therefore ~24 GiB of buffering at that ratio — plenty for a spike, without
  letting the box paper over a 20 GiB overshoot.
- The desired end state: memory pressure on forge resolves to **one bounded,
  immediate OOM kill of a container** (recoverable in seconds by kubelet)
  instead of an unbounded two-way page storm that takes sshd, kubelet and etcd
  with it. Miners are not at risk: `peakminer` uses 136-137 MiB against a 512Mi
  limit and holds the GPU, so the OOM killer's target will be a llama/llmster
  container, exactly as intended.

Exact steps (j_kro):

```bash
# 0. confirm the file is genuinely unused before touching anything
cat /proc/swaps                       # expect /swap/swapfile Used = 0

# 1. drop the file  (swapoff must pull back only what is resident in it; at
#    0 used this is a no-op. Do NOT run it while Used > ~1 GiB on a box with
#    < 4 GiB MemAvailable — it would stall the node exactly like the incident.)
sudo swapoff /swap/swapfile
sudo sed -i.bak 's|^/swap/swapfile|#REMOVED 2026-10-02 (t_56d315ce; single-SSD hazard) /swap/swapfile|' /etc/fstab
sudo rm -f /swap/swapfile            # frees 16 GB on the etcd device

# 2. cap zram at 4 GiB (zram-generator is NOT configured via a conf file on
#    forge today — /etc/systemd/zram-generator.conf does not exist, the device
#    comes from the distro default — so pin it explicitly)
printf '[zram0]\nzram-size = 4096\ncompression-algorithm = zstd\n' | sudo tee /etc/systemd/zram-generator.conf.d/10-homelab.conf
sudo systemctl daemon-reload && sudo systemctl restart systemd-zram-setup@zram0.service

# 3. verify
cat /proc/swaps                       # expect only /dev/zram0, 4G
free -h
```

Expected verification after step 3: `SwapTotal` ~4 GiB; `node_memory_SwapTotal_bytes`
drops from 30.94 GiB to ~4 GiB in VictoriaMetrics; forge's `MemAvailable` band
does not collapse, and if it does the OOM killer fires on a container instead of
the box stalling.

### 2c. FAILURE -> TEST

- `node-health` VMRule (`media-k8s` commit **2fd6049**) — `NodeMemoryAvailableLow`
  (MemAvailable/MemTotal < 5% for 5m, warning) and `NodeSwapThrash`
  (`rate(node_vmstat_pswpout[5m]) > 5000` for 10m, critical). Observed live
  immediately after deploy: `NodeMemoryAvailableLow` pending on
  `10.1.1.130:9100` (forge) at value 0.0194, which is the chronic condition this
  runbook is about — see §3.
- `media-k8s/tests/test_monitoring_invariants.py` §12 — 6 tests, all passing.
- `media-k8s/cluster/checks/verify-fleet.sh` §9l — peakminer NoExecute
  tolerations.

---

## 3. Why forge is at the wall permanently

`node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` on forge, 7d of
5-minute windows to 2026-10-02T04:35Z:

| window | value |
|---|---|
| p50 | **0.08** |
| p5 | 0.04 |
| p1 | 0.04 |
| min | 0.02 |
| share of windows < 5% | **17.1%** |
| share of windows < 10% | **75.3%** |

For comparison, over the same window: nexus p50 0.42 (0% below 5%), zephyr p50
0.37 (0.10% below 5%), sentry p50 0.64 (0%). Forge is the only host in the fleet
that lives at its own wall.

Consequences for alerting, recorded so the next reader does not "fix" it:
`NodeMemoryAvailableLow` and the upstream `NodeMemoryHighUtilization` will be
**expected to be firing much of the time on forge**. That is truthful. The
signal that means "something is happening NOW" is `NodeSwapThrash`, and its
threshold was moved off the proposed 2000 p/s precisely because at that level
the alert is indistinguishable from forge's normal state (see the rule file).

---

## 4. DECISION — forge's single-SSD hazard (third time named)

### Current state, measured on forge

`/dev/mapper/root` = LUKS over `sdb2`, 237 GB, 119 GB used, 115 GB free, and it
carries all of:

| user | size | source |
|---|---|---|
| containerd (all container storage) | **40 GB** (the 2026-09-22 runbook recorded 24 GB; it has grown) | `sudo du -s -h /var/lib/rancher/k3s/agent/containerd` |
| etcd WAL + db | 628 MB | `sudo du -s -h /var/lib/rancher/k3s/server/db` |
| journald | 998 MB | `sudo du -s -h /var/log/journal` |
| `/swap/swapfile` | 16 GB | `sudo du -s -h /swap` (removed by §2b) |

The idle disk `/dev/sda2` is 216 GB btrfs mounted at `/mnt/oldforge` with
**166 GB free**, and read **0 bytes** during the entire incident.

### Decision

**Move k3s's container storage off `/dev/mapper/root` onto `/dev/sda2`.** The
2026-09-22 runbook already named this as "the durable fix". This is the second
confirmed control-plane stall on that device, so the decision is to do it, not
to re-accept the risk.

### Migration steps (j_kro-signed — this restarts every pod on the node)

k3s has no per-component data-dir flag: `systemctl show k3s -p ExecStart` on
forge shows a single `--data-dir=/var/lib/rancher/k3s`, which would move etcd's
own DB as well and is a much bigger change than this problem needs. The
containerd-only lever is k3s's containerd config template.

1. **Pre-flight: prove overlayfs works on the target filesystem.** `/mnt/oldforge`
   is **btrfs**, and container storage on btrfs is the one real unknown here. Do
   not skip this — it is a 5-minute test:
   ```bash
   sudo btrfs subvolume create /mnt/oldforge/_overlaytest
   mkdir -p /tmp/lower /tmp/upper /tmp/work /tmp/merged
   sudo mount -t overlay overlay -o lowerdir=/tmp/lower,upperdir=/mnt/oldforge/_overlaytest/upper,workdir=/mnt/oldforge/_overlaytest/work /tmp/merged
   # success = the mount succeeds and a file written to /tmp/merged appears in upper
   sudo umount /tmp/merged && sudo btrfs subvolume delete /mnt/oldforge/_overlaytest
   ```
   If overlay-on-btrfs fails, change the plan to: shrink `sda1`, create a plain
   ext4 partition on sda for containerd, and use that instead. Do not proceed on
   btrfs without this test.

2. **Create the target and capture the CURRENT generated config as the template.**
   k3s writes `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` at startup.
   Supplying `config.toml.tmpl` makes k3s use YOUR file instead of the built-in
   template, so it must be the full config, not a fragment:
   ```bash
   sudo mkdir -p /mnt/oldforge/k3s-containerd /var/lib/rancher/k3s/agent/etc/containerd
   sudo cp /var/lib/rancher/k3s/agent/etc/containerd/config.toml \
           /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
   ```
   (Neither file exists on forge yet: `ls /var/lib/rancher/k3s/agent/etc/containerd/`
   is empty, so check both paths against whatever k3s actually generates at next
   start, or take the template that ships in the k3s release for the pinned
   version `v1.37.0+k3s1`.)

3. **Point containerd's root at sda** in `config.toml.tmpl`:
   ```toml
   [plugins."io.containerd.grpc.v1.cri".containerd]
     # default_runtime_name = "runc"
     # ...
   version = 2
   root = "/mnt/oldforge/k3s-containerd"
   state = "/run/k3s/containerd"
   ```
   `root` is the persistent storage; `state` stays on tmpfs (`/run`) and is
   rebuilt on start.

4. **Drain and restart the node.** This restarts every pod on forge, including
   both miners and all three llama members:
   ```bash
   kubectl --kubeconfig=... drain forge --ignore-daemonsets --delete-emptydir-data --force
   sudo systemctl restart k3s
   # verify containerd actually moved
   sudo ls -la /mnt/oldforge/k3s-containerd
   df -h /                        # /dev/mapper/root usage should drop by ~40 GB
   ```
5. **Uncordon, then verify mining is back.** Both forge miners are nodeName-pinned
   and now tolerate the `unreachable`/`not-ready` NoExecute taints
   (`mining-k8s` a06f3bd), so the replacements created during the drain will
   schedule onto forge as soon as it accepts work. Confirm accepted shares rise.
6. **Budget the image re-pull.** Container storage moves empty, so every image on
   forge is pulled fresh; with `--disable=traefik,metrics-server,servicelb` that
   is a small set on this node, but it is a real cost on a mining node. Do it in
   a low-share window.

### What is NOT done, and why

Nothing in §2b or §4 has been executed. Both are host changes on the etcd member
that holds the cluster's write quorum, and both restart or stall the node that
carries two revenue miners:

- `swapoff` on a swapfile with pages in it can stall the node exactly like the
  incident (`MemAvailable` at decision time was **1.98 GiB**, and the box
  oscillates between ~2% and ~42% available).
- The containerd move restarts every pod on forge and re-pulls every image.

Item 2a (llama limits), item 2c (alerts + tests) and the miner tolerations are
done and deployed. §2b and §4 are recorded here with the numbers and the exact
steps so they can be executed in one signed change window.

### Accepted-risk alternative, if §4 is refused

If the containerd move is refused, the residual risk to record is: **one device
holds etcd's WAL, 40 GB of container storage, ~1 GB of journald and (until §2b
is done) 16 GB of swap; a memory-induced page-cache collapse on forge will stall
etcd and take the node unrecoverable.** Measured exposure: 2 confirmed
occurrences in 10 days (2026-09-22 18:09Z, 2026-10-01 20:38 CDT), the second
costing ~2h36m of node downtime and an unknown share of mining revenue.
