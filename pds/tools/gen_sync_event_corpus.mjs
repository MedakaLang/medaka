#!/usr/bin/env node
// Derive two corpora from the pinned official PDS image: the exact wire bodies
// of the #identity/#account/#sync subscribeRepos events, and the CAR shapes
// sync.getRecord/sync.getBlocks answer for present/absent/partial inputs.
// Procedure to run this: pds/tools/gen_sync_event_corpus.sh.
//
// Every VALUE below comes from CALLING the pinned image's own installed code:
// sequencer/events.js's formatSeqIdentityEvt/formatSeqAccountEvt/
// formatSeqSyncEvt (the exact functions Sequencer.sequenceAccountCreation
// calls, read at pds/tools/gen_sync_event_corpus.sh's PDS_REVISION), and the
// same @atproto/repo primitives getRecord.js/getBlocks.js call
// (repo.getRecords, repo.blocksToCarStream, MemoryBlockstore.getBlocks) plus
// @atproto/xrpc-server's own InvalidRequestError for the refusal shape. No
// field set or value here is hand-assembled against a schema; each is read
// back off a real call into the pinned image.
//
// `seq` and `time` are NOT part of any body here (F1 in the packet: builders
// set neither; the wrapping Sequencer.sequenceEvts/subscribeRepos.js's
// `{seq, time, ...evt.evt}` splice is only a SHAPE fact, already pinned and
// not re-derived by this tool).

import { createHash } from 'node:crypto'
import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { mine } from './mst_depth.mjs'

const [output] = process.argv.slice(2)
if (!output) throw new Error('usage: gen_sync_event_corpus.mjs <output-dir>')

const PDS_DIST = '/app/node_modules/@atproto/pds/dist'
const STORE = '/app/node_modules/.pnpm'
const REPO_DIST = `${STORE}/@atproto+repo@0.10.10/node_modules/@atproto/repo/dist`
const CBOR_DIST = `${STORE}/@atproto+lex-cbor@0.1.6/node_modules/@atproto/lex-cbor/dist`
const LEXDATA_DIST = `${STORE}/@atproto+lex-data@0.1.7/node_modules/@atproto/lex-data/dist`
const CRYPTO_DIST = `${STORE}/@atproto+crypto@0.5.4/node_modules/@atproto/crypto/dist`
const XRPC_DIST = `${STORE}/@atproto+xrpc-server@0.12.3/node_modules/@atproto/xrpc-server/dist`

const load = (path) => import(pathToFileURL(path).href)

const events = await load(`${PDS_DIST}/sequencer/events.js`)
const { AccountStatus } = await load(`${PDS_DIST}/account-manager/helpers/account.js`)
const repo = await load(`${REPO_DIST}/index.js`)
const util = await load(`${REPO_DIST}/util.js`)
const cbor = await load(`${CBOR_DIST}/index.js`)
const lexData = await load(`${LEXDATA_DIST}/index.js`)
const crypto = await load(`${CRYPTO_DIST}/index.js`)
const xrpcErrors = await load(`${XRPC_DIST}/errors.js`)

const { formatSeqIdentityEvt, formatSeqAccountEvt, formatSeqSyncEvt, syncEvtDataFromCommit } = events
const { MST, MemoryBlockstore } = repo
const { InvalidRequestError } = xrpcErrors

const hex = (bytes) => Buffer.from(bytes).toString('hex')

// A fixed, exportable test key: the DID it derives is a value read back off
// the pinned image's own Secp256k1Keypair.did(), same technique as
// pds/tools/extract_pds_did_keys.mjs.
const secretHex = '0000000000000000000000000000000000000000000000000000000000000001'
const keypair = await crypto.Secp256k1Keypair.import(secretHex, { exportable: true })
const did = await keypair.did()

// ── #identity / #account bodies ─────────────────────────────────────────────
// formatSeqIdentityEvt/formatSeqAccountEvt take no repo state at all — call
// them directly, then decode `.event` back with the same lex-cbor the image
// itself encoded it with, so the recorded field set is read off the value,
// not assumed from source.

