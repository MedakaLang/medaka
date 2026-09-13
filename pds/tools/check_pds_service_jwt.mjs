// Grades service-auth tokens minted by pds/lib/jwt.mdk against the official
// @atproto/crypto reference verifier (S-service-jwt, #2608).
//
// Usage: node check_pds_service_jwt.mjs <node_modules> <manifest> <now>
//
//   <node_modules>  a tree materialized by `npm ci` from the pinned
//                   pds/tools/atproto_reference lockfile
//   <manifest>      pds/test/service_jwt_interop_main.mdk's stdout
//   <now>           the instant, in seconds, to check `exp` against
//
// Manifest grammar; `#` comments and blank lines are ignored, fields are
// whitespace-separated:
//
//   case <name> <accept|reject> <did:key:...> <expected-aud> <expected-lxm|-> <token> [<lifetime>]
//   <other key> <value>      informational, ignored
//
// <lifetime> is the exact `exp - iat` the row's token must carry, in seconds. A
// row that omits it is graded against 60, which is what a service-auth request
// naming no expiry of its own mints. The field is per row rather than fixed
// here because com.atproto.server.getServiceAuth lets a client ask for its own
// window: a single hardcoded figure would refuse every such token before any
// claim was looked at, and deleting the assertion instead would stop grading
// the mint shape at all.
//
// Every row states its OWN expectation, so one run covers both the accept and
// the reject cases and exits nonzero when any row's outcome differs from what
// it claimed. A reject row with no stated reason would be indistinguishable
// from a token this script failed to parse, so each rejection prints why.
//
// The checks mirror the `verifier-checks` row of
// pds/test/vectors/pds_service_auth_shape_corpus.txt, which was read off the
// official implementation: exp against now, aud equal to the verifier's own
// DID, lxm equal to the called NSID, and the signature under the issuer's
// signing key. The claim-shape assertions come from the same corpus.
//
// ONE DELIBERATE DIVERGENCE, in the strict direction: the corpus records that
// the official verifier passes `allowMalleableSig`, so it would accept a
// high-S signature. This script leaves that option unset, which makes
// @atproto/crypto enforce canonical low-S compact encoding — so an accept here
// also certifies the canonicalization pds/lib/secp256k1.mdk performs, and is
// strictly harder to pass than the official verifier.

import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const [modulesArg, manifestArg, nowArg] = process.argv.slice(2)
if (!modulesArg || !manifestArg || !nowArg) {
  console.error(
    'usage: check_pds_service_jwt.mjs <node_modules> <manifest> <now>',
  )
  process.exit(2)
}

const modules = path.resolve(modulesArg)
const cryptoPkg = path.join(modules, '@atproto/crypto/package.json')
const pinnedVersion = '0.5.4'
const actualVersion = JSON.parse(fs.readFileSync(cryptoPkg, 'utf8')).version
if (actualVersion !== pinnedVersion) {
  console.error(
    `check_pds_service_jwt: @atproto/crypto ${actualVersion}, expected ${pinnedVersion}`,
  )
  process.exit(2)
}

const { parseDidKey, verifySignature } = await import(
  pathToFileURL(path.join(modules, '@atproto/crypto/dist/index.js')).href
)

const now = Number(nowArg)
if (!Number.isInteger(now)) {
  console.error(`check_pds_service_jwt: <now> must be an integer, got ${nowArg}`)
  process.exit(2)
}

const expectedHeader = '{"typ":"JWT","alg":"ES256K"}'
const expectedAlg = 'ES256K'
const defaultLifetimeSeconds = 60
const jtiPattern = /^[0-9a-f]{32}$/

const b64urlToBytes = (segment) => Buffer.from(segment, 'base64url')
const b64urlToText = (segment) => b64urlToBytes(segment).toString('utf8')

