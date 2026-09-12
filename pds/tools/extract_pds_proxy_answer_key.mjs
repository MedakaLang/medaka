#!/usr/bin/env node
// Derive three corpora from the pinned official PDS image: which XRPC methods it
// registers locally, the methods it refuses to proxy or service-auth at all, and
// the wire shape of the inter-service credential it mints for a proxied call.
// Procedure to run this: pds/README.md, "Proxy answer key".
//
// The route table is produced by RUNNING the image's own dist/api/index.js
// against a recording stub server, twice -- once with an appview configured and
// once without -- so the `if (!bskyAppView) return` registration gates are
// observed rather than read off. Anything absent from that set is served, if at
// all, by the catch-all proxyHandler, whose target is pipethrough.js's
// defaultService.
//
// The third column is each route module's imported proxy helpers, read from the
// image's own source. That is a derived fact rather than a verdict: which helper
// a module imports is exactly what distinguishes a handler that answers from
// PDS-local state from one that forwards, and the corpus header states the
// mapping so a reader draws the verdict from the evidence.
//
// The protected list is READ OUT of the image's own pipethrough module rather
// than transcribed: PROTECTED_METHODS is an LxmSet whose iterator yields the
// lexicon constants it was built from, so the corpus is that set's own members
// in its own spelling. A transcription could go stale against the image without
// anything noticing; this cannot.
//
// The credential shape is produced by calling the same createServiceJwt the
// image's AppContext.serviceAuthJwt() calls. `iat` is pinned by the caller and
// `jti` is fresh random per mint, so the corpus records jti's shape rather than
// a value, and the signature's encoding rather than a signature: both corpora
// are byte-reproducible, which a pinned token string could not be.

import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const [output, iatArg] = process.argv.slice(2)
if (!output || !iatArg) {
  throw new Error('usage: extract_pds_proxy_answer_key.mjs <output-dir> <pinned-iat>')
}
const IAT = Number(iatArg)
if (!Number.isInteger(IAT)) throw new Error(`pinned-iat must be an integer: ${iatArg}`)

const store = '/app/node_modules/.pnpm'
const required = [
  ['@atproto/pds', '0.5.27'],
  ['@atproto/xrpc-server', '0.12.3'],
  ['@atproto/crypto', '0.5.4'],
]

// Same version-pinning discipline as extract_pds_phase1_corpora.mjs: resolve each
// package out of the image's pnpm store and refuse if the manifest disagrees, so
// a future image can never silently answer a different question.
const findPackage = async (name, version) => {
  const candidate = join(store, `${name.replace('/', '+')}@${version}`, 'node_modules', ...name.split('/'))
  const manifest = JSON.parse(await readFile(join(candidate, 'package.json'), 'utf8'))
  if (manifest.name !== name || manifest.version !== version) {
    throw new Error(`image package mismatch for ${name}@${version}`)
  }
  return candidate
}
const resolved = {}
for (const [name, version] of required) resolved[name] = await findPackage(name, version)

const load = (name, sub) => import(pathToFileURL(join(resolved[name], sub)).href)

// ── route registration ──────────────────────────────────────────────────────

// The route modules read far more of ctx than registration needs. A proxy that
// answers every property access with another callable proxy lets the real
// registration code run untouched; only the two knobs that GATE registration
// (ctx.bskyAppView, ctx.cfg.bskyAppView) carry real values.
const anything = () =>
  new Proxy(function () {}, {
    get: (_t, prop) => (prop === 'then' || prop === Symbol.toPrimitive ? undefined : anything()),
    apply: () => anything(),
  })

const APPVIEW = { url: 'http://127.0.0.1:9', did: 'did:web:appview.invalid' }

const registeredWith = async (appView) => {
  const { default: registerRoutes } = await load('@atproto/pds', 'dist/api/index.js')
  const seen = []
  const server = {
    add: (def) => seen.push(def?.$lxm ?? String(def)),
    streamMethod: (nsid) => seen.push(nsid),
  }
  const withReal = (real) => new Proxy(real, { get: (t, p) => (p in t ? t[p] : anything()) })
  registerRoutes(server, withReal({ bskyAppView: appView, cfg: withReal({ bskyAppView: appView }) }))
  return seen.sort()
}

const bare = await registeredWith(undefined)
const full = await registeredWith(APPVIEW)
const bareSet = new Set(bare)

