#!/usr/bin/env node
// Generate P1-D repository transcript bytes with pinned official atproto code.

import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const [moduleRoot, output, batchOutput, eventOutput, lexiconPath] = process.argv.slice(2)
if (!moduleRoot || !output || !batchOutput || !eventOutput || !lexiconPath) {
  throw new Error(
    'usage: gen_repo_corpus.mjs <node_modules> <output> <batch-output> <event-output> <lexicon-json>',
  )
}

const repo = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/index.js')).href)
const repoUtil = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/util.js')).href)
const provider = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/sync/provider.js')).href)
const cbor = await import(pathToFileURL(resolve(moduleRoot, '@atproto/lex-cbor/dist/index.js')).href)
const lexData = await import(pathToFileURL(resolve(moduleRoot, '@atproto/lex-data/dist/index.js')).href)
const commonWeb = await import(pathToFileURL(resolve(moduleRoot, '@atproto/common-web/dist/index.js')).href)
const crypto = await import(pathToFileURL(resolve(moduleRoot, '@atproto/crypto/dist/secp256k1/keypair.js')).href)
const carMod = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/car.js')).href)

const { MST, MemoryBlockstore, BlockMap, DataDiff } = repo
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

// ── the #commit firehose transcript ─────────────────────────────────────────
// A THIRD, independent transcript in its own file, for the same reason the
// batch one above is separate: the first output is matched positionally by two
// other drivers, so a row added to it breaks them.
//
// This one grades the SYNC lexicon's `#commit` event, which is a different
// schema from the repository commit object the transcripts above pin. No
// official package on the pinned graph assembles that event — @atproto/pds is
// the only one that does and it needs a newer @atproto/repo plus a database and
// a web server — so the ASSEMBLY here is hand-derived against the pinned
// lexicon JSON and the published sequencer source, while every VALUE it
// assembles (the MST, the covering proofs, the diff, the signature, the commit
// bytes, the CAR framing and the DAG-CBOR encoding) comes from the pinned
// official packages.
//
// The transcript climbs to a three-layer MST before it writes anything
// interesting, because on a one-node tree every candidate rule for `blocks`
// returns the same answer and the corpus would grade nothing. Steps 2 and 4
// are the discriminating ones: their `blocks` contain MST nodes the write did
// not itself change.

const lexicon = JSON.parse(await readFile(lexiconPath, 'utf8'))
const commitDef = lexicon.defs?.commit
const repoOpDef = lexicon.defs?.repoOp
if (!commitDef || !repoOpDef) {
  throw new Error(`${lexiconPath} has no commit/repoOp def`)
}

// Grades one assembled event against the pinned lexicon: every required key
// present, every absent key genuinely optional, nothing invented, and null
// used only where the schema declares nullability. A field-name typo is
// otherwise invisible — it would encode cleanly and be graded against itself.
const checkAgainstLexicon = (def, value, label) => {
  const declared = Object.keys(def.properties)
  const nullable = def.nullable ?? []
  const present = Object.keys(value).filter((k) => value[k] !== undefined)
  for (const key of def.required) {
    if (!present.includes(key)) throw new Error(`${label}: required key ${key} is absent`)
  }
  for (const key of present) {
    if (!declared.includes(key)) throw new Error(`${label}: key ${key} is not in the lexicon`)
    if (value[key] === null && !nullable.includes(key)) {
      throw new Error(`${label}: key ${key} is null but not declared nullable`)
    }
  }
}

