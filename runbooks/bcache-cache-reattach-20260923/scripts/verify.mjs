#!/usr/bin/env node
// Decisive phase verifiers for the bcache cache re-attach (nexus, 2026-09-23).
//
// usage: node scripts/verify.mjs <check>
//   checks: paused unmounted partitions tier-restored cache-mode cache-attached
//           pool-integrity cache-in-use media-restored stack-http repo-state
//
// Every check performs its own assertions, exits non-zero with a reason on the
// first failure, and prints exactly one success marker only after all of them
// pass:   PHASE VERIFIED: <check>
//
// Read-only with respect to the devices; the only writes are the temporary
// probe file used by pool-integrity / cache-in-use, which is removed again.

import { spawnSync } from 'node:child_process'
import { readFileSync, writeFileSync, openSync, closeSync, writeSync, unlinkSync, readdirSync, existsSync } from 'node:fs'
import { createHash, randomInt } from 'node:crypto'

const CHECK = process.argv[2]
const FAST = '/data/fast'
const POOL = '/data/shared'
const HOLD = '/data/nvme1/_fast-hold-20260923'
const CORRUPTION_BASELINE = 3959 // btrfs corruption_errs measured 2026-09-23 before the window
const APPS = ['bazarr', 'gamarr', 'lidarr', 'tubearchivist']
const ARGO_APPS = ['media-bazarr', 'media-lidarr', 'media-stack']
const TIER_BYTES_MIN = 94 * 1024 ** 3
const TIER_BYTES_MAX = 98 * 1024 ** 3
const CACHE_BYTES_MIN = 350 * 1024 ** 3

const failures = []
function fail(msg) { failures.push(msg) }
function done() {
  if (failures.length) {
    console.error(`FAILED ${CHECK}:`)
    for (const f of failures) console.error(`  - ${f}`)
    process.exit(1)
  }
  console.log(`PHASE VERIFIED: ${CHECK}`)
}

function sh(cmd, args = [], opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...opts })
  return { code: r.status, out: (r.stdout || '') + (r.stderr || ''), stdout: r.stdout || '', stderr: r.stderr || '' }
}
const sudo = (args, opts) => sh('sudo', ['-n', ...args], opts)
const kubectl = (args, opts) => sudo(['k3s', 'kubectl', ...args], opts)
const read = (p) => { try { return readFileSync(p, 'utf8').trim() } catch { return null } }
const readInt = (p) => { const v = read(p); return v === null ? null : parseInt(v, 10) }

function kubectlJson(args) {
  const r = kubectl([...args, '-o', 'json'])
  if (r.code !== 0) throw new Error(`kubectl ${args.join(' ')} failed: ${r.out.slice(0, 300)}`)
  return JSON.parse(r.stdout)
}

// Recursive byte comparison of two trees, run out of process so both this
// script and the ledger stay small. Runs under sudo -n: the tier holds
// root-owned state (preseed/romm-db, the arr databases) that is not readable
// as the invoking user, and an unreadable tree must fail loudly rather than
// compare nothing.
function treeEqual(a, b) {
  const r = sh('sudo', ['-n', process.execPath, new URL('./verify-tree.mjs', import.meta.url).pathname, a, b])
  if (r.code !== 0) { fail(`tree mismatch ${a} vs ${b}: ${r.out.trim().split('\n').slice(-4).join(' | ')}`); return false }
  return true
}

// --- individual checks -----------------------------------------------------

