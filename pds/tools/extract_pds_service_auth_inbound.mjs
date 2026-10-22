#!/usr/bin/env node
// Derive the inbound service-auth answer key from the pinned official PDS image:
// a corpus of JWTs, each labelled with the verdict of the image's own
// @atproto/xrpc-server verifyJwt, the function its auth verifier calls on a
// service-auth bearer. The labels come from running that function, never from
// our code. Procedure to run this: pds/README.md, "Service-auth inbound answer key".
//
// Tokens are built here with a fixed jti and signed by the image's own
// Secp256k1Keypair.sign (RFC 6979, deterministic), so the output is
// byte-reproducible; createServiceJwt itself draws a random jti and cannot be.
// Before emitting, one real createServiceJwt token is minted and its header and
// payload layout is compared with this construction, so the hand-built tokens are
// proven to have the shape the image mints.
//
// verifyJwt runs with Date.now faked to NOW*1000, and with a getSigningKey that
// knows only the issuer DID.

import { createHmac } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const [output] = process.argv.slice(2)
if (!output) throw new Error('usage: extract_pds_service_auth_inbound.mjs <output-dir>')

// The env var lets the extractor be iterated without the image; the committed
// corpus comes from the canonical run inside the pinned image.
const store = process.env.MEDAKA_IMAGE_STORE ?? '/app/node_modules/.pnpm'
const required = [
  ['@atproto/xrpc-server', '0.12.3'],
  ['@atproto/crypto', '0.5.4'],
]

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

const { createServiceJwt, verifyJwt } = await load('@atproto/xrpc-server', 'dist/auth.js')
const { AuthRequiredError } = await load('@atproto/xrpc-server', 'dist/errors.js')
const { Secp256k1Keypair } = await load('@atproto/crypto', 'dist/index.js')

// ── fixed inputs ────────────────────────────────────────────────────────────

// PUBLIC test constant: this secret is committed on purpose and protects nothing.
const SECRET_HEX = '4d65646b61416e737765724b657954657374436f6e7374616e7430303031ff01'
const ISSUER = 'did:plc:answerkeyissuer000000000000'
const OTHER_ISSUER = 'did:plc:answerkeyotherissuer0000000'
const SERVER = 'did:web:pds.answerkey.invalid'
const METHOD = 'com.atproto.repo.uploadBlob'
const NOW = 1700000000
const EXP = NOW + 1800
const JTI = '00112233445566778899aabbccddeeff'

const keypair = await Secp256k1Keypair.import(SECRET_HEX)
const keyDid = keypair.did()
const pubHex = Buffer.from(keypair.publicKeyBytes()).toString('hex')

const b64 = (s) => Buffer.from(s, 'utf8').toString('base64url')
const jsonSeg = (o) => b64(JSON.stringify(o))
const HEADER = { typ: 'JWT', alg: 'ES256K' }
const claims = (over = {}) => {
  const o = { iat: NOW, iss: ISSUER, aud: SERVER, exp: EXP, lxm: METHOD, jti: JTI, ...over }
  for (const k of Object.keys(o)) if (o[k] === undefined) delete o[k]
  return o
}
const signB64 = async (signingInput) => Buffer.from(await keypair.sign(Buffer.from(signingInput, 'utf8')))
const signed = async (headerSeg, payloadSeg) => {
  const input = `${headerSeg}.${payloadSeg}`
  return { input, sig: await signB64(input) }
}
const tokenOf = (input, sig) => `${input}.${sig.toString('base64url')}`
const genuineParts = await signed(jsonSeg(HEADER), jsonSeg(claims()))
const GENUINE_SIG = genuineParts.sig

// ── layout equivalence with the real minter ─────────────────────────────────

const real = await createServiceJwt({ iss: ISSUER, aud: SERVER, keypair, iat: NOW, exp: EXP, lxm: METHOD })
const [rh, rp] = real.split('.')
const realJti = JSON.parse(Buffer.from(rp, 'base64url').toString('utf8')).jti
if (!/^[0-9a-f]{32}$/.test(realJti)) throw new Error('real jti has an unexpected shape')
const mine = `${jsonSeg(HEADER)}.${jsonSeg(claims({ jti: realJti }))}`
if (mine !== `${rh}.${rp}`) throw new Error('hand-built token layout differs from createServiceJwt')
const realNoLxm = await createServiceJwt({ iss: ISSUER, aud: SERVER, keypair, iat: NOW, exp: EXP })
const [, rnp] = realNoLxm.split('.')
const realNoLxmJti = JSON.parse(Buffer.from(rnp, 'base64url').toString('utf8')).jti
if (jsonSeg(claims({ jti: realNoLxmJti, lxm: undefined })) !== rnp) {
  throw new Error('hand-built lxm-less payload differs from createServiceJwt')
}

