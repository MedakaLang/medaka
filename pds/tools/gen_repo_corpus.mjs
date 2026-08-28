#!/usr/bin/env node
// Generate P1-D repository transcript bytes with pinned official atproto code.

import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const [moduleRoot, output] = process.argv.slice(2)
if (!moduleRoot || !output) throw new Error('usage: gen_repo_corpus.mjs <node_modules> <output>')

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
