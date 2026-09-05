#!/usr/bin/env node
// Generate the S-blob-core blob-CID/blob-ref corpus using the official
// TypeScript @atproto/lex-data + @atproto/lex-json reference implementations,
// from the committed exact dependency graph.

import { createHash } from 'node:crypto'
import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'

const [moduleRoot, output] = process.argv.slice(2)
if (!moduleRoot || !output) {
  throw new Error('usage: gen_blob_corpus.mjs <node_modules> <output>')
}

const lexData = await import(
  pathToFileURL(resolve(moduleRoot, '@atproto/lex-data/dist/index.js')).href
)
const lexJson = await import(
  pathToFileURL(resolve(moduleRoot, '@atproto/lex-json/dist/index.js')).href
)

const enc = new TextEncoder()

function sha256(bytes) {
  return new Uint8Array(createHash('sha256').update(bytes).digest())
}

function rawCid(bytes) {
  return lexData.createCid(
    lexData.RAW_DATA_CODEC,
    lexData.SHA256_HASH_CODE,
    sha256(bytes),
  )
}

// Representative payloads: empty, a short text blob, and an image-shaped
// MIME type over a slightly larger payload. Bytes are deterministic (no
// randomness), so the corpus is reproducible byte-for-byte on regeneration.
const cases = [
  ['empty', 'application/octet-stream', new Uint8Array()],
  ['small-text', 'text/plain', enc.encode('hello, blob')],
  [
    'image-shaped',
    'image/png',
    // Not a real PNG — this corpus only exercises content addressing and the
    // blob ref shape, not image format validation (no such validation exists
    // per this slice's mission: MIME-shape admission, not content sniffing).
    enc.encode('medaka-blob-corpus-image-shaped-payload'),
  ],
]

function hex(bytes) {
  return Buffer.from(bytes).toString('hex')
}

const lines = [
  '# Generated only by pds/tools/gen_blob_corpus.sh.',
  '# Official @atproto/lex-data + @atproto/lex-json reference; exact package routes are in VECTOR-PROVENANCE.txt.',
  '# Columns: case-name<TAB>mime-type<TAB>payload-bytes-hex<TAB>cid-string<TAB>blob-ref-json.',
]

for (const [name, mimeType, bytes] of cases) {
  const cid = rawCid(bytes)
  const blobRef = { $type: 'blob', ref: cid, mimeType, size: bytes.length }
  const json = lexJson.lexStringify(blobRef)

  // Self-verify against the reference's own type guard before emitting: a
  // row is never captured from a shape the reference library itself would
  // reject as a blob ref.
  const reparsed = lexJson.lexParse(json, { strict: true })
  if (!lexData.isTypedBlobRef(reparsed)) {
    throw new Error(`lex-data did not accept case ${name} as a typed blob ref`)
  }

  lines.push(`${name}\t${mimeType}\t${hex(bytes)}\t${cid.toString()}\t${json}`)
}

await writeFile(output, `${lines.join('\n')}\n`)