// ── signature helpers ───────────────────────────────────────────────────────

const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n
const bytesToBig = (u) => BigInt('0x' + Buffer.from(u).toString('hex'))
const bigTo32 = (n) => Buffer.from(n.toString(16).padStart(64, '0'), 'hex')
const highS = (sig) => Buffer.concat([sig.subarray(0, 32), bigTo32(N - bytesToBig(sig.subarray(32)))])
const derInt = (b) => {
  let i = 0
  while (i < b.length - 1 && b[i] === 0) i++
  let v = b.subarray(i)
  if (v[0] & 0x80) v = Buffer.concat([Buffer.from([0]), v])
  return Buffer.concat([Buffer.from([0x02, v.length]), v])
}
const der = (sig) => {
  const body = Buffer.concat([derInt(sig.subarray(0, 32)), derInt(sig.subarray(32))])
  return Buffer.concat([Buffer.from([0x30, body.length]), body])
}

// ── cases ───────────────────────────────────────────────────────────────────

const cases = []
const add = (name, token) => cases.push({ name, token })
const std = async (name, header, payloadObj) => {
  const { input, sig } = await signed(jsonSeg(header), jsonSeg(payloadObj))
  add(name, tokenOf(input, sig))
}
const hSeg = jsonSeg(HEADER)
const pSeg = jsonSeg(claims())
const gSigSeg = GENUINE_SIG.toString('base64url')

add('genuine', tokenOf(genuineParts.input, GENUINE_SIG))
await std('aud_wrong', HEADER, claims({ aud: 'did:web:other.answerkey.invalid' }))
await std('aud_fragment', HEADER, claims({ aud: `${SERVER}#atproto_pds` }))
await std('lxm_wrong', HEADER, claims({ lxm: 'com.atproto.repo.createRecord' }))
await std('lxm_missing', HEADER, claims({ lxm: undefined }))
await std('lxm_other_case', HEADER, claims({ lxm: 'com.atproto.repo.UploadBlob' }))
await std('lxm_empty', HEADER, claims({ lxm: '' }))
await std('lxm_not_string', HEADER, claims({ lxm: 7 }))
await std('exp_past', HEADER, claims({ exp: NOW - 1 }))
await std('exp_equals_now', HEADER, claims({ exp: NOW }))
await std('exp_not_number', HEADER, claims({ exp: String(EXP) }))
await std('exp_missing', HEADER, claims({ exp: undefined }))
await std('iss_other', HEADER, claims({ iss: OTHER_ISSUER }))
await std('iss_fragment', HEADER, claims({ iss: `${ISSUER}#atproto` }))
await std('iss_empty_fragment', HEADER, claims({ iss: `${ISSUER}#` }))
await std('iss_not_did', HEADER, claims({ iss: 'not-a-did' }))
await std('typ_at_jwt', { typ: 'at+jwt', alg: 'ES256K' }, claims())
await std('typ_refresh_jwt', { typ: 'refresh+jwt', alg: 'ES256K' }, claims())
await std('typ_dpop_jwt', { typ: 'dpop+jwt', alg: 'ES256K' }, claims())
await std('alg_es256', { typ: 'JWT', alg: 'ES256' }, claims())
await std('alg_missing', { typ: 'JWT' }, claims())
await std('alg_not_string', { typ: 'JWT', alg: 7 }, claims())
{
  const input = `${jsonSeg({ typ: 'JWT', alg: 'none' })}.${pSeg}`
  add('alg_none', `${input}.`)
  const hs = jsonSeg({ typ: 'JWT', alg: 'HS256' })
  const hsInput = `${hs}.${pSeg}`
  add('alg_hs256', `${hsInput}.${createHmac('sha256', 'secret').update(hsInput).digest('base64url')}`)
}
{
  const flipped = Buffer.from(GENUINE_SIG)
  flipped[0] ^= 1
  add('sig_bit_flipped', tokenOf(genuineParts.input, flipped))
  add('high_s_twin', tokenOf(genuineParts.input, highS(GENUINE_SIG)))
  add('sig_der', tokenOf(genuineParts.input, der(GENUINE_SIG)))
  const other = await signed(hSeg, jsonSeg(claims({ aud: 'did:web:other.answerkey.invalid' })))
  add('sig_over_other_bytes', `${genuineParts.input}.${other.sig.toString('base64url')}`)
  add('sig_truncated', tokenOf(genuineParts.input, GENUINE_SIG.subarray(0, 63)))
  add('sig_empty', `${genuineParts.input}.`)
}
add('segments_2', `${hSeg}.${pSeg}`)
add('segments_4', `${genuineParts.input}.${gSigSeg}.extra`)
add('b64_header_bad', `!!!!.${pSeg}.${gSigSeg}`)
add('b64_payload_bad', `${hSeg}.!!!!.${gSigSeg}`)
add('b64_sig_bad', `${genuineParts.input}.${gSigSeg.slice(0, 20)}!${gSigSeg.slice(20)}`)
{
  const bad = await signed(hSeg, b64('not json'))
  add('payload_not_json', tokenOf(bad.input, bad.sig))
  const arr = await signed(hSeg, b64('[1,2,3]'))
  add('payload_array', tokenOf(arr.input, arr.sig))
  const raw = JSON.stringify(claims())
  const dup = raw.replace(`"aud":"${SERVER}"`, `"aud":"did:web:other.answerkey.invalid","aud":"${SERVER}"`)
  if (dup === raw) throw new Error('duplicate-aud construction failed')
  const d = await signed(hSeg, b64(dup))
  add('aud_duplicate_key_last_wins', tokenOf(d.input, d.sig))
  const dup2 = raw.replace(`"aud":"${SERVER}"`, `"aud":"${SERVER}","aud":"did:web:other.answerkey.invalid"`)
  const d2 = await signed(hSeg, b64(dup2))
  add('aud_duplicate_key_first_right', tokenOf(d2.input, d2.sig))
}