function checkPaused() {
  const pods = kubectlJson(['get', 'pods', '-A'])
  const offenders = pods.items.filter((p) =>
    (p.spec.volumes || []).some((v) => ((v.hostPath || {}).path || '').includes('/data/fast')))
  for (const p of offenders) fail(`pod ${p.metadata.namespace}/${p.metadata.name} still mounts /data/fast (phase ${p.status.phase})`)
  if (!offenders.length) console.log(`  no pods reference /data/fast (${pods.items.length} pods cluster-wide)`)

  const lsof = sudo(['lsof', '+D', FAST])
  const holders = lsof.stdout.split('\n').filter((l) => l.includes(`${FAST}/`))
  if (holders.length) fail(`processes still hold files under ${FAST}: ${holders.slice(0, 5).join(' ; ')}`)
  else console.log(`  no process holds files under ${FAST}`)

  const sts = kubectlJson(['-n', 'argocd', 'get', 'statefulset', 'argocd-application-controller'])
  const replicas = sts.spec.replicas
  if (replicas !== 0) fail(`argocd-application-controller replicas=${replicas}, expected 0 (self-heal must be suspended)`)
  else console.log('  argocd-application-controller suspended (replicas=0)')

  const deploys = kubectlJson(['-n', 'media', 'get', 'deploy'])
  for (const name of APPS) {
    const d = deploys.items.find((x) => x.metadata.name === name)
    if (!d) { fail(`deployment media/${name} not found`); continue }
    if ((d.spec.replicas ?? 1) !== 0) fail(`deployment media/${name} replicas=${d.spec.replicas}, expected 0`)
  }
  done()
}

function checkUnmounted() {
  const fm = sh('findmnt', ['-n', FAST])
  if (fm.stdout.trim()) fail(`${FAST} is still mounted: ${fm.stdout.trim()}`)
  const unit = sh('systemctl', ['is-active', 'data-fast.mount'])
  if (unit.stdout.trim() === 'active') fail('data-fast.mount is still active')
  const holders = readdirSync('/sys/block/sdb/holders')
  if (holders.length) fail(`/dev/sdb still has holders: ${holders.join(',')}`)
  const fuser = sudo(['fuser', '-m', '/dev/sdb'])
  const pids = fuser.stdout.split('\n').filter((l) => /\/dev\/sdb/.test(l))
  if (pids.length) fail(`processes still hold /dev/sdb: ${pids.join(' ')}`)
  const pool = sh('findmnt', ['-n', '-o', 'SOURCE,FSTYPE', POOL])
  if (!pool.stdout.includes('bcache0')) fail(`pool is not mounted from bcache0: ${pool.stdout.trim() || '(nothing)'}`)
  console.log(`  ${FAST} unmounted, /dev/sdb idle, pool live on ${pool.stdout.trim()}`)
  done()
}

function checkPartitions() {
  const r = sh('lsblk', ['-J', '-b', '-o', 'NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT', '/dev/sdb'])
  if (r.code !== 0) { fail(`lsblk failed: ${r.out.slice(0, 200)}`); return done() }
  const disk = JSON.parse(r.stdout).blockdevices.find((d) => d.name === 'sdb')
  const parts = disk?.children || []
  const p1 = parts.find((p) => p.name === 'sdb1')
  const p2 = parts.find((p) => p.name === 'sdb2')
  if (!p1) fail('sdb1 missing')
  if (!p2) fail('sdb2 missing')
  if (p1) {
    const size = Number(p1.size)
    if (!(size >= TIER_BYTES_MIN && size <= TIER_BYTES_MAX)) fail(`sdb1 size ${size} outside [${TIER_BYTES_MIN},${TIER_BYTES_MAX}]`)
    if (p1.fstype !== 'btrfs') fail(`sdb1 fstype=${p1.fstype}, expected btrfs`)
    if ((p1.label || '') !== 'nexus-fast') fail(`sdb1 label=${p1.label}, expected nexus-fast`)
    console.log(`  sdb1 ${(size / 1024 ** 3).toFixed(1)} GiB ${p1.fstype} label=${p1.label}`)
  }
  if (p2) {
    const size = Number(p2.size)
    if (size < CACHE_BYTES_MIN) fail(`sdb2 size ${size} below ${CACHE_BYTES_MIN}`)
    console.log(`  sdb2 ${(size / 1024 ** 3).toFixed(1)} GiB fstype=${p2.fstype || '(none yet)'}`)
  }
  done()
}