const eventDepth = (key) => {
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
const mineKey = (prefix, depth) => {
  for (let i = 0; ; i++) {
    const key = `${prefix}${i}`
    if (eventDepth(key) === depth) return key
  }
}

const evtKeys = [
  mineKey('app.bsky.feed.post/evt-a-', 0),
  mineKey('app.bsky.feed.post/evt-b-', 1),
  mineKey('app.bsky.feed.post/evt-c-', 0),
  mineKey('app.bsky.feed.post/evt-d-', 2),
  mineKey('app.bsky.feed.post/evt-e-', 0),
]

const post = (text, second) => ({
  $type: 'app.bsky.feed.post',
  text,
  createdAt: `2026-09-01T00:00:0${second}.000Z`,
})

// Each step is one signed commit. Step 7 is a batch: three operations, one
// commit, one revision — the shape that makes the `ops` array plural and the
// covering proof a union over three keys.
const evtSteps = [
  [['create', evtKeys[0], post('a', 0)]],
  [['create', evtKeys[1], post('b', 1)]],
  [['create', evtKeys[2], post('c', 2)]],
  [['create', evtKeys[3], post('d', 3)]],
  [['update', evtKeys[0], post('a-updated', 0)]],
  [['delete', evtKeys[2], null]],
  [
    ['create', evtKeys[4], post('e', 4)],
    ['update', evtKeys[1], post('b-updated', 1)],
    ['delete', evtKeys[3], null],
  ],
]

const eventLines = [
  '# Generated only by pds/tools/gen_repo_corpus.sh.',
  '# Official atproto repository/crypto reference; exact package routes are in VECTOR-PROVENANCE.txt.',
  `META\t${did}\t${secretHex}`,
]

const evtStorage = new MemoryBlockstore()
let evtTree = await MST.create(evtStorage)
const liveRecordCid = new Map()

const evtTid = (offset) => TID.fromTime(1700000000000000 + offset, 7).toString()

const signAt = async (rev, dataCid) => {
  const unsigned = { did, version: 3, rev, prev: null, data: dataCid }
  const signed = await repoUtil.signCommit(unsigned, keypair)
  const bytes = cbor.encode(signed)
  return { bytes, cid: await lexData.cidForCbor(bytes) }
}

let evtRev = evtTid(0)
let evtData = await evtTree.getPointer()
let evtCommit = await signAt(evtRev, evtData)
eventLines.push(`INIT\t${evtRev}\t${evtCommit.cid}\t${evtData}`)

for (let i = 0; i < evtSteps.length; i++) {
  const operations = evtSteps[i]
  const seq = i + 1
  const rev = evtTid(seq)
  const time = `2026-09-11T12:00:0${seq}.000Z`
  const since = evtRev
  const prevData = evtData
  const before = evtTree

  eventLines.push(`STEP\t${seq}\t${rev}\t${time}`)

  const ops = []
  const addedLeaves = new BlockMap()
  const touched = []
  for (const [action, key, record] of operations) {
    const prevCid = liveRecordCid.get(key) ?? null
    let recordBytes = null
    let recordCid = null
    if (record !== null) {
      recordBytes = cbor.encode(record)
      recordCid = await lexData.cidForCbor(recordBytes)
      addedLeaves.set(recordCid, recordBytes)
      evtTree = action === 'create' ? await evtTree.add(key, recordCid) : await evtTree.update(key, recordCid)
      liveRecordCid.set(key, recordCid)
    } else {
      evtTree = await evtTree.delete(key)
      liveRecordCid.delete(key)
    }
    touched.push(key)
    const op = { action, path: key, cid: recordCid }
    // `prev` is ABSENT on a create and present otherwise; it is not a nullable
    // field. @atproto/pds's transactor sets it from the current record, so a
    // create — which has none — leaves the key off the map entirely.
    if (prevCid) op.prev = prevCid
    checkAgainstLexicon(repoOpDef, op, `step ${seq} op ${key}`)
    ops.push(op)
    eventLines.push(
      `OP\t${action}\t${pathHex(key)}\t${recordBytes ? hex(recordBytes) : '-'}\t${recordCid ?? '-'}\t${prevCid ?? '-'}`,
    )
  }

  const dataCid = await evtTree.getPointer()
  const diff = await DataDiff.of(evtTree, before)
  const sendBlocks = new BlockMap()
  sendBlocks.addMap(diff.newMstBlocks)
  const added = addedLeaves.getMany(diff.newLeafCids.toList())
  if (added.missing.length > 0) throw new Error(`step ${seq}: missing leaf blocks`)
  sendBlocks.addMap(added.blocks)
  // The covering proofs are taken over the POST-write tree, for every key the
  // write touched. That receiver is the whole point: over the pre-write tree
  // they would name nodes this commit has already replaced.
  for (const key of touched) sendBlocks.addMap(await evtTree.getCoveringProof(key))
  const commit = await signAt(rev, dataCid)
  sendBlocks.set(commit.cid, commit.bytes)

  const referenceCar = await carMod.blocksToCarFile(commit.cid, sendBlocks)
  const sortedMap = new BlockMap()
  const sortedEntries = [...sendBlocks.entries()].sort((l, r) => (l.cid.toString() < r.cid.toString() ? -1 : 1))
  for (const entry of sortedEntries) sortedMap.set(entry.cid, entry.bytes)
  const sortedCar = await carMod.blocksToCarFile(commit.cid, sortedMap)
  const blockCids = sortedEntries.map((entry) => entry.cid.toString())

  const evt = {
    seq,
    rebase: false,
    tooBig: false,
    repo: did,
    commit: commit.cid,
    rev,
    since,
    blocks: referenceCar,
    ops,
    blobs: [],
    prevData,
    time,
  }
  checkAgainstLexicon(commitDef, evt, `step ${seq} event`)
  const header = cbor.encode({ op: 1, t: '#commit' })
  const frame = Buffer.concat([Buffer.from(header), Buffer.from(cbor.encode(evt))])
  const sortedFrame = Buffer.concat([
    Buffer.from(header),
    Buffer.from(cbor.encode({ ...evt, blocks: sortedCar })),
  ])
  if (frame.length !== sortedFrame.length) {
    throw new Error(`step ${seq}: reordering blocks changed the frame length`)
  }

  eventLines.push(`EXPECT\t${commit.cid}\t${dataCid}\t${since}\t${prevData}`)
  eventLines.push(`BLOCKS\t${blockCids.join(',')}`)
  eventLines.push(`CAR\t${hex(referenceCar)}`)
  eventLines.push(`EVENT\t${hex(frame)}`)
  eventLines.push(`EVENTSORTED\t${hex(sortedFrame)}`)
  eventLines.push('ENDSTEP')

  evtRev = rev
  evtData = dataCid
  evtCommit = commit
}

eventLines.push('END')
await writeFile(eventOutput, `${eventLines.join('\n')}\n`)