// ── run the image's verifyJwt ───────────────────────────────────────────────

const getSigningKey = async (did) => {
  // The image's own lookup splits the `#fragment` off before resolving the DID.
  if (did.split('#')[0] === ISSUER) return keyDid
  throw new AuthRequiredError('no signing key for did (answer-key stub)', 'StubUnknownDid')
}
const realNow = Date.now
const verdicts = []
for (const c of cases) {
  Date.now = () => NOW * 1000
  try {
    await verifyJwt(c.token, SERVER, METHOD, getSigningKey)
    verdicts.push({ ...c, verdict: 'accept', error: '-' })
  } catch (err) {
    verdicts.push({ ...c, verdict: 'reject', error: String(err?.error ?? err?.name ?? 'Error') })
  } finally {
    Date.now = realNow
  }
}
if (verdicts.find((v) => v.name === 'genuine')?.verdict !== 'accept') {
  throw new Error('the genuine token was not accepted: the stub or the date faking is wrong')
}

// ── emit ────────────────────────────────────────────────────────────────────

const out = []
out.push('# Generated only by pds/tools/extract_pds_service_auth_inbound.mjs; see pds/README.md.')
out.push('# Inbound service-auth answer key: JWTs labelled with the verdict of the pinned')
out.push("# official image's own @atproto/xrpc-server verifyJwt (design P8: the labels come")
out.push('# from outside our code). Header lines first, then one `case` line per token.')
out.push('#')
out.push('#   key      compressed secp256k1 public key (hex) of a fixed test keypair. Its secret is a')
out.push('#            PUBLIC test constant in the extractor and protects nothing.')
out.push('#   issuer   the one DID the stub signing-key lookup knows; it resolves to `key`.')
out.push('#   server   the audience verifyJwt was given as its own DID.')
out.push('#   method   the lexicon method verifyJwt was told to expect.')
out.push('#   now      the Unix time (seconds) Date.now was faked to around every verifyJwt call.')
out.push('#')
out.push('# case <name> <accept|reject> <official-error-name or -> <token>')
out.push('#   The error name is the XRPCError `error` the image threw (BadJwt, BadJwtType,')
out.push('#   JwtExpired, BadJwtAudience, BadJwtLexiconMethod, BadJwtIss, BadJwtSignature), or the')
out.push('#   JavaScript error class (SyntaxError) when JSON.parse threw before any check ran.')
out.push('#   StubUnknownDid is the extractor stub refusing a DID it does not know; the real')
out.push('#   resolver is outside this corpus.')
out.push('#   Equal `exp` and `now` is accepted, a high-S signature is accepted (allowMalleableSig),')
out.push('#   and verdicts that differ from what a strict verifier would give are the point.')
out.push('#   Layout equivalence with createServiceJwt is asserted by the extractor before it writes.')
out.push('#')
out.push(`key ${pubHex}`)
out.push(`issuer ${ISSUER}`)
out.push(`server ${SERVER}`)
out.push(`method ${METHOD}`)
out.push(`now ${NOW}`)
for (const v of verdicts) out.push(`case ${v.name} ${v.verdict} ${v.error} ${v.token}`)
await writeFile(join(output, 'pds_service_auth_inbound_corpus.txt'), out.join('\n') + '\n')

const accepts = verdicts.filter((v) => v.verdict === 'accept').length
console.log(`cases: ${verdicts.length}; accept: ${accepts}; reject: ${verdicts.length - accepts}`)
