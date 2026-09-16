// The MST layer a key lands on, and the search that finds a key for a layer.
//
// An atproto MST puts a key on the layer named by the count of leading ZERO
// BIT PAIRS in sha256(key) — so a key's depth is not a choice, it is a
// property of its own hash, and a tree with nodes on four layers can only be
// built by finding keys whose hashes already agree to sit there.
//
// Two corpus generators need this: pds/tools/gen_mst_corpus.mjs, which grades
// the layer assignment itself, and pds/tools/gen_sync_event_corpus.mjs, which
// needs a repository whose tree is deeper than one node. It lives here so the
// two mine the same keys from the same rule rather than from two copies of it.

import { createHash } from 'node:crypto'

export const exactDepth = (key) => {
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

export const mine = (prefix, depth) => {
  for (let i = 0; ; i++) {
    const key = `${prefix}${i}`
    if (exactDepth(key) === depth) return key
  }
}
