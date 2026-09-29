#!/usr/bin/env node
// Derive the record-validation answer key from the pinned official PDS image:
// (1) every knownSchemas record schema of repo/prepare.js plus every def they
// reach, as Lexicon-shaped JSON read off the compiled lex-schema objects, and
// (2) for each hand-authored input row in lexicon_cases.jsonl, the verdict the
// reference's own validateRecord gives. No verdict or schema constraint here is
// hand-written; inputs are the only authored data.
// Procedure to run this: pds/tools/gen_lexicon_corpus.sh.

import { readdirSync, readFileSync, statSync } from 'node:fs'
import { writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'

const [vectorsDir, output] = process.argv.slice(2)
if (!vectorsDir || !output) {
  throw new Error('usage: gen_lexicon_corpus.mjs <vectors-dir> <output-dir>')
}

const PDS_PKG =
  '/app/node_modules/.pnpm/@atproto+pds@0.5.27/node_modules/@atproto/pds'
const LEX = `${PDS_PKG}/dist/lexicons`
const { app, chat, com } = await import(`${LEX}/index.js`)
const { jsonToLex } = await import(
  '/app/node_modules/.pnpm/@atproto+lex-json@0.1.6/node_modules/@atproto/lex-json/dist/index.js'
)

// The exact list of repo/prepare.js's knownSchemas.
const known = [
  app.bsky.actor.profile,
  app.bsky.actor.status,
  app.bsky.feed.generator,
  app.bsky.feed.like,
  app.bsky.feed.post,
  app.bsky.feed.postgate,
  app.bsky.feed.repost,
  app.bsky.feed.threadgate,
  app.bsky.graph.block,
  app.bsky.graph.follow,
  app.bsky.graph.list,
  app.bsky.graph.listblock,
  app.bsky.graph.listitem,
  app.bsky.graph.starterpack,
  app.bsky.graph.verification,
  app.bsky.labeler.service,
  app.bsky.notification.declaration,
  chat.bsky.actor.declaration,
  com.atproto.lexicon.schema,
  com.germnetwork.declaration,
].map((m) => m.main)
const knownSchemas = new Map(known.map((s) => [s.$type, s]))

// Identity registry: every exported def of every *.defs.js. Several exports
// can be one shared instance (a token type); the first name in directory
// order keeps it, so the name is deterministic.
function defsFiles(d) {
  let out = []
  for (const f of readdirSync(d).sort()) {
    const p = `${d}/${f}`
    if (statSync(p).isDirectory()) out = out.concat(defsFiles(p))
    else if (p.endsWith('.defs.js')) out.push(p)
  }
  return out
}
const registry = new Map()
for (const p of defsFiles(LEX)) {
  const ns = await import(pathToFileURL(p).href)
  if (!ns.$nsid) continue
  for (const [k, v] of Object.entries(ns)) {
    if (k.startsWith('$') || v == null || typeof v !== 'object' || !v.type) continue
    if (!registry.has(v)) registry.set(v, `${ns.$nsid}#${k}`)
  }
}

const reached = new Map()
const strip = (o) => {
  const r = {}
  for (const [k, x] of Object.entries(o)) if (x !== undefined) r[k] = x
  return r
}
const isOptional = (v) =>
  v.constructor.name === 'OptionalSchema' ||
  v.constructor.name === 'WithDefaultSchema'

function refTo(v) {
  const n = registry.get(v)
  if (!n) throw new Error(`unregistered def: ${v.constructor.name}`)
  if (!reached.has(n)) {
    reached.set(n, null)
    reached.set(n, defOf(v))
  }
  return n
}
function shapeOf(o) {
  const required = Object.keys(o.shape).filter((k) => !isOptional(o.shape[k]))
  const properties = {}
  for (const k of Object.keys(o.shape)) properties[k] = typeOf(o.shape[k])
  return { type: 'object', required, properties }
}
function typeOf(v) {
  switch (v.constructor.name) {
    case 'StringSchema': return strip({ type: 'string', ...v.options })
    case 'IntegerSchema': return strip({ type: 'integer', ...v.options })
    case 'BooleanSchema': return { type: 'boolean' }
    case 'BytesSchema': return strip({ type: 'bytes', ...v.options })
    case 'BlobSchema': return strip({ type: 'blob', ...v.options })
    case 'LiteralSchema': return { type: 'literal', const: v.value }
    case 'ArraySchema': return strip({ type: 'array', items: typeOf(v.validator), ...v.options })
    case 'OptionalSchema': return typeOf(v.validator)
    case 'WithDefaultSchema': return { ...typeOf(v.validator), default: v.defaultValue }
    case 'RefSchema': return { type: 'ref', ref: refTo(v.validator) }
    case 'TypedRefSchema': return { type: 'ref', ref: refTo(v.schema ?? v.validator) }
    case 'TypedUnionSchema': return { type: 'union', refs: v.validators.map((x) => typeOf(x).ref), closed: v.closed }
    case 'ObjectSchema': return shapeOf(v)
    case 'TypedObjectSchema': return shapeOf(v.schema ?? v.validator)
    default: throw new Error(`unhandled schema class: ${v.constructor.name}`)
  }
}
function defOf(v) {
  if (v.constructor.name === 'RecordSchema') {
    return { type: 'record', key: v.key, record: shapeOf(v.schema) }
  }
  return typeOf(v)
}
for (const s of known) refTo(s)
const schemas = {}
for (const k of [...reached.keys()].sort()) schemas[k] = reached.get(k)

// A case's record may hold {"$repeat":[unit,count]} (the string unit repeated
// count times) or {"$times":[value,count]} (an array of count copies), so long
// inputs stay readable in the cases file.
function expand(v) {
  if (Array.isArray(v)) return v.map(expand)
  if (v && typeof v === 'object') {
    const ks = Object.keys(v)
    if (ks.length === 1 && ks[0] === '$repeat') return v.$repeat[0].repeat(v.$repeat[1])
    if (ks.length === 1 && ks[0] === '$times') {
      return Array.from({ length: v.$times[1] }, () => expand(v.$times[0]))
    }
    // defineProperty, not assignment: `r["__proto__"] = x` would set the
    // prototype and drop the key, so the judged record would differ from the
    // input and from the stored row.
    const r = {}
    for (const k of ks) {
      Object.defineProperty(r, k, {
        value: expand(v[k]), enumerable: true, writable: true, configurable: true,
      })
    }
    return r
  }
  return v
}

// repo/prepare.js validateRecord with validate:true.
// jsonToLex's own refusals (e.g. `Invalid key: __proto__`) are thrown before
// validateRecord runs; a request carrying such a record gets that refusal.
function verdict(rkey, jsonRecord) {
  let record
  try {
    record = jsonToLex(jsonRecord)
  } catch (e) {
    return ['error', e.message]
  }
  const schema = knownSchemas.get(record.$type)
  if (!schema) return ['error', `Unknown lexicon type: ${record.$type}`]
  const k = schema.keySchema.safeValidate(rkey)
  if (!k.success) {
    return ['error', `Invalid record key for ${record.$type}: ${k.reason.message}`]
  }
  const r = schema.safeValidate(record, { path: ['record'] })
  if (!r.success) {
    return ['error', `Invalid ${record.$type} record: ${r.reason.message}`]
  }
  return ['ok', '']
}

const rows = []
const ids = new Set()
for (const line of readFileSync(`${vectorsDir}/lexicon_cases.jsonl`, 'utf8').split('\n')) {
  if (!line) continue
  const c = JSON.parse(line)
  if (ids.has(c.id)) throw new Error(`duplicate case id ${c.id}`)
  ids.add(c.id)
  const record = expand(c.record)
  const [v, message] = verdict(c.rkey, record)
  rows.push(JSON.stringify({ id: c.id, collection: c.collection, rkey: c.rkey, record, verdict: v, message }))
}

const meta = [
  '# lexicon answer key generator record',
  'image-tag:    ghcr.io/bluesky-social/pds:0.4',
  `image-digest: ${process.env.PDS_IMAGE_DIGEST ?? 'unset'}`,
  'package:      @atproto/pds@0.5.27',
  `node:         ${process.version}`,
  `schemas:      ${Object.keys(schemas).length} defs, ${known.length} of them knownSchemas records`,
  `rows:         ${rows.length}`,
  '',
].join('\n')

await writeFile(`${output}/lexicon_schemas.json`, `${JSON.stringify(schemas, null, 1)}\n`)
await writeFile(`${output}/lexicon_record_corpus.jsonl`, `${rows.join('\n')}\n`)
await writeFile(`${output}/lexicon_corpus.meta`, meta)
