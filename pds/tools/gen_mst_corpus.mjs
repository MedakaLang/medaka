#!/usr/bin/env node
// Generate the P1-B MST corpus with the pinned official @atproto/repo package.
// The shell wrapper installs the exact package outside the source tree and
// passes its node_modules directory here.

import { createHash } from 'node:crypto'
import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const [moduleRoot, output] = process.argv.slice(2)
if (!moduleRoot || !output) {
  throw new Error('usage: gen_mst_corpus.mjs <node_modules> <output>')
}

const repo = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/index.js')).href)
const lexData = await import(pathToFileURL(resolve(moduleRoot, '@atproto/lex-data/dist/index.js')).href)
const { MST, MemoryBlockstore, mstUtil } = repo
const { cidForCbor } = lexData

const exactDepth = (key) => {
  const digest = createHash('sha256').update(Buffer.from(key, 'utf8')).digest()
  let zeros = 0
  for (const byte of digest) {
    if (byte === 0) {
      zeros += 8
      continue
    }
    zeros += Math.clz32(byte) - 24
    break
  }
  return Math.floor(zeros / 2)
}

const mine = (prefix, depth) => {
  for (let i = 0; ; i++) {
    const key = `${prefix}${i}`
    if (exactDepth(key) === depth) return key
  }
}

const hex = (bytes) => Buffer.from(bytes).toString('hex')
const keyHex = (key) => Buffer.from(key, 'utf8').toString('hex')

const values = []
for (let i = 0; i < 8; i++) {
  values.push(await cidForCbor(Uint8Array.of(0xa1, 0x61, 0x6e, i)))
}

const depth0 = mine('app.bsky.feed.post/medaka-depth-0-', 0)
const depth1 = mine('app.bsky.feed.post/medaka-depth-1-', 1)
const depth2 = mine('app.bsky.feed.post/medaka-depth-2-', 2)
const depth3 = mine('app.bsky.feed.post/medaka-depth-3-', 3)
const prefix0 = mine('app.bsky.feed.post/prefix-a-', 0)
const prefix1 = mine('app.bsky.feed.post/prefix-b-', 0)
const prefix2 = mine('app.bsky.feed.post/prefix-c-', 0)

for (const [key, expected] of [
  [depth0, 0],
  [depth1, 1],
  [depth2, 2],
  [depth3, 3],
  [prefix0, 0],
  [prefix1, 0],
  [prefix2, 0],
]) {
  const observed = await mstUtil.leadingZerosOnHash(key)
  if (observed !== expected || exactDepth(key) !== expected) {
    throw new Error(`depth disagreement for ${key}: crypto=${exactDepth(key)} repo=${observed} expected=${expected}`)
  }
}

const put = (key, value) => ({ kind: 'PUT', key, depth: exactDepth(key), value })
const replace = (key, value) => ({ kind: 'REPLACE', key, value })
const del = (key) => ({ kind: 'DELETE', key })

const all = [
  put(depth0, values[0]),
  put(depth1, values[1]),
  put(depth2, values[2]),
  put(depth3, values[3]),
]

const cases = [
  ['empty', []],
  ['leading-zero-bits-0', [all[0]]],
  ['leading-zero-bits-2', all.slice(0, 2)],
  ['leading-zero-bits-4', all.slice(0, 3)],
  ['leading-zero-bits-6', all],
  ['prefix-compression', [put(prefix0, values[4]), put(prefix1, values[5]), put(prefix2, values[6])]],
  ['permutation-forward', all],
  ['permutation-reverse', [...all].reverse()],
  ['replace', [put(depth0, values[0]), replace(depth0, values[7])]],
  ['delete', [...all, del(depth1)]],
  ['delete-to-empty', [put(depth2, values[2]), del(depth2)]],
]

const lines = [
  '# Generated only by pds/tools/gen_mst_corpus.sh.',
  '# @atproto/repo 0.10.12; independent expected roots and node bytes.',
]

for (const [name, operations] of cases) {
  let tree = await MST.create(new MemoryBlockstore())
  lines.push(`CASE\t${name}`)
  for (const operation of operations) {
    if (operation.kind === 'PUT') {
      tree = await tree.add(operation.key, operation.value)
      lines.push(`PUT\t${keyHex(operation.key)}\t${operation.depth}\t${operation.value.toString()}`)
    } else if (operation.kind === 'REPLACE') {
      tree = await tree.update(operation.key, operation.value)
      lines.push(`REPLACE\t${keyHex(operation.key)}\t${operation.value.toString()}`)
    } else {
      tree = await tree.delete(operation.key)
      lines.push(`DELETE\t${keyHex(operation.key)}`)
    }
  }
  const { root, blocks } = await tree.getUnstoredBlocks()
  lines.push(`ROOT\t${root.toString()}`)
  const entries = Array.from(blocks).sort(([left], [right]) => left.toString().localeCompare(right.toString()))
  for (const [cid, bytes] of entries) {
    lines.push(`BLOCK\t${cid.toString()}\t${hex(bytes)}`)
  }
  lines.push('END')
}

await writeFile(output, `${lines.join('\n')}\n`)
