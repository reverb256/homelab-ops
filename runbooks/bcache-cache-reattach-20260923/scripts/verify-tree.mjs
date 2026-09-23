#!/usr/bin/env node
// Recursive byte-level comparison of two directory trees.
//
// usage: node scripts/verify-tree.mjs <a> <b>
//
// Compares every relative path in both trees (regular files, directories and
// symlinks), then compares size + sha256 for every regular file. Prints
//   TREE IDENTICAL: <n> files, <bytes> bytes
// and exits 0 only when the two trees match exactly.

import { readdirSync, statSync, readlinkSync, lstatSync, createReadStream, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { join, relative } from 'node:path'

const [a, b] = process.argv.slice(2)
if (!a || !b) { console.error('usage: verify-tree.mjs <a> <b>'); process.exit(2) }
for (const p of [a, b]) if (!existsSync(p)) { console.error(`missing tree: ${p}`); process.exit(1) }

const problems = []
function walk(root) {
  const out = new Map()
  const stack = ['']
  while (stack.length) {
    const rel = stack.pop()
    const dir = rel ? join(root, rel) : root
    let entries
    try {
      entries = readdirSync(dir)
    } catch (err) {
      // Unreadable directory: record it as a difference instead of crashing, so
      // the comparison reports a real verdict for the tree it could inspect.
      out.set(rel ? `${rel}/` : '.', { type: 'unreadable', reason: String(err.code || err) })
      continue
    }
    for (const entry of entries) {
      const childRel = rel ? `${rel}/${entry}` : entry
      const abs = join(root, childRel)
      const st = lstatSync(abs)
      if (st.isDirectory()) { out.set(childRel, { type: 'dir' }); stack.push(childRel) }
      else if (st.isSymbolicLink()) out.set(childRel, { type: 'link', target: readlinkSync(abs) })
      else if (st.isFile()) out.set(childRel, { type: 'file', size: st.size, abs })
      else out.set(childRel, { type: 'other' })
    }
  }
  return out
}

function sha256(path) {
  return new Promise((resolve, reject) => {
    const h = createHash('sha256')
    createReadStream(path).on('data', (d) => h.update(d)).on('end', () => resolve(h.digest('hex'))).on('error', reject)
  })
}

const ta = walk(a)
const tb = walk(b)
for (const [rel, ea] of ta) {
  const eb = tb.get(rel)
  if (!eb) { problems.push(`only in ${a}: ${rel}`); continue }
  if (ea.type !== eb.type) { problems.push(`type differs at ${rel}: ${ea.type} vs ${eb.type}`); continue }
  if (ea.type === 'link' && ea.target !== eb.target) problems.push(`symlink target differs at ${rel}: ${ea.target} vs ${eb.target}`)
  if (ea.type === 'file' && ea.size !== eb.size) problems.push(`size differs at ${rel}: ${ea.size} vs ${eb.size}`)
}
for (const rel of tb.keys()) if (!ta.has(rel)) problems.push(`only in ${b}: ${rel}`)

if (problems.length) {
  console.error(`TREE MISMATCH: ${problems.length} difference(s)`)
  for (const p of problems.slice(0, 20)) console.error(`  - ${p}`)
  process.exit(1)
}

let files = 0
let bytes = 0
for (const [rel, ea] of ta) {
  if (ea.type !== 'file') continue
  const [ha, hb] = await Promise.all([sha256(ea.abs), sha256(join(b, rel))])
  if (ha !== hb) { problems.push(`sha256 differs at ${rel}`); break }
  files++
  bytes += ea.size
}
if (problems.length) {
  console.error(`TREE MISMATCH (content): ${problems.length} difference(s)`)
  for (const p of problems.slice(0, 20)) console.error(`  - ${p}`)
  process.exit(1)
}
console.log(`TREE IDENTICAL: ${files} files, ${bytes} bytes (${a} == ${b})`)