const identityWithHandle = await formatSeqIdentityEvt(did, 'medaka.example.invalid')
const identityNoHandle = await formatSeqIdentityEvt(did, undefined)
const accountActive = await formatSeqAccountEvt(did, AccountStatus.Active)
const accountInactive = await formatSeqAccountEvt(did, AccountStatus.Takendown)

const bodyLines = []
const brow = (...cells) => bodyLines.push(cells.join('\t'))
brow('# Generated only by pds/tools/gen_sync_event_corpus.mjs; see pds/tools/gen_sync_event_corpus.sh.')
brow('# Bodies from the pinned image\'s own sequencer/events.js builders (formatSeqIdentityEvt,')
brow('# formatSeqAccountEvt, formatSeqSyncEvt); exact package routes are in VECTOR-PROVENANCE.txt.')
brow('# Columns: TAG<TAB>event-cbor-hex<TAB>decoded-json.')
brow('#')
brow('# IDENTITY-WITH-HANDLE / IDENTITY-NO-HANDLE: formatSeqIdentityEvt(did, handle|undefined).')
brow('#   No `handle` KEY at all when absent (not present-with-null) -- see the decoded JSON.')
brow('# ACCOUNT-ACTIVE / ACCOUNT-INACTIVE: formatSeqAccountEvt(did, status). Active carries no')
brow('#   `status` key; inactive always carries both `active:false` and `status`.')
brow('# SYNC: formatSeqSyncEvt(did, syncEvtDataFromCommit(commitData)) over one signed commit;')
brow('#   `blocks` is a CAR rooted at and containing ONLY that commit block -- SYNC-CAR-ROOTS and')
brow('#   SYNC-CAR-BLOCKS record that shape directly rather than leaving it implicit in the hex.')
brow('# GENESIS-COMMIT-*: Repo.formatInitCommit(new MemoryBlockstore(), did, keypair, [], rev) --')
brow('#   a repository\'s FIRST commit over a brand-new EMPTY repo (zero records, zero ops). Its')
brow('#   relevantBlocks is what the #commit frame\'s `blocks` field carries, and for an empty repo')
brow('#   that is TWO blocks: the empty MST root node and the signed commit. A genesis CAR of the')
brow('#   commit alone does not verify -- the reader has no node for the data root it names. Not')
brow('#   the same case as the SYNC fixture above, whose repo already holds four records.')
brow('#')
brow('# `seq`/`time` are NOT part of any row: neither builder sets them (F1); they are spliced in')
brow('# only by subscribeRepos.js, a shape fact already pinned and not re-derived by this tool.')

// Uint8Array fields (SYNC's `blocks`) stringify as a per-index object under
// plain JSON.stringify; replace with a `<N bytes, sha256:...>` marker so the
// decoded column stays a field-shape summary -- the bytes themselves are
// already the row's own hex column, byte-identical by construction.
const summarizeBinary = (value) => {
  if (value instanceof Uint8Array) {
    return `<${value.byteLength} bytes, sha256:${createHash('sha256').update(value).digest('hex')}>`
  }
  if (Array.isArray(value)) return value.map(summarizeBinary)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, summarizeBinary(v)]))
  }
  return value
}

const bodyRow = (tag, wrapped) => {
  const decoded = cbor.decode(Buffer.from(wrapped.event))
  brow(tag, hex(wrapped.event), JSON.stringify(summarizeBinary(decoded)))
}
bodyRow('IDENTITY-WITH-HANDLE', identityWithHandle)
bodyRow('IDENTITY-NO-HANDLE', identityNoHandle)
bodyRow('ACCOUNT-ACTIVE', accountActive)
bodyRow('ACCOUNT-INACTIVE', accountInactive)

