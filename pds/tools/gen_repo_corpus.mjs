#!/usr/bin/env node
// Generate P1-D repository transcript bytes with pinned official atproto code.

import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const [moduleRoot, output, batchOutput] = process.argv.slice(2)
if (!moduleRoot || !output || !batchOutput) {
  throw new Error('usage: gen_repo_corpus.mjs <node_modules> <output> <batch-output>')
}

const repo = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/index.js')).href)
const repoUtil = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/util.js')).href)
const provider = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/sync/provider.js')).href)
const cbor = await import(pathToFileURL(resolve(moduleRoot, '@atproto/lex-cbor/dist/index.js')).href)
const lexData = await import(pathToFileURL(resolve(moduleRoot, '@atproto/lex-data/dist/index.js')).href)
const commonWeb = await import(pathToFileURL(resolve(moduleRoot, '@atproto/common-web/dist/index.js')).href)
const crypto = await import(pathToFileURL(resolve(moduleRoot, '@atproto/crypto/dist/secp256k1/keypair.js')).href)

const { MST, MemoryBlockstore } = repo
const { TID } = commonWeb
const secretHex = '0000000000000000000000000000000000000000000000000000000000000001'
const keypair = await crypto.Secp256k1Keypair.import(secretHex)
const did = keypair.did()
const storage = new MemoryBlockstore()
let tree = await MST.create(storage)
const records = new Map()

const hex = (bytes) => Buffer.from(bytes).toString('hex')
const pathHex = (value) => Buffer.from(value, 'utf8').toString('hex')
const tids = [0, 1, 2, 3, 4].map((offset) => {
  const micros = 1700000000000000 + offset
  return { micros, clock: 7, text: TID.fromTime(micros, 7).toString() }
})

const pathA = 'app.bsky.feed.post/medaka-a'
const pathB = 'app.bsky.feed.post/medaka-b'
const recordA = {
  $type: 'app.bsky.feed.post',
  text: 'hello from Medaka',
  createdAt: '2026-08-28T00:00:00.000Z',
}
const recordA2 = { ...recordA, text: 'updated from Medaka' }
const recordB = {
  $type: 'app.bsky.feed.post',
  text: 'survives deletion',
  createdAt: '2026-08-28T00:00:01.000Z',
}
const recordC = {
  $type: 'app.bsky.feed.post',
  text: 'batched with the others',
  createdAt: '2026-08-28T00:00:02.000Z',
}

const lines = [
  '# Generated only by pds/tools/gen_repo_corpus.sh.',
  '# Official atproto repository/crypto reference; exact package routes are in VECTOR-PROVENANCE.txt.',
  `META\t${did}\t${secretHex}`,
  ...tids.map((tid) => `TID\t${tid.micros}\t${tid.clock}\t${tid.text}`),
]

const commit = async (tag, rev) => {
  const { root, blocks } = await tree.getUnstoredBlocks()
  const unsigned = { did, version: 3, data: root, rev, prev: null }
  const unsignedBytes = cbor.encode(unsigned)
  const signed = await repoUtil.signCommit(unsigned, keypair)
  const signedBytes = cbor.encode(signed)
  const commitCid = await lexData.cidForCbor(signedBytes)
  lines.push(`${tag}\t${root}\t${hex(unsignedBytes)}\t${hex(signedBytes)}\t${commitCid}\t${hex(signed.sig)}`)
  return { root, blocks, signedBytes, commitCid }
}

const exportCar = async (tag, metadata) => {
  await storage.putMany(metadata.blocks)
  for (const record of records.values()) await storage.putBlock(record.cid, record.bytes)
  await storage.putBlock(metadata.commitCid, metadata.signedBytes)

  const chunks = []
  for await (const chunk of provider.getFullRepo(storage, metadata.commitCid)) chunks.push(chunk)
  const carBytes = repoUtil.concatBytes(chunks)
  const decoded = await repo.readCarWithRoot(carBytes)
  const order = decoded.blocks.entries().map(({ cid }) => cid.toString()).join(',')
  lines.push(`${tag}CARORDER\t${order}`)
  lines.push(`${tag}CAR\t${hex(carBytes)}`)
}

await commit('INIT', tids[0].text)

const mutate = async (action, path, record, tid) => {
  let recordBytes = null
  let recordCid = null
  if (record !== null) {
    recordBytes = cbor.encode(record)
    recordCid = await lexData.cidForCbor(recordBytes)
    records.set(recordCid.toString(), { cid: recordCid, bytes: recordBytes })
  }
  if (action === 'CREATE') tree = await tree.add(path, recordCid)
  else if (action === 'UPDATE') tree = await tree.update(path, recordCid)
  else tree = await tree.delete(path)
  lines.push(`OP\t${action}\t${pathHex(path)}\t${recordBytes ? hex(recordBytes) : '-'}\t${recordCid ?? '-'}\t${tid.text}`)
  const meta = await commit('COMMIT', tid.text)
  return meta
}