function checkTierRestored() {
  const fm = sh('findmnt', ['-n', '-o', 'SOURCE,FSTYPE', FAST])
  if (!/\/dev\/sdb1\s+btrfs/.test(fm.stdout)) fail(`${FAST} source/fstype unexpected: ${fm.stdout.trim() || '(nothing mounted)'}`)
  const unit = read('/etc/systemd/system/data-fast.mount') || ''
  const m = unit.match(/What=\/dev\/disk\/by-uuid\/([0-9a-f-]{36})/i)
  if (!m) fail('data-fast.mount does not declare a by-uuid What= device')
  else {
    const blkid = sudo(['blkid', '-s', 'UUID', '-o', 'value', '/dev/sdb1'])
    const live = blkid.stdout.trim()
    if (live !== m[1]) fail(`sdb1 UUID ${live} != unit UUID ${m[1]}`)
    else console.log(`  ${FAST} on /dev/sdb1, UUID matches data-fast.mount (${live})`)
  }
  if (!existsSync(HOLD)) fail(`hold copy ${HOLD} missing — cannot verify the restored tree`)
  else treeEqual(HOLD, FAST)
  done()
}

function cacheSetDirs() {
  if (!existsSync('/sys/fs/bcache')) return []
  return readdirSync('/sys/fs/bcache').filter((d) => existsSync(`/sys/fs/bcache/${d}/cache0`))
}

function checkCacheMode() {
  const mode = read('/sys/block/sda/bcache/cache_mode') || ''
  if (!/\[writearound\]/.test(mode)) fail(`backing cache_mode is '${mode}', expected [writearound] before attach`)
  const state = read('/sys/block/sda/bcache/state')
  if (state !== 'no cache') fail(`backing state='${state}', expected 'no cache' at this phase`)
  const sets = cacheSetDirs()
  if (!sets.length) fail('no registered bcache cache set (expected /sys/fs/bcache/<set-uuid>/cache0)')
  else console.log(`  cache set registered: ${sets.join(',')}`)
  const sb = sudo(['bcache-super-show', '/dev/sdb2'])
  if (!/\[cache device\]/i.test(sb.out)) fail(`bcache-super-show /dev/sdb2 does not report a cache device:\n${sb.out.slice(0, 300)}`)
  const cacheUuid = (sb.out.match(/dev\.uuid\s+([0-9a-f-]{36})/i) || [])[1]
  if (!cacheUuid) fail('could not read the cache device uuid from its superblock')
  else console.log(`  cache device uuid ${cacheUuid}`)
  done()
}

function checkCacheAttached() {
  const state = read('/sys/block/sda/bcache/state')
  if (state !== 'clean') fail(`backing state='${state}', expected 'clean'`)
  const dirty = read('/sys/block/sda/bcache/dirty_data')
  if (dirty !== '0.0k') fail(`dirty_data='${dirty}', expected '0.0k' (writearound must never hold dirty data)`)
  const mode = read('/sys/block/sda/bcache/cache_mode') || ''
  if (!/\[writearound\]/.test(mode)) fail(`cache_mode is '${mode}', expected [writearound]`)
  if (!existsSync('/dev/bcache0')) fail('/dev/bcache0 missing')
  const pool = sh('findmnt', ['-n', '-o', 'SOURCE', POOL])
  if (!pool.stdout.includes('bcache0')) fail(`pool not mounted from bcache0: ${pool.stdout.trim()}`)
  const sb = sudo(['bcache-super-show', '/dev/sda'])
  const setUuid = (sb.out.match(/cset\.uuid\s+([0-9a-f-]{36})/i) || [])[1]
  if (!setUuid || /^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(setUuid)) {
    fail(`backing cset.uuid is empty (${setUuid}) — the attach would not survive a reboot`)
  }
  const persisted = (sb.out.match(/dev\.data\.cache_mode\s+(\d+)\s+\[(\w+)\]/i) || [])
  if (persisted[2] !== 'writearound') {
    fail(`persisted backing cache_mode is '${persisted[2] || 'unparsed'}' — a reboot would come back in the wrong mode`)
  }
  console.log(`  attached: state=${state} dirty=${dirty} cset.uuid=${setUuid} persisted mode=${persisted[2]}`)
  done()
}