// The sync event needs a real signed commit -- build the repository with the
// pinned image's own MST/signCommit, exactly the primitives
// getFullRepo/getRecords use, then call syncEvtDataFromCommit the same way
// Sequencer.sequenceAccountCreation does.
//
// FOUR records, not one. A one-record repository's MST is a single node, and a
// single node makes every candidate read routine -- the descent path
// cidsForPath, the covering proof, the whole tree -- return the same block set,
// so the CAR-shape rows below could not tell them apart. The four keys are
// MINED to sit on MST layers 0/1/2/3 (mst_depth.mjs; a key's layer is a
// property of sha256(key), not a choice), which is the shallowest tree in which
// a getRecord answer names a real descent path.
const fixturePaths = [
  mine('app.bsky.feed.post/medaka-depth-0-', 0),
  mine('app.bsky.feed.post/medaka-depth-1-', 1),
  mine('app.bsky.feed.post/medaka-depth-2-', 2),
  mine('app.bsky.feed.post/medaka-depth-3-', 3),
]
// Distinct per key, so a route that answered a different record's block than
// the one asked for would name a different CID rather than the same one.
const fixtureRecordFor = (path) => ({
  $type: 'app.bsky.feed.post',
  text: `record at ${path}`,
  createdAt: '2026-09-01T00:00:00.000Z',
})

const storage = new MemoryBlockstore()
let tree = await MST.create(storage)
const fixtureCids = []
const fixtureRecordHex = []
for (const path of fixturePaths) {
  const bytes = cbor.encode(fixtureRecordFor(path))
  const cid = await lexData.cidForCbor(bytes)
  tree = await tree.add(path, cid)
  await storage.putBlock(cid, bytes)
  fixtureCids.push(cid)
  fixtureRecordHex.push(hex(bytes))
}

const { root, blocks: unstoredBlocks } = await tree.getUnstoredBlocks()
await storage.putMany(unstoredBlocks)
const rev = '3lhz6x6h6h623'
const unsignedCommit = { did, version: 3, rev, prev: null, data: root }
const signedCommit = await util.signCommit(unsignedCommit, keypair)
const signedCommitBytes = cbor.encode(signedCommit)
const commitCid = await lexData.cidForCbor(signedCommitBytes)
await storage.putBlock(commitCid, signedCommitBytes)

const relevantBlocks = await storage.getBlocks([commitCid])
if (relevantBlocks.missing.length > 0) throw new Error('commit block missing from storage')
const commitData = {
  cid: commitCid,
  rev,
  since: null,
  newBlocks: unstoredBlocks,
  relevantBlocks: relevantBlocks.blocks,
  ops: fixturePaths.map((path, i) => ({ action: 'create', path, cid: fixtureCids[i] })),
  prevData: undefined,
}
const syncData = syncEvtDataFromCommit(commitData)
const syncEvt = await formatSeqSyncEvt(did, syncData)
bodyRow('SYNC', syncEvt)

const syncDecoded = cbor.decode(Buffer.from(syncEvt.event))
const { roots: syncRoots, blocks: syncBlocks } = await repo.readCar(syncDecoded.blocks)
brow('SYNC-CAR-ROOTS', syncRoots.map((c) => c.toString()).join(','))
brow('SYNC-CAR-BLOCKS', [...syncBlocks.entries()].map((e) => e.cid.toString()).join(','))

// ── the genesis #commit's own blocks CAR ────────────────────────────────────
// A brand-new EMPTY repository, through Repo.formatInitCommit -- the call
// that produces the CommitData a repository's first #commit frame is built
// from. Its `relevantBlocks` is the frame's `blocks` field, CARred the same
// way (blocksToCarFile, rooted at the commit), so the row set below is the
// genesis CAR's shape read off the reference rather than reasoned about.
//
// Its own revision, distinct from the four-record fixture's above, so a driver
// that rebuilt the wrong repository could not match by reusing the other rev.
const genesisRev = '3lhz6x6h6h622'
const genesisCommit = await repo.Repo.formatInitCommit(new MemoryBlockstore(), did, keypair, [], genesisRev)
const genesisCar = await repo.blocksToCarFile(genesisCommit.cid, genesisCommit.relevantBlocks)
const { roots: genesisRoots, blocks: genesisBlocks } = await repo.readCar(genesisCar)
brow('GENESIS-COMMIT-REV', genesisRev)
brow('GENESIS-COMMIT-CAR-ROOTS', genesisRoots.map((c) => c.toString()).join(','))
brow('GENESIS-COMMIT-CAR-BLOCKS', [...genesisBlocks.entries()].map((e) => e.cid.toString()).join(','))
brow('END')