// Returns null when the token is good for this audience and method, or the
// reason it was refused.
const refusal = async (
  token,
  didKey,
  expectedAud,
  expectedLxm,
  lifetimeSeconds,
) => {
  const segments = token.split('.')
  if (segments.length !== 3) return `expected 3 segments, got ${segments.length}`
  const [headerSeg, payloadSeg, sigSeg] = segments

  const headerText = b64urlToText(headerSeg)
  if (headerText !== expectedHeader) return `header is ${headerText}`

  const payloadText = b64urlToText(payloadSeg)
  let payload
  try {
    payload = JSON.parse(payloadText)
  } catch (err) {
    return `payload is not JSON: ${err.message}`
  }

  // Claim ORDER is wire-visible, so the names are compared as a sequence, not
  // as a set. JSON.parse preserves the source order of string keys.
  const names = Object.keys(payload)
  const wanted =
    expectedLxm === null
      ? ['iat', 'iss', 'aud', 'exp', 'jti']
      : ['iat', 'iss', 'aud', 'exp', 'lxm', 'jti']
  if (names.join(',') !== wanted.join(','))
    return `claims are ${names.join(',')}, expected ${wanted.join(',')}`

  if (payload.exp - payload.iat !== lifetimeSeconds)
    return `lifetime is ${payload.exp - payload.iat}s, expected ${lifetimeSeconds}s`
  if (!jtiPattern.test(payload.jti)) return `jti is ${JSON.stringify(payload.jti)}`
  if (now >= payload.exp) return `expired: now ${now} >= exp ${payload.exp}`
  if (now < payload.iat) return `not yet valid: now ${now} < iat ${payload.iat}`
  if (payload.aud !== expectedAud)
    return `aud is ${payload.aud}, expected ${expectedAud}`
  if (expectedLxm !== null && payload.lxm !== expectedLxm)
    return `lxm is ${payload.lxm}, expected ${expectedLxm}`

  const sig = b64urlToBytes(sigSeg)
  if (sig.length !== 64) return `signature is ${sig.length} bytes, expected 64`

  const parsed = parseDidKey(didKey)
  if (parsed.jwtAlg !== expectedAlg)
    return `${didKey} is a ${parsed.jwtAlg} key, expected ${expectedAlg}`

  const signingInput = Buffer.from(`${headerSeg}.${payloadSeg}`, 'utf8')
  let verified
  try {
    verified = await verifySignature(didKey, signingInput, sig, {
      jwtAlg: expectedAlg,
    })
  } catch (err) {
    return `verifySignature threw: ${err.message}`
  }
  return verified ? null : 'signature does not verify under the stated did:key'
}

const lines = fs
  .readFileSync(manifestArg === '-' ? 0 : manifestArg, 'utf8')
  .split('\n')
  .filter((line) => line.trim() && !line.startsWith('#'))

let cases = 0
let failures = 0
for (const line of lines) {
  const fields = line.trim().split(/\s+/)
  if (fields[0] !== 'case') continue
  const [, name, expectation, didKey, expectedAud, lxmField, token, lifeField] =
    fields
  if (!token) {
    console.log(`${name} MALFORMED ROW`)
    failures += 1
    continue
  }
  if (expectation !== 'accept' && expectation !== 'reject') {
    console.log(`${name} UNKNOWN EXPECTATION ${expectation}`)
    failures += 1
    continue
  }
  // An unreadable lifetime is a MALFORMED ROW and not a silent fall back to
  // the default: a row that names a window and is graded against 60 anyway
  // would report a pass for an assertion nobody made.
  const lifetimeSeconds =
    lifeField === undefined ? defaultLifetimeSeconds : Number(lifeField)
  if (!Number.isInteger(lifetimeSeconds) || lifetimeSeconds <= 0) {
    console.log(`${name} MALFORMED ROW lifetime=${lifeField}`)
    failures += 1
    continue
  }
  cases += 1
  const reason = await refusal(
    token,
    didKey,
    expectedAud,
    lxmField === '-' ? null : lxmField,
    lifetimeSeconds,
  )
  const got = reason === null ? 'accept' : 'reject'
  const ok = got === expectation
  if (!ok) failures += 1
  console.log(
    `${ok ? 'ok  ' : 'FAIL'} ${name} expect=${expectation} got=${got}` +
      (reason === null ? '' : ` reason=${reason}`),
  )
}

// A manifest that produced no rows would otherwise exit 0 having verified
// nothing, which is the one failure this script cannot afford to report as a
// pass.
if (cases === 0) {
  console.error('check_pds_service_jwt: no case rows in the manifest')
  process.exit(1)
}

console.log(
  `check_pds_service_jwt: ${cases} case(s), ${failures} failing ` +
    `(@atproto/crypto ${actualVersion}, low-S enforced)`,
)
process.exit(failures === 0 ? 0 : 1)