// Each route module sits at dist/api/<nsid with dots as slashes>.js, with the
// retired sync methods one level deeper under deprecated/.
const HELPERS = ['pipethroughReadAfterWrite', 'pipethrough', 'serviceAuthHeaders']
const proxyHelpers = async (nsid) => {
  const parts = nsid.split('.')
  const leaf = parts.pop()
  const base = join(resolved['@atproto/pds'], 'dist/api', ...parts)
  let source
  for (const candidate of [join(base, `${leaf}.js`), join(base, 'deprecated', `${leaf}.js`)]) {
    try {
      source = await readFile(candidate, 'utf8')
      break
    } catch {
      /* try the next candidate */
    }
  }
  if (source === undefined) return 'no-module-file'
  const found = HELPERS.filter((h) => source.includes(h))
  // pipethroughReadAfterWrite contains pipethrough as a substring; the longest
  // match is the one that describes the module.
  if (found.includes('pipethroughReadAfterWrite')) {
    return found.filter((h) => h !== 'pipethrough').join(',')
  }
  return found.length ? found.join(',') : '-'
}

// ── service-auth credential ─────────────────────────────────────────────────

const { createServiceJwt } = await load('@atproto/xrpc-server', 'dist/auth.js')
const { Secp256k1Keypair, P256Keypair } = await load('@atproto/crypto', 'dist/index.js')

const keypair = await Secp256k1Keypair.create({ exportable: true })
const p256 = await P256Keypair.create({ exportable: true })

const ISS = 'did:plc:issueraccountplaceholder'
const AUD = 'did:web:appview.invalid'
const LXM = 'app.bsky.feed.getTimeline'

const b64json = (b) => JSON.parse(Buffer.from(b, 'base64url').toString('utf8'))
const mint = async (params) => {
  const jwt = await createServiceJwt({ iss: ISS, aud: AUD, keypair, iat: IAT, ...params })
  const [h, p, s] = jwt.split('.')
  return { headerSeg: h, header: b64json(h), payload: b64json(p), sigSeg: s }
}
const withLxm = await mint({ lxm: LXM })
const noLxm = await mint({})

// ── emit ────────────────────────────────────────────────────────────────────

const rows = []
const row = (...cells) => rows.push(cells.join('\t'))

row('# Generated only by pds/tools/extract_pds_proxy_answer_key.mjs; see pds/README.md.')
row('# Registration observed by running the pinned image\'s own dist/api/index.js against a')
row('# recording stub server; exact package routes are in VECTOR-PROVENANCE.txt.')
row('# Columns: nsid<TAB>registration<TAB>proxy-helpers-imported.')
row('#')
row('# registration   always         registered unconditionally')
row('#                appview-gated  registered only when PDS_BSKY_APP_VIEW_URL/DID are set')
row('#')
row('# An nsid ABSENT FROM THIS FILE is not registered at all and reaches the catch-all')
row('# proxyHandler, which forwards it to pipethrough.js defaultService -- bsky_appview for')
row('# everything except the enumerated tools.ozone (atproto_labeler) and')
row('# com.atproto.moderation.createReport cases. With no such service configured the oracle')
row('# answers 400 InvalidRequest "No service configured for <nsid>", which is the SAME answer')
row('# it gives for an nsid in no lexicon at all: an HTTP probe cannot distinguish')
row('# "forwarded" from "does not exist".')
row('#')
row('# proxy-helpers-imported is read from the route module\'s own source and is how a local')
row('# handler is told from a forwarding one:')
row('#   -                          answers entirely from PDS-local state')
row('#   pipethrough                answers locally for some requests and forwards others,')
row('#                              deciding per request -- getPreferences/putPreferences')
row('#                              forward only when an atproto-proxy header names a service')
row('#                              other than the configured appview, while repo.getRecord')
row('#                              forwards when this PDS does not host the repo at all.')
row('#                              Read the module to see which rule applies.')
row('#   pipethroughReadAfterWrite  forwards to the appview, then patches the response with')
row('#                              the caller\'s own not-yet-indexed writes')
row('#   serviceAuthHeaders         calls the target service itself, with a service-auth bearer')
for (const nsid of full) {
  row(nsid, bareSet.has(nsid) ? 'always' : 'appview-gated', await proxyHelpers(nsid))
}
await writeFile(join(output, 'pds_route_registration_corpus.txt'), rows.join('\n') + '\n')

// ── the protected list ──────────────────────────────────────────────────────