const first = await mutate('CREATE', pathA, recordA, tids[1])
await exportCar('CREATE', first)
await mutate('UPDATE', pathA, recordA2, tids[2])
await mutate('CREATE', pathB, recordB, tids[3])
const final = await mutate('DELETE', pathA, null, tids[4])

await exportCar('', final)
lines.push('END')

await writeFile(output, `${lines.join('\n')}\n`)

// ── the batch transcript ────────────────────────────────────────────────────
// A SECOND, independent transcript in its own file. It is not appended to the
// one above because pds/test/repo_vectors_main.mdk and
// pds/test/record_handlers_main.mdk both match that corpus by exact positional
// row shape, so a row added to it is a breaking change to two drivers that have
// nothing to do with batching.
//
// The batch is generated the way the official library models one: N tree edits
// against a single MST, then ONE signCommit. That is the property under test —
// a batch of four operations must land as one signed commit at one revision,
// not four — so the answer key has to be built the same way rather than by
// replaying four single-write commits.

const batchStorage = new MemoryBlockstore()
let batchTree = await MST.create(batchStorage)
const batchRecords = new Map()
const batchTids = [0, 1].map((offset) => {
  const micros = 1700000000000000 + offset
  return { micros, clock: 7, text: TID.fromTime(micros, 7).toString() }
})

const batchLines = [
  '# Generated only by pds/tools/gen_repo_corpus.sh.',
  '# Official atproto repository/crypto reference; exact package routes are in VECTOR-PROVENANCE.txt.',
  `META\t${did}\t${secretHex}`,
  ...batchTids.map((tid) => `TID\t${tid.micros}\t${tid.clock}\t${tid.text}`),
]

const batchCommit = async (tag, rev) => {
  const { root, blocks } = await batchTree.getUnstoredBlocks()
  const unsigned = { did, version: 3, data: root, rev, prev: null }
  const unsignedBytes = cbor.encode(unsigned)
  const signed = await repoUtil.signCommit(unsigned, keypair)
  const signedBytes = cbor.encode(signed)
  const commitCid = await lexData.cidForCbor(signedBytes)
  batchLines.push(
    `${tag}\t${root}\t${hex(unsignedBytes)}\t${hex(signedBytes)}\t${commitCid}\t${hex(signed.sig)}`,
  )
  return { root, blocks, signedBytes, commitCid }
}

// The four operations of the batch, in the order a client would send them.
// Two rkey-less creates are deliberately NOT here: the record keys are all
// explicit, because an omitted rkey is the SERVER's derivation and not
// something the official library has an opinion about.
const batchOps = [
  { action: 'CREATE', path: 'app.bsky.feed.post/medaka-a', record: recordA },
  { action: 'CREATE', path: 'app.bsky.feed.post/medaka-b', record: recordB },
  { action: 'UPDATE', path: 'app.bsky.feed.post/medaka-a', record: recordA2 },
  { action: 'CREATE', path: 'app.bsky.feed.post/medaka-c', record: recordC },
]

await batchCommit('INIT', batchTids[0].text)

for (const op of batchOps) {
  let recordBytes = null
  let recordCid = null
  if (op.record !== null) {
    recordBytes = cbor.encode(op.record)
    recordCid = await lexData.cidForCbor(recordBytes)
    batchRecords.set(recordCid.toString(), { cid: recordCid, bytes: recordBytes })
  }
  if (op.action === 'CREATE') batchTree = await batchTree.add(op.path, recordCid)
  else if (op.action === 'UPDATE') batchTree = await batchTree.update(op.path, recordCid)
  else batchTree = await batchTree.delete(op.path)
  batchLines.push(
    `BATCHOP\t${op.action}\t${pathHex(op.path)}\t${recordBytes ? hex(recordBytes) : '-'}\t${recordCid ?? '-'}`,
  )
}

// ONE commit for the whole batch, at ONE revision.
const batchFinal = await batchCommit('BATCHCOMMIT', batchTids[1].text)

await batchStorage.putMany(batchFinal.blocks)
for (const record of batchRecords.values()) await batchStorage.putBlock(record.cid, record.bytes)
await batchStorage.putBlock(batchFinal.commitCid, batchFinal.signedBytes)

const batchChunks = []
for await (const chunk of provider.getFullRepo(batchStorage, batchFinal.commitCid)) {
  batchChunks.push(chunk)
}
const batchCarBytes = repoUtil.concatBytes(batchChunks)
const batchDecoded = await repo.readCarWithRoot(batchCarBytes)
batchLines.push(
  `BATCHCARORDER\t${batchDecoded.blocks.entries().map(({ cid }) => cid.toString()).join(',')}`,
)
batchLines.push(`BATCHCAR\t${hex(batchCarBytes)}`)
batchLines.push('END')

await writeFile(batchOutput, `${batchLines.join('\n')}\n`)
