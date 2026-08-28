#!/usr/bin/env node
// Generate the P1-C CAR corpus with the pinned official @atproto/repo package.

import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const [moduleRoot, output] = process.argv.slice(2)
if (!moduleRoot || !output) {
  throw new Error('usage: gen_car_corpus.mjs <node_modules> <output>')
}

const car = await import(pathToFileURL(resolve(moduleRoot, '@atproto/repo/dist/car.js')).href)
const lexData = await import(pathToFileURL(resolve(moduleRoot, '@atproto/lex-data/dist/index.js')).href)

const rootBytes = Uint8Array.of(0xa1, 0x61, 0x6e, 0x01)
const extraBytes = new TextEncoder().encode('medaka-car-unrelated')
const root = await lexData.cidForCbor(rootBytes)
const extra = await lexData.cidForRawBytes(extraBytes)
const blocks = [
  { cid: root, bytes: rootBytes },
  { cid: extra, bytes: extraBytes },
]

async function* blockStream() {
  yield* blocks
}

const chunks = []
for await (const chunk of car.writeCarStream(root, blockStream())) chunks.push(chunk)
const size = chunks.reduce((total, chunk) => total + chunk.byteLength, 0)
const bytes = new Uint8Array(size)
let offset = 0
for (const chunk of chunks) {
  bytes.set(chunk, offset)
  offset += chunk.byteLength
}

const decoded = await car.readCarWithRoot(bytes)
if (!decoded.root.equals(root) || decoded.blocks.size !== 2) {
  throw new Error('official CAR writer/reader did not round-trip generated fixture')
}

const hex = (value) => Buffer.from(value).toString('hex')
const lines = [
  '# Generated only by pds/tools/gen_car_corpus.sh.',
  '# Official atproto repository reference; exact package routes are in VECTOR-PROVENANCE.txt.',
  'CASE\tofficial-atproto-basic',
  `ROOT\t${root.toString()}`,
  ...blocks.map((block) => `BLOCK\t${block.cid.toString()}\t${hex(block.bytes)}`),
  `CAR\t${hex(bytes)}`,
  'END',
]

await writeFile(output, `${lines.join('\n')}\n`)