await writeFile(`${output}/pds_sync_event_bodies_corpus.txt`, bodyLines.join('\n') + '\n')

// ── sync.getRecord / sync.getBlocks CAR shapes ──────────────────────────────
// Drive the exact primitives getRecord.js/getBlocks.js call:
//   getRecord: repo.getRecords(storage, commitCid, [{collection, rkey}]) --
//     never throws for a missing record (a covering proof, not an error);
//     it throws only when the repo has no root at ALL, which is out of
//     scope here (F7; not one of the four required cases).
//   getBlocks: MemoryBlockstore.getBlocks(cids) -- getBlocks.js's own
//     all-or-nothing rule: ANY missing cid refuses the WHOLE request via
//     InvalidRequestError, never a partial CAR.

const carLines = []
const crow = (...cells) => carLines.push(cells.join('\t'))
crow('# Generated only by pds/tools/gen_sync_event_corpus.mjs; see pds/tools/gen_sync_event_corpus.sh.')
crow('# CAR shapes from the pinned image\'s own @atproto/repo (getRecords, blocksToCarStream) and')
crow('# @atproto/xrpc-server (InvalidRequestError) -- the exact primitives getRecord.js/getBlocks.js')
crow('# call. Repo: the four FIXTURE-RECORD-PATHS records, on MST layers 0/1/2/3; the two absent')
crow('# probe keys below were never written.')
crow('#')
crow('# FIXTURE-RECORD-PATHS / FIXTURE-RECORD-CBORS: the repository this corpus was computed over,')
crow('#   as parallel comma-separated lists in write order -- the only INPUT rows here. A consumer')
crow('#   rebuilds the repository from them and checks the commit CID it gets against')
crow('#   GETRECORD-PRESENT-D0-ROOT before grading a single answer.')
crow('# GETRECORD-PRESENT-D0..D3 / GETRECORD-ABSENT-BELOW / GETRECORD-ABSENT-MID: each probe names')
crow('#   the key it asked about in its own -PATH row, so a consumer takes the QUESTION from here')
crow('#   and supplies only the answer.')
crow('#   repo.getRecords(storage, commitCid, [path]) CAR bytes, one probe per MST layer plus two')
crow('#   keys that were never written -- one sorting below every present key and one between two')
crow('#   of them. All six succeed (200); the absent answers are covering proofs of non-membership,')
crow('#   never an error -- getRecord.js only throws when the repo has no root at all, which this')
crow('#   corpus does not exercise.')
crow('#   getRecords reaches MST.cidsForPath: the root-down DESCENT PATH to the key, carrying the')
crow('#   record CID inline when the key is present. It is NOT getCoveringProof, which is a separate')
crow('#   routine nothing on this call path reaches. A server answering with a covering proof')
crow('#   answers a SUPERSET of these blocks in a different order; what a consumer can claim')
crow('#   against these rows is therefore containment, not byte-identity, wherever the two shapes')
crow('#   diverge -- see pds/test/repo_vectors.sh, which derives that split per probe.')
crow('# GETBLOCKS-PRESENT: blocksToCarStream(null, blocks) for every stored CID -- ROOTS is the')
crow('#   EMPTY list (getBlocks never sets a CAR root), unlike GETRECORD\'s single commit root.')
crow('# GETBLOCKS-PARTLY-MISSING: same call, one requested CID absent from storage -- ALL-OR-')
crow('#   NOTHING: getBlocks.js refuses the whole request (400 InvalidRequest) rather than filling')
crow('#   a partial CAR, naming every missing CID. STATUS/ERROR/MESSAGE below are read off a real')
crow('#   InvalidRequestError instance, not transcribed from source.')
crow('#')
crow('# Columns vary per TAG; each block is self-describing.')