const { PROTECTED_METHODS } = await load('@atproto/pds', 'dist/pipethrough.js')
const protectedMethods = [...PROTECTED_METHODS].sort()
if (protectedMethods.length === 0) throw new Error('PROTECTED_METHODS is empty')

const protectedRows = []
const prow = (...cells) => protectedRows.push(cells.join('\t'))
prow("# Generated only by pds/tools/extract_pds_proxy_answer_key.mjs; see pds/README.md.")
prow('# The pinned image\'s own PROTECTED_METHODS set (pipethrough.js), read out of the')
prow('# module rather than transcribed: these are the account-management methods the')
prow('# official PDS will neither proxy nor accept a service-auth lxm for. Its own comment:')
prow('# "These endpoints are related to account management and must be used directly, not')
prow('# proxied or service-authed. Service auth may be utilized between PDS and entryway')
prow('# for these methods."')
prow('#')
prow('# Matching in the oracle is case-insensitive over the WHOLE lxm, authority and method')
prow('# name alike (LxmSet lowercases its members and every probe); the rows below are the')
prow('# set\'s own original spelling, which is what it iterates.')
prow('#')
prow('# Columns: nsid.')
for (const nsid of protectedMethods) prow(nsid)
await writeFile(join(output, 'pds_protected_methods_corpus.txt'), protectedRows.join('\n') + '\n')

const shape = []
const srow = (...cells) => shape.push(cells.join('\t'))
srow('# Generated only by pds/tools/extract_pds_proxy_answer_key.mjs; see pds/README.md.')
srow('# The inter-service credential the pinned official PDS mints for a proxied call:')
srow('# AppContext.serviceAuthJwt(did, aud, lxm) -> @atproto/xrpc-server createServiceJwt,')
srow('# signed with the ACCOUNT\'s repo signing keypair (ctx.actorStore.keypair(did)).')
srow(`# Minted here with iat pinned to ${IAT}; jti is fresh random per mint and the signature`)
srow('# is over it, so both are recorded as SHAPES rather than as values.')
srow('# Columns: property<TAB>value.')
srow('serialization', 'JWS compact, three base64url segments joined by "."')
srow('header-json', JSON.stringify(withLxm.header))
srow('header-segment-b64url', withLxm.headerSeg)
srow('alg-secp256k1-key', keypair.jwtAlg)
srow('alg-p256-key', p256.jwtAlg)
srow('typ', withLxm.header.typ)
srow('payload-claims-in-order', Object.keys(withLxm.payload).join(','))
srow('payload-claims-without-lxm', Object.keys(noLxm.payload).join(','))
srow('payload-json-jti-elided', JSON.stringify({ ...withLxm.payload, jti: '<32-hex>' }))
srow('iss', 'the ACCOUNT did whose repo key signs, never the PDS service did')
srow('aud', 'the bare did of the receiving service; any "#<serviceId>" fragment is stripped')
srow('lxm', 'the nsid being called; omitted entirely rather than null when not supplied')
srow('lifetime-seconds', String(withLxm.payload.exp - withLxm.payload.iat))
srow('nbf-present', String('nbf' in withLxm.payload))
srow('sub-present', String('sub' in withLxm.payload))
srow('jti-hex-chars', String(withLxm.payload.jti.length))
srow('signature-encoding', 'base64url unpadded, raw IEEE P1363 r||s, not DER')
srow('signature-bytes', String(Buffer.from(withLxm.sigSeg, 'base64url').length))
srow('verifier-rejects-typ', 'at+jwt, refresh+jwt, dpop+jwt')
srow(
  'verifier-checks',
  'exp against now; aud equals own did; lxm equals the called nsid; iss is a did or did#fragment; signature under iss\'s signing key, retried once against a freshly resolved key',
)
srow('verifier-allows-malleable-sig', 'true; cryptoVerifySignatureWithKey passes allowMalleableSig')
srow(
  'outbound-relay-announce',
  'POST <crawler>/xrpc/com.atproto.sync.requestCrawl body {"hostname":"<own hostname>"} with NO authorization header, fire-and-forget on the background queue, at most once per 1200 seconds',
)
await writeFile(join(output, 'pds_service_auth_shape_corpus.txt'), shape.join('\n') + '\n')

console.log(
  `routes: ${bare.length} always + ${full.length - bare.length} appview-gated = ${full.length}; ` +
    `protected: ${protectedMethods.length}; ` +
    `service-auth alg=${withLxm.header.alg} lifetime=${withLxm.payload.exp - withLxm.payload.iat}s`,
)