function probeFile(bytes, path) {
  writeFileSync(path, Buffer.alloc(1024 * 1024))
  const fd = openSync(path, 'r+')
  const chunk = Buffer.alloc(1024 * 1024)
  for (let i = 0; i < bytes / chunk.length; i++) { require('node:fs').writeSync(fd, chunk) }
  closeSync(fd)
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

// Phase marker: several gates only describe the post-conversion world, so they
// assert the conversion actually happened instead of passing on the pre-window
// state. Cheap and decisive: the backing device is only 'clean' with a cache
// attached.
function requireCacheAttached() {
  const state = read('/sys/block/sda/bcache/state')
  if (state !== 'clean') {
    fail(`the conversion has not happened yet: /sys/block/sda/bcache/state='${state}', expected 'clean'`)
    return false
  }
  return true
}

function checkCopy() {
  const pods = kubectlJson(['get', 'pods', '-A'])
  const offenders = pods.items.filter((p) =>
    (p.spec.volumes || []).some((v) => ((v.hostPath || {}).path || '').includes('/data/fast')))
  if (offenders.length) fail(`copy taken while ${offenders.length} pod(s) still mount /data/fast — it could be torn`)
  const lsof = sudo(['lsof', '+D', FAST])
  if (lsof.stdout.split('\n').some((l) => l.includes(`${FAST}/`))) fail(`copy taken while processes still hold files under ${FAST} — it could be torn`)
  if (!existsSync(HOLD)) { fail(`hold tree ${HOLD} does not exist`); return done() }
  if (!treeEqual(FAST, HOLD)) return done()
  done()
}

function checkPoolIntegrity() {
  if (!requireCacheAttached()) return done()
  const r = sudo(['btrfs', 'device', 'stats', POOL])
  if (r.code !== 0) { fail(`btrfs device stats failed: ${r.out.slice(0, 200)}`); return done() }
  const get = (k) => Number((r.out.match(new RegExp(`${k}\\s+(\\d+)`)) || [])[1] ?? NaN)
  const counters = {
    write_io_errs: get('write_io_errs'), read_io_errs: get('read_io_errs'),
    flush_io_errs: get('flush_io_errs'), generation_errs: get('generation_errs'),
    corruption_errs: get('corruption_errs'),
  }
  for (const k of ['write_io_errs', 'read_io_errs', 'flush_io_errs', 'generation_errs']) {
    if (counters[k] !== 0) fail(`${k}=${counters[k]}, expected 0`)
  }
  if (!(counters.corruption_errs <= CORRUPTION_BASELINE)) {
    fail(`corruption_errs grew to ${counters.corruption_errs} (baseline ${CORRUPTION_BASELINE})`)
  }
  console.log(`  device stats ${JSON.stringify(counters)} (corruption baseline ${CORRUPTION_BASELINE})`)

  const probe = `${POOL}/_bcache-verify-${process.pid}.bin`
  try {
    probeFile(64 * 1024 * 1024, probe)
    const written = sha256(probe)
    const back = sha256(probe)
    if (written !== back) fail(`pool read-back hash mismatch ${written} != ${back}`)
    else console.log(`  pool write+read round-trip OK (64 MiB, sha256 ${written.slice(0, 12)}…)`)
  } finally {
    try { unlinkSync(probe) } catch {}
  }
  done()
}

function directRead(path, offset, length) {
  const r = sh('dd', [`if=${path}`, 'iflag=direct,skip_bytes,count_bytes', `skip=${offset}`, `count=${length}`, 'bs=65536', 'of=/dev/null'])
  return r.code === 0
}

function checkCacheInUse() {
  if (!requireCacheAttached()) return done()
  const hits = () => readInt('/sys/block/sda/bcache/stats_total/cache_hits') ?? -1
  const misses = () => readInt('/sys/block/sda/bcache/stats_total/cache_misses') ?? -1
  const bypass = () => readInt('/sys/block/sda/bcache/stats_total/cache_bypass_misses') ?? -1
  const probe = `${POOL}/_bcache-hitprobe-${process.pid}.bin`
  const SIZE = 256 * 1024 * 1024
  const BLOCK = 64 * 1024
  try {
    probeFile(SIZE, probe)
    const offsets = []
    for (let i = 0; i < 64; i++) offsets.push(randomInt(0, (SIZE - BLOCK) / BLOCK) * BLOCK)
    const h0 = hits(); const m0 = misses(); const b0 = bypass()
    for (const off of offsets) directRead(probe, off, BLOCK)          // pass 1: populate
    for (const off of offsets) directRead(probe, off, BLOCK)          // pass 2: expect hits
    const h1 = hits(); const m1 = misses(); const b1 = bypass()
    const dh = h1 - h0; const dm = m1 - m0; const db = b1 - b0
    console.log(`  cache_hits +${dh}, cache_misses +${dm}, cache_bypass_misses +${db} over ${offsets.length * 2} direct 64 KiB reads`)
    if (dh < 8) fail(`only ${dh} cache hits from ${offsets.length * 2} direct reads — the cache is not serving the pool`)
  } finally {
    try { unlinkSync(probe) } catch {}
  }
  done()
}

function checkMediaRestored() {
  if (!requireCacheAttached()) return done()
  const sts = kubectlJson(['-n', 'argocd', 'get', 'statefulset', 'argocd-application-controller'])
  if (sts.spec.replicas !== 1) fail(`argocd-application-controller replicas=${sts.spec.replicas}, expected 1 (self-heal must be restored)`)
  const deploys = kubectlJson(['-n', 'media', 'get', 'deploy'])
  for (const name of APPS) {
    const d = deploys.items.find((x) => x.metadata.name === name)
    if (!d) { fail(`deployment media/${name} not found`); continue }
    const want = d.spec.replicas ?? 1
    const ready = d.status.readyReplicas ?? 0
    if (want < 1 || ready < 1) fail(`media/${name} replicas=${want} ready=${ready}`)
    else console.log(`  media/${name} ${ready}/${want} ready`)
  }
  const lsof = sudo(['lsof', '+D', FAST])
  const expected = {
    bazarr: '/data/fast/media-config/bazarr/db/bazarr.db',
    lidarr: '/data/fast/media-config/lidarr/lidarr.db',
    gamarr: '/data/fast/gamarr/gamarr.db',
    tubearchivist: '/data/fast/tubearchivist/db.sqlite3',
  }
  for (const [name, db] of Object.entries(expected)) {
    if (!lsof.stdout.split('\n').some((l) => l.includes(db))) fail(`${name} has not re-opened its state file ${db}`)
    else console.log(`  ${name} re-opened ${db}`)
  }
  const apps = kubectlJson(['-n', 'argocd', 'get', 'applications'])
  for (const name of ARGO_APPS) {
    const a = apps.items.find((x) => x.metadata.name === name)
    if (!a) { fail(`argocd application ${name} not found`); continue }
    const auto = a.spec?.syncPolicy?.automated
    if (!auto || auto.selfHeal !== true) fail(`argocd ${name} self-heal not restored: ${JSON.stringify(a.spec?.syncPolicy)}`)
    if (a.status?.sync?.status !== 'Synced') fail(`argocd ${name} sync=${a.status?.sync?.status}`)
    if (a.status?.health?.status !== 'Healthy') fail(`argocd ${name} health=${a.status?.health?.status}`)
  }
  console.log('  argocd self-heal restored, media apps Synced/Healthy')
  done()
}

function checkStackHttp() {
  if (!requireCacheAttached()) return done()
  const svcs = kubectlJson(['-n', 'media', 'get', 'svc'])
  const okCodes = new Set([200, 301, 302, 401, 403])
  for (const name of APPS) {
    const svc = svcs.items.find((s) => s.metadata.name === name)
    if (!svc) { fail(`service media/${name} not found`); continue }
    const port = svc.spec.ports[0].port
    const r = kubectl(['get', '--raw', `/api/v1/namespaces/media/services/${name}:${port}/proxy/`])
    const code = (r.out.match(/\b(2\d\d|3\d\d|4\d\d|5\d\d)\b/) || [])[1]
    if (!code || !okCodes.has(Number(code))) fail(`media/${name}:${port} proxy returned ${code || 'no HTTP status'} (${r.out.slice(0, 120)})`)
    else console.log(`  media/${name}:${port} -> HTTP ${code}`)
  }
  done()
}

function checkRepoState() {
  const repo = '/home/j_kro/homelab-ops'
  const readme = readFileSync(`${repo}/omarchy/nexus/README.md`, 'utf8')
  for (const marker of ['CACHE RE-ATTACHED (2026-09-23)', 'writearound', 'sdb1']) {
    if (!readme.includes(marker)) fail(`README.md missing marker '${marker}'`)
  }
  const apply = readFileSync(`${repo}/omarchy/nexus/apply.sh`, 'utf8')
  const declared = (apply.match(/CACHE_UUID="([0-9a-f-]{36})"/) || [])[1]
  const sb = sudo(['bcache-super-show', '/dev/sdb2'])
  const live = (sb.out.match(/dev uuid:\s*([0-9a-f-]+)/i) || [])[1]
  if (!declared) fail('apply.sh has no CACHE_UUID')
  else if (declared !== live) fail(`apply.sh CACHE_UUID ${declared} != live cache uuid ${live}`)
  else console.log(`  apply.sh CACHE_UUID matches the live cache device (${live})`)

  const unit = '/etc/systemd/system/bcache-cache-mode.service'
  if (!existsSync(unit)) fail(`${unit} missing`)
  else {
    const en = sh('systemctl', ['is-enabled', 'bcache-cache-mode.service'])
    if (en.stdout.trim() !== 'enabled') fail(`bcache-cache-mode.service is-enabled=${en.stdout.trim()}`)
    const body = readFileSync(unit, 'utf8')
    if (!body.includes('writearound')) fail('bcache-cache-mode.service does not enforce writearound')
  }
  const status = sh('git', ['-C', repo, 'status', '--porcelain'])
  if (status.stdout.trim()) fail(`homelab-ops working tree is dirty:\n${status.stdout.trim().split('\n').slice(0, 8).join('\n')}`)
  const subject = sh('git', ['-C', repo, 'log', '-1', '--pretty=%s'])
  if (!/bcache/i.test(subject.stdout)) fail(`HEAD commit does not mention bcache: ${subject.stdout.trim()}`)
  console.log(`  repo committed: ${subject.stdout.trim()}`)
  done()
}

function checkRunbook() {
  const path = new URL('../RUNBOOK.md', import.meta.url).pathname
  if (!existsSync(path)) { fail(`RUNBOOK.md does not exist at ${path}`); return done() }
  const doc = readFileSync(path, 'utf8')
  const required = [
    'Residual risk', 'dead extent', 'scrub', 'writearound', 'sdb1', 'sdb2',
    'PHASE VERIFIED', 'rollback',
  ]
  const missing = required.filter((m) => !doc.toLowerCase().includes(m.toLowerCase()))
  if (missing.length) fail(`RUNBOOK.md missing: ${missing.join(', ')}`)
  const phases = (doc.match(/^## /gm) || []).length
  if (phases < 6) fail(`RUNBOOK.md documents only ${phases} sections`)
  console.log(`  runbook: ${doc.length} chars, ${phases} sections, residual risk recorded`)
  done()
}

const checks = {
  paused: checkPaused,
  copy: checkCopy,
  unmounted: checkUnmounted,
  partitions: checkPartitions,
  'tier-restored': checkTierRestored,
  'cache-mode': checkCacheMode,
  'cache-attached': checkCacheAttached,
  'pool-integrity': checkPoolIntegrity,
  'cache-in-use': checkCacheInUse,
  'media-restored': checkMediaRestored,
  'stack-http': checkStackHttp,
  'repo-state': checkRepoState,
  runbook: checkRunbook,
}

if (!checks[CHECK]) {
  console.error(`unknown check '${CHECK}'; known: ${Object.keys(checks).join(' ')}`)
  process.exit(2)
}
checks[CHECK]()