const carOf = async (chunks) => {
  const parts = []
  for await (const c of chunks) parts.push(c)
  return Buffer.concat(parts)
}

const recordCar = async (tag, rkey) => {
  const carBytes = await carOf(repo.getRecords(storage, commitCid, [{ collection: 'app.bsky.feed.post', rkey }]))
  const { root, blocks } = await repo.readCarWithRoot(carBytes)
  crow(`${tag}-PATH`, `app.bsky.feed.post/${rkey}`)
  crow(`${tag}-ROOT`, root.toString())
  crow(`${tag}-BLOCKS`, [...blocks.entries()].map((e) => e.cid.toString()).join(','))
  crow(`${tag}-CAR`, hex(carBytes))
}
const rkeyOf = (path) => path.slice(path.indexOf('/') + 1)
crow('FIXTURE-RECORD-PATHS', fixturePaths.join(','))
crow('FIXTURE-RECORD-CBORS', fixtureRecordHex.join(','))

for (let i = 0; i < fixturePaths.length; i++) {
  await recordCar(`GETRECORD-PRESENT-D${i}`, rkeyOf(fixturePaths[i]))
}
// Two never-written keys at different positions in the key order, because an
// absent read's descent path depends on where the key WOULD have gone: one
// sorting below every present key, one landing between the layer-1 and layer-2
// keys. `${...}zz` cannot collide with a mined key, whose suffix is decimal.
await recordCar('GETRECORD-ABSENT-BELOW', 'medaka-absent')
await recordCar('GETRECORD-ABSENT-MID', `${rkeyOf(fixturePaths[1])}zz`)

const allCids = [...(await storage.getBlocks([commitCid, fixtureCids[0]])).blocks.entries()].map((e) => e.cid)
const gotPresent = await storage.getBlocks(allCids)
if (gotPresent.missing.length > 0) throw new Error('unexpected missing blocks in getBlocks-present case')
const presentCarBytes = await carOf(repo.blocksToCarStream(null, gotPresent.blocks))
const { roots: presentRoots, blocks: presentCarBlocks } = await repo.readCar(presentCarBytes)
crow('GETBLOCKS-PRESENT-ROOTS', presentRoots.map((c) => c.toString()).join(','))
crow('GETBLOCKS-PRESENT-BLOCKS', [...presentCarBlocks.entries()].map((e) => e.cid.toString()).join(','))
crow('GETBLOCKS-PRESENT-CAR', hex(presentCarBytes))

const fakeCid = await lexData.cidForCbor(cbor.encode({ $type: 'medaka.neverStored', n: 1 }))
const partialCids = [...allCids, fakeCid]
const gotPartial = await storage.getBlocks(partialCids)
if (gotPartial.missing.length !== 1) throw new Error('expected exactly one missing cid in the partial case')
const missingStr = gotPartial.missing.map((c) => c.toString())
const refusal = new InvalidRequestError(`Could not find cids: ${missingStr}`)
crow('GETBLOCKS-PARTLY-MISSING-REQUESTED', partialCids.map((c) => c.toString()).join(','))
crow('GETBLOCKS-PARTLY-MISSING-MISSING', missingStr.join(','))
crow('GETBLOCKS-PARTLY-MISSING-STATUS', String(refusal.statusCode))
crow('GETBLOCKS-PARTLY-MISSING-ERROR', refusal.error)
crow('GETBLOCKS-PARTLY-MISSING-MESSAGE', refusal.errorMessage)
crow('END')

await writeFile(`${output}/pds_sync_car_shapes_corpus.txt`, carLines.join('\n') + '\n')

console.log(
  `sync event bodies: 4 events + 1 sync (${syncBlocks.entries().length} car block) + ` +
    `1 genesis commit (${genesisBlocks.entries().length} car blocks); ` +
    `car shapes: ${fixturePaths.length + 2} getRecord over a ${fixturePaths.length}-record repo + ` +
    `2 getBlocks (partial refusal status=${refusal.statusCode})`,
)
