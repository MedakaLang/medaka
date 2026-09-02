#!/usr/bin/env node
// Generate the P4-B lexicon-JSON<->DAG-CBOR corpus using the official
// TypeScript @atproto/lex-cbor + @atproto/lex-json + @atproto/lex-data
// reference implementations, from the committed exact dependency graph.

import { createHash } from 'node:crypto'
import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const [moduleRoot, output] = process.argv.slice(2)
if (!moduleRoot || !output) {
  throw new Error('usage: gen_lexjson_corpus.mjs <node_modules> <output>')
}

const lexCbor = await import(
  pathToFileURL(resolve(moduleRoot, '@atproto/lex-cbor/dist/index.js')).href
)
const lexJson = await import(
  pathToFileURL(resolve(moduleRoot, '@atproto/lex-json/dist/index.js')).href
)
const lexData = await import(
  pathToFileURL(resolve(moduleRoot, '@atproto/lex-data/dist/index.js')).href
)

const enc = new TextEncoder()

function sha256(bytes) {
  return new Uint8Array(createHash('sha256').update(bytes).digest())
}

function rawCid(seedBytes) {
  return lexData.createCid(
    lexData.RAW_DATA_CODEC,
    lexData.SHA256_HASH_CODE,
    sha256(seedBytes),
  )
}

function cborCid(seedBytes) {
  return lexData.createCid(
    lexData.CBOR_DATA_CODEC,
    lexData.SHA256_HASH_CODE,
    sha256(seedBytes),
  )
}

const linkRaw = rawCid(enc.encode('medaka-lexjson-link-raw'))
const linkCbor = cborCid(enc.encode('medaka-lexjson-link-cbor'))
const bytesLong = sha256(enc.encode('medaka-lexjson-bytes-long'))

const cases = [
  ['null', null],
  ['bool-true', true],
  ['bool-false', false],
  ['int-zero', 0],
  ['int-positive', 12345],
  ['int-negative', -98765],
  ['int-large', 9007199254740991],
  ['bytes-empty', new Uint8Array()],
  ['bytes-short', new Uint8Array([1, 2, 3])],
  ['bytes-long', bytesLong],
  ['string-basic', 'hello, world'],
  ['string-unicode', '水 𝄞'],
  ['array-nested', [1, 'two', [3, null], true]],
  ['map-basic', { a: 1, b: 'two', c: true }],
  ['map-nested', { outer: { inner: [1, 2, 3] } }],
  ['link-raw', linkRaw],
  ['link-cbor', linkCbor],
  [
    // Field order matches DAG-CBOR's canonical map-key order (shortest key
    // first, then lexicographic: "ref" < "blob" < "name") so the reference
    // JSON text — which JS serializes in plain insertion order — agrees
    // byte-for-byte with what decoding the canonical DAG-CBOR bytes and
    // re-rendering as JSON produces. JSON objects have no required key
    // order (this row asserts insertion order, not a mandated one), but
    // this corpus is compared by exact JSON text, so the two orderings are
    // deliberately aligned here.
    'map-with-bytes-and-link',
    { ref: linkCbor, blob: new Uint8Array([9, 8, 7]), name: 'combo' },
  ],
]

function hex(bytes) {
  return Buffer.from(bytes).toString('hex')
}

const lines = [
  '# Generated only by pds/tools/gen_lexjson_corpus.sh.',
  '# Official @atproto/lex-cbor + @atproto/lex-json + @atproto/lex-data reference; exact package routes are in VECTOR-PROVENANCE.txt.',
  '# Columns: case-name<TAB>canonical-dagcbor-hex<TAB>lexicon-json-text.',
]

for (const [name, value] of cases) {
  const cbor = lexCbor.encode(value)
  const json = lexJson.lexStringify(value)

  // Round-trip sanity against the reference implementation itself, so a
  // corpus row is never captured from a value the reference libraries
  // themselves cannot reproduce.
  const decoded = lexCbor.decode(cbor)
  const reencoded = lexCbor.encode(decoded)
  if (Buffer.compare(reencoded, cbor) !== 0) {
    throw new Error(`lex-cbor did not round-trip case ${name}`)
  }
  const reparsed = lexJson.lexParse(json, { strict: true })
  if (lexJson.lexStringify(reparsed) !== json) {
    throw new Error(`lex-json did not round-trip case ${name}`)
  }

  lines.push(`${name}\t${hex(cbor)}\t${json}`)
}

await writeFile(output, `${lines.join('\n')}\n`)
