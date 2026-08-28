#!/usr/bin/env node
// Recreate the Phase 1 corpora with libraries installed inside the pinned PDS
// image. This never starts the service and never performs an XRPC call.

import { mkdir, readFile, symlink } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import { dirname, join } from 'node:path'

const [tools, output] = process.argv.slice(2)
if (!tools || !output) {
  throw new Error('usage: extract_pds_phase1_corpora.mjs <mounted-tools> <output-dir>')
}

const store = '/app/node_modules/.pnpm'
const required = [
  ['@atproto/repo', '0.10.10'],
  ['@atproto/crypto', '0.5.4'],
  ['@atproto/common-web', '0.5.9'],
  ['@atproto/lex-cbor', '0.1.6'],
  ['@atproto/lex-data', '0.1.7'],
]

const findPackage = async (name, version) => {
  const packageDir = `${name.replace('/', '+')}@${version}`
  const candidate = join(store, packageDir, 'node_modules', ...name.split('/'))
  const manifest = JSON.parse(await readFile(join(candidate, 'package.json'), 'utf8'))
  if (manifest.name !== name || manifest.version !== version) {
    throw new Error(`image package mismatch for ${name}@${version}`)
  }
  return candidate
}

const moduleRoot = join(output, 'node_modules')
await mkdir(moduleRoot, { recursive: true })
for (const [name, version] of required) {
  const source = await findPackage(name, version)
  const destination = join(moduleRoot, ...name.split('/'))
  await mkdir(dirname(destination), { recursive: true })
  await symlink(source, destination, 'dir')
}

for (const [generator, corpus] of [
  ['gen_mst_corpus.mjs', 'mst_reference_corpus.txt'],
  ['gen_car_corpus.mjs', 'car_reference_corpus.txt'],
  ['gen_repo_corpus.mjs', 'repo_reference_corpus.txt'],
]) {
  const run = spawnSync(process.execPath, [join(tools, generator), moduleRoot, join(output, corpus)], {
    encoding: 'utf8',
  })
  if (run.status !== 0) {
    throw new Error(`${generator} failed in image (status ${run.status}):\n${run.stdout}${run.stderr}`)
  }
}

console.log('image libraries: @atproto/repo@0.10.10 @atproto/crypto@0.5.4; MST/CAR/repo corpora recreated')
