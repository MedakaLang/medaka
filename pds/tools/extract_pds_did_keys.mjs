import fs from 'node:fs'
import { Secp256k1Keypair } from '/app/node_modules/.pnpm/@atproto+crypto@0.5.4/node_modules/@atproto/crypto/dist/secp256k1/keypair.js'

const manifest = fs.readFileSync(process.argv[2], 'utf8')
const keyRows = manifest
  .split('\n')
  .filter((line) => line.startsWith('key '))
  .map((line) => line.split(/\s+/))

if (keyRows.length !== 16) throw new Error(`expected 16 key rows, found ${keyRows.length}`)
for (const [position, fields] of keyRows.entries()) {
  const [record, idText, key] = fields
  const id = Number(idText)
  if (record !== 'key' || fields.length !== 3 || id !== position) {
    throw new Error(`key row ${position} is malformed or out of order`)
  }
  const pair = await Secp256k1Keypair.import(key, { exportable: false })
  const publicKey = Buffer.from(pair.publicKeyBytes()).toString('hex')
  const did = await pair.did()
  console.log(`did-key ${id} ${publicKey} ${did}`)
}
